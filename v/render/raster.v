// CPU port of hex 3.4.0's Dot scope fragment shader, `dot_scope_fragment`
// (oracle/rune_hud.wgsl:283-343), for the plate path the HUD draws: a plate
// centred in the window, no island and no ears, and a dark target. The
// uniforms are `DotUniforms` (src/rune_hud.rs:687-712) as
// `DotUniforms::new` fills them for `Layout::default()`.
//
// Every expression below keeps the shader's operand order and f32 width:
// multiply and add are never contracted (build with -ffp-contract=off), and
// the transcendental functions are the C float ones, so a pixel's colour is
// the number the GPU computes.
module render

import image
import image.png
import math
import os

// The f32 libm entry points; V's math module is f64 only.
fn C.powf(x f32, y f32) f32
fn C.tanhf(x f32) f32
fn C.floorf(x f32) f32
fn C.ceilf(x f32) f32
fn C.roundf(x f32) f32
fn C.sqrtf(x f32) f32

// `DotUniforms` is 208 bytes of f32s (src/rune_hud.rs:713-716 asserts the
// length).
const uniform_floats = 52
pub const uniform_bytes_len = uniform_floats * 4

// `pack_dots` writes at most `MAX_DOTS` pairs, 4096 bytes a frame.
pub const dot_frame_bytes = 4096

// What one frame draws: the window, the plate's pose, the dot grid, and the
// grid's u16 `[power, fresh]` pairs row by row. `pose_reveal` grows the island
// and `pose_level`/`pose_clock` drive the ears' glyphs, so the plate path here
// does not read them.
pub struct Scene {
pub mut:
	width         int // device pixels
	height        int
	backing_scale f32 // device pixels per point
	dark          bool
	pitch         f32
	columns       int
	rows          int
	dots          []u16 // len columns*rows*2, [power, fresh] per dot
	pose_width    f32
	pose_height   f32
	pose_opacity  f32
	pose_scale    f32
	pose_softness f32
	pose_cool     f32
	pose_fail     f32
	pose_glow     f32
	pose_grid     f32
	pose_live     f32
	pose_reveal   f32
	pose_level    f32
	pose_clock    f32
	pose_done     f32
}

// Dot scope's colours for one frame, sRGB (src/rune_hud/dot_scope/scope.rs:
// 905-970): `Palette`, with the plate colours already RGBA.
struct Palette {
	base   Rgb
	core   Rgb
	plate  Rgba
	rim    Rgba
	shadow Rgba
}

struct Rgb {
	r f32
	g f32
	b f32
}

struct Rgba {
	r f32
	g f32
	b f32
	a f32
}

struct Vec2 {
	x f32
	y f32
}

// A dot's shader terms that depend only on the dot: the fragment recomputes
// them for every pixel it touches, on the same operands, so hoisting them to
// one table per frame leaves every value bit for bit what it was.
struct Dot {
	center     Vec2
	power      f32
	mask       f32
	alpha      f32
	dot_radius f32
	color      Rgb
}

fn maxf(a f32, b f32) f32 {
	return if a > b { a } else { b }
}

fn minf(a f32, b f32) f32 {
	return if a < b { a } else { b }
}

fn absf(a f32) f32 {
	return if a < 0.0 { -a } else { a }
}

fn clampf(x f32, lo f32, hi f32) f32 {
	if x < lo {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}

// `select(a, b, condition)` with the condition read.
fn selectf(condition bool, a f32, b f32) f32 {
	return if condition { b } else { a }
}

fn v2(x f32, y f32) Vec2 {
	return Vec2{x, y}
}

fn v2_sub(a Vec2, b Vec2) Vec2 {
	return Vec2{a.x - b.x, a.y - b.y}
}

fn v2_mul(a Vec2, s f32) Vec2 {
	return Vec2{a.x * s, a.y * s}
}

fn v2_div(a Vec2, s f32) Vec2 {
	return Vec2{a.x / s, a.y / s}
}

fn v2_length(a Vec2) f32 {
	return C.sqrtf(a.x * a.x + a.y * a.y)
}

// `sstep`: `smoothstep` spelled out because `coverage` relies on descending
// edges.
fn sstep(edge0 f32, edge1 f32, x f32) f32 {
	t := clampf((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
}

fn rounded_box(point Vec2, half_size Vec2, radius f32) f32 {
	q := v2(absf(point.x) - half_size.x + radius, absf(point.y) - half_size.y + radius)
	return v2_length(v2(maxf(q.x, 0.0), maxf(q.y, 0.0))) + minf(maxf(q.x, q.y), 0.0) - radius
}

fn coverage(distance f32, softness f32) f32 {
	return sstep(softness, -softness, distance)
}

fn mix1(a f32, b f32, t f32) f32 {
	return a + (b - a) * t
}

fn mix3(a Rgb, b Rgb, t f32) Rgb {
	return Rgb{a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t}
}

// `composite`: premultiplied source over premultiplied destination.
fn composite(mut dest Rgba, color Rgb, alpha_in f32) {
	alpha := clampf(alpha_in, 0.0, 1.0)
	dest = Rgba{
		r: color.r * alpha + dest.r * (1.0 - alpha)
		g: color.g * alpha + dest.g * (1.0 - alpha)
		b: color.b * alpha + dest.b * (1.0 - alpha)
		a: alpha + dest.a * (1.0 - alpha)
	}
}

fn fract(x f32) f32 {
	return x - C.floorf(x)
}

// Blue-noise-ish dither, +-1/255 of a level, on the pixel grid.
fn dithered(result_in Rgba, position Vec2) Rgba {
	mut result := result_in
	if result.a > 0.0 {
		pixel := v2(C.floorf(position.x), C.floorf(position.y))
		n1 := fract(52.9829189 * fract(pixel.x * 0.06711056 + pixel.y * 0.00583715))
		n2 := fract(52.9829189 * fract((pixel.x + 17.0) * 0.06711056 + (pixel.y + 31.0) * 0.00583715))
		dither := ((n1 - n2) / 255.0) * result.a
		result = Rgba{
			r: clampf(result.r + dither, 0.0, result.a)
			g: clampf(result.g + dither, 0.0, result.a)
			b: clampf(result.b + dither, 0.0, result.a)
			a: result.a
		}
	}
	return result
}

// `for_target` with the shader's default `override linear_target: bool =
// false`: the colours stay sRGB-encoded, as they were composed.
fn for_target(result Rgba) Rgba {
	return result
}

// Dot scope's colours for one frame, sRGB, `palette(dark, pose, saturation)`
// at `saturation = 1.0` (Tuning::default()).
fn palette(dark bool, cool f32, fail f32) Palette {
	mut you := Rgb{}
	mut you_core := Rgb{}
	mut agent := Rgb{}
	mut agent_core := Rgb{}
	mut coral := Rgb{}
	mut coral_core := Rgb{}
	if dark {
		you = Rgb{0.86, 0.83, 0.77}
		you_core = Rgb{0.98, 0.96, 0.92}
		agent = Rgb{0.70, 0.78, 0.90}
		agent_core = Rgb{0.92, 0.95, 1.0}
		coral = Rgb{1.0, 0.38, 0.31}
		coral_core = Rgb{1.0, 0.66, 0.6}
	} else {
		you = Rgb{0.62, 0.53, 0.40}
		you_core = Rgb{0.47, 0.38, 0.26}
		agent = Rgb{0.40, 0.47, 0.58}
		agent_core = Rgb{0.24, 0.31, 0.43}
		coral = Rgb{0.9, 0.27, 0.21}
		coral_core = Rgb{0.7, 0.18, 0.13}
	}
	base := saturate(mix3(mix3(you, agent, cool), coral, fail))
	core := saturate(mix3(mix3(you_core, agent_core, cool), coral_core, fail))
	if dark {
		return Palette{
			base:   base
			core:   core
			plate:  Rgba{f32(17.0) / f32(255.0), f32(17.0) / f32(255.0), f32(20.0) / f32(255.0), 0.94}
			rim:    Rgba{1.0, 1.0, 1.0, 0.11}
			shadow: Rgba{0.0, 0.0, 0.0, 0.5}
		}
	}
	return Palette{
		base:   base
		core:   core
		plate:  Rgba{f32(252.0) / f32(255.0), f32(251.0) / f32(255.0), f32(249.0) / f32(255.0), 0.96}
		rim:    Rgba{0.0, 0.0, 0.0, 0.09}
		shadow: Rgba{f32(20.0) / f32(255.0), f32(24.0) / f32(255.0), f32(40.0) / f32(255.0), 0.2}
	}
}

// `saturate(color, amount)`: blend towards the luma, then clamp.
fn saturate(color Rgb) Rgb {
	luma := 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
	return Rgb{
		r: clampf(luma + (color.r - luma) * 1.0, 0.0, 1.0)
		g: clampf(luma + (color.g - luma) * 1.0, 0.0, 1.0)
		b: clampf(luma + (color.b - luma) * 1.0, 0.0, 1.0)
	}
}

// `field_radius` with no island: the plate's corner radius is half its
// height, so its ends are pills.
fn field_radius(pose_height f32) f32 {
	return pose_height / 2.0
}

// `dot_value`: each dot's (power, freshness) as 0-1 from its two u16 halves.
fn dot_value(dots []u16, index int) Vec2 {
	return v2(f32(dots[index * 2]) / 65535.0, f32(dots[index * 2 + 1]) / 65535.0)
}

// The dot grid's per-dot terms, as the shader's inner loop computes them.
fn dot_table(scene &Scene, pal Palette, half_size Vec2, radius f32) []Dot {
	columns := scene.columns
	rows := scene.rows
	pitch := scene.pitch
	center_offset := v2((f32(columns) - 1.0) * 0.5, (f32(rows) - 1.0) * 0.5)
	dark := scene.dark
	unlit := selectf(dark, 0.085, 0.07)
	full := selectf(dark, 1.0, 0.96)
	curve := selectf(dark, 0.75, 0.9)
	presence := 0.5 + 0.5 * maxf(scene.pose_live, scene.pose_cool)
	mut table := []Dot{len: columns * rows}
	for j in 0 .. rows {
		for i in 0 .. columns {
			center := v2((f32(i) - center_offset.x) * pitch, (f32(j) - center_offset.y) * pitch)
			cap := -rounded_box(center, half_size, radius)
			mask := sstep(1.4, 4.6, cap)
			if mask <= 0.0 {
				table[j * columns + i] = Dot{
					center: center
					mask:   mask
				}
				continue
			}
			value := dot_value(scene.dots, j * columns + i)
			power := maxf(value.x, f32(1e-5))
			fresh := value.y
			row := absf(center.y) / half_size.y
			floor_alpha := unlit * (1.0 - 0.7 * sstep(0.35, 0.95, row)) * presence * scene.pose_grid
			alpha := floor_alpha + (full - floor_alpha) * C.powf(power, curve * mix1(1.4, 1.0, fresh))
			dot_radius := (0.25 + 0.17 * C.powf(power, 0.6)) * mix1(1.0, mix1(0.82, 1.0,
				fresh), sstep(0.03, 0.2, power)) * pitch
			core := clampf(power * power * 1.1, 0.0, 0.9) * mix1(0.3, 1.0, fresh)
			table[j * columns + i] = Dot{
				center:     center
				power:      power
				mask:       mask
				alpha:      alpha
				dot_radius: dot_radius
				color:      mix3(pal.base, pal.core, core)
			}
		}
	}
	return table
}

// `dot_scope_fragment` at one pixel's `uv`.
fn fragment(scene &Scene, pal Palette, table []Dot, uv Vec2) Rgba {
	resolution := v2(f32(scene.width), f32(scene.height))
	position := v2(uv.x * resolution.x, uv.y * resolution.y)
	// `Layout::default()`: the plate's middle is the window's middle
	// (`plate_layout.xy` = 0) and its fit is 1.
	fit := f32(1.0)
	plate_xy := v2(0.0, 0.0)
	scale := maxf(scene.pose_scale, 0.001) * maxf(fit, 0.01)
	window_point := v2_div(v2_sub(position, v2_mul(resolution, 0.5)), scene.backing_scale)
	point := v2_div(v2_sub(window_point, plate_xy), scale)
	pixel := 1.0 / (scene.backing_scale * scale)
	softness := maxf(scene.pose_softness, 0.0)
	aa := pixel * 0.75 + softness * 0.72
	half_size := v2_mul(v2(scene.pose_width, scene.pose_height), 0.5)
	radius := clampf(field_radius(scene.pose_height), 0.0, scene.pose_height * 0.5)
	distance := rounded_box(point, half_size, radius)
	dark := scene.dark
	mut result := Rgba{}
	// No island: `island_shape` is 1 and the island and ears branches are
	// dead, so the plate is the only shape drawn.

	// A soft drop shadow 3 pt below, as the prototype's 16 pt canvas blur.
	shadow_distance := rounded_box(v2_sub(point, v2(0.0, 3.0)), half_size, radius)
	composite(mut result, Rgb{pal.shadow.r, pal.shadow.g, pal.shadow.b}, pal.shadow.a * (0.5 - 0.5 * C.tanhf(shadow_distance / 6.5)))

	shape := coverage(distance, aa)
	composite(mut result, Rgb{pal.plate.r, pal.plate.g, pal.plate.b}, pal.plate.a * shape)
	composite(mut result, Rgb{pal.rim.r, pal.rim.g, pal.rim.b}, pal.rim.a * coverage(absf(distance) - 0.3, aa))

	if scene.pose_glow > 0.01 {
		reach := 34.0 + 20.0 * scene.pose_glow
		t := clampf(v2_length(point) / reach, 0.0, 1.0)
		strength := selectf(dark, 0.19, 0.3) * 0.55 * minf(1.0, scene.pose_glow)
		middle := mix3(pal.base, pal.core, 0.5)
		composite(mut result, mix3(middle, pal.base, t), strength * (1.0 - t) * shape)
	}

	columns := scene.columns
	rows := scene.rows
	pitch := scene.pitch
	center_offset := v2((f32(columns) - 1.0) * 0.5, (f32(rows) - 1.0) * 0.5)
	i0 := int(C.roundf(point.x / pitch + center_offset.x))
	j0 := int(C.roundf(point.y / pitch + center_offset.y))
	for dj := -1; dj <= 1; dj++ {
		for di := -1; di <= 1; di++ {
			i := i0 + di
			j := j0 + dj
			if i < 0 || j < 0 || i >= columns || j >= rows {
				continue
			}
			dot := table[j * columns + i]
			if dot.mask <= 0.0 {
				continue
			}
			from_center := v2_length(v2_sub(point, dot.center))
			if dot.power > 0.05 {
				composite(mut result, dot.color, 0.132 * dot.power * dot.power * dot.mask * shape * coverage(from_center - dot.dot_radius * 2.0,
					aa))
			}
			composite(mut result, dot.color, dot.alpha * dot.mask * shape * coverage(from_center - dot.dot_radius,
				aa))
		}
	}

	result = Rgba{
		r: result.r * scene.pose_opacity
		g: result.g * scene.pose_opacity
		b: result.b * scene.pose_opacity
		a: result.a * scene.pose_opacity
	}
	return for_target(dithered(result, position))
}

// The pixel rectangle that can produce a non-zero byte. Pixels outside it are
// left as the zero the buffer starts with.
struct Bounds {
	x0 int
	x1 int
	y0 int
	y1 int
}

fn clamp_i(x int, lo int, hi int) int {
	if x < lo {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}

// `lit_bounds` is the conservative early-out: it sizes a rectangle around the
// plate and its drop shadow and `render_rgba` only shades inside it.
//
// The plate's zero set reaches `half_size`, and the shadow is the same box 3 pt
// lower. Outside both, every remaining term is either exactly zero or is the
// shadow:
//
//   - plate coverage is `sstep(aa, -aa, distance)`, which is exactly 0 for
//     `distance >= aa`; the rim is the same test on `|distance| - 0.3`;
//   - the glow and every dot are multiplied by `shape`, so they vanish with it;
//   - what is left is the shadow, alpha = `shadow.a * 0.5 * (1 - tanh(d/6.5))`.
//     With `shadow.a <= 0.5` and `pose_opacity <= 1`, a byte is zero once
//     `alpha * 256 < 0.5` - 256 rather than 255 so the dither, which is bounded
//     by `alpha`, also rounds to zero. That needs `1 - tanh < 1/256`, i.e.
//     `d > artanh(255/256) * 6.5 = 20.3` pt.
//
// So a 24 pt margin is enough with headroom, and `aa` is folded in so a large
// `pose_softness` widens the box rather than breaking the argument.
fn lit_bounds(scene &Scene, half_size Vec2) Bounds {
	width := scene.width
	height := scene.height
	// `fragment` maps a pixel to point space as (position - resolution/2) /
	// (backing_scale * scale), with the plate's layout offset at zero.
	scale := maxf(scene.pose_scale, 0.001)
	inv := scene.backing_scale * scale
	if inv <= 0.0 {
		return Bounds{0, width - 1, 0, height - 1}
	}
	aa := (1.0 / inv) * 0.75 + maxf(scene.pose_softness, 0.0) * 0.72
	margin := maxf(24.0, aa + 1.0)
	reach_x := half_size.x + margin
	reach_y := half_size.y + margin + 3.0
	half_w := f32(width) * 0.5
	half_h := f32(height) * 0.5
	return Bounds{
		x0: clamp_i(int(C.floorf(half_w - 0.5 - reach_x * inv)), 0, width - 1)
		x1: clamp_i(int(C.ceilf(half_w - 0.5 + reach_x * inv)), 0, width - 1)
		y0: clamp_i(int(C.floorf(half_h - 0.5 - reach_y * inv)), 0, height - 1)
		y1: clamp_i(int(C.ceilf(half_h - 0.5 + reach_y * inv)), 0, height - 1)
	}
}

// A frame as premultiplied RGBA bytes, sRGB, `width * height * 4` of them.
pub fn render_rgba(scene &Scene) []u8 {
	needed := scene.columns * scene.rows * 2
	if scene.dots.len < needed {
		panic('render: Scene.dots holds ${scene.dots.len} halves, need ${needed} for ${scene.columns}x${scene.rows}')
	}
	pal := palette(scene.dark, scene.pose_cool, scene.pose_fail)
	half_size := v2_mul(v2(scene.pose_width, scene.pose_height), 0.5)
	radius := clampf(field_radius(scene.pose_height), 0.0, scene.pose_height * 0.5)
	table := dot_table(scene, pal, half_size, radius)
	width := f32(scene.width)
	height := f32(scene.height)
	mut out := []u8{len: scene.width * scene.height * 4}
	bounds := lit_bounds(scene, half_size)
	for y in bounds.y0 .. bounds.y1 + 1 {
		for x in bounds.x0 .. bounds.x1 + 1 {
			uv := v2((f32(x) + 0.5) / width, (f32(y) + 0.5) / height)
			c := fragment(scene, pal, table, uv)
			i := (y * scene.width + x) * 4
			out[i] = unorm(c.r)
			out[i + 1] = unorm(c.g)
			out[i + 2] = unorm(c.b)
			out[i + 3] = unorm(c.a)
		}
	}
	return out
}

// A u8 render target's UNORM conversion: round to nearest, then clamp.
fn unorm(v f32) u8 {
	return u8(clampf(C.roundf(v * 255.0), 0.0, 255.0))
}

// `DotUniforms` in its field order, little-endian floats: exactly 208 bytes.
pub fn uniform_bytes(scene &Scene) []u8 {
	pal := palette(scene.dark, scene.pose_cool, scene.pose_fail)
	mut floats := []f32{cap: uniform_floats}
	floats << f32(scene.width)
	floats << f32(scene.height)
	floats << scene.backing_scale
	floats << scene.pose_width
	floats << scene.pose_height
	floats << scene.pose_opacity
	floats << scene.pose_scale
	floats << scene.pose_softness
	floats << scene.pitch
	floats << f32(scene.columns)
	floats << f32(scene.rows)
	floats << scene.pose_glow
	floats << scene.pose_grid
	floats << scene.pose_live
	floats << scene.pose_cool
	floats << if scene.dark { f32(1.0) } else { f32(0.0) }
	// `rgba()` in `DotUniforms::new`: the dot colours are opaque.
	floats << pal.base.r
	floats << pal.base.g
	floats << pal.base.b
	floats << f32(1.0)
	floats << pal.core.r
	floats << pal.core.g
	floats << pal.core.b
	floats << f32(1.0)
	floats << pal.plate.r
	floats << pal.plate.g
	floats << pal.plate.b
	floats << pal.plate.a
	floats << pal.rim.r
	floats << pal.rim.g
	floats << pal.rim.b
	floats << pal.rim.a
	floats << pal.shadow.r
	floats << pal.shadow.g
	floats << pal.shadow.b
	floats << pal.shadow.a
	// `plate_layout`: the plate's middle, the fit, and 1 in an island.
	floats << f32(0.0)
	floats << f32(0.0)
	floats << f32(1.0)
	floats << f32(0.0)
	// `island`: zeros when the layout has none.
	for _ in 0 .. 4 {
		floats << f32(0.0)
	}
	// `field`: the plate's corner radius, and none of the ears' terms.
	floats << field_radius(scene.pose_height)
	floats << f32(0.0)
	floats << f32(0.0)
	floats << f32(0.0)
	// `ears`: done and failed.
	floats << scene.pose_done
	floats << scene.pose_fail
	floats << f32(0.0)
	floats << f32(0.0)
	if floats.len != uniform_floats {
		panic('render: DotUniforms holds ${floats.len} floats, want ${uniform_floats}')
	}
	mut out := []u8{cap: uniform_bytes_len}
	for value in floats {
		bits := math.f32_bits(value)
		out << u8(bits & 0xff)
		out << u8((bits >> 8) & 0xff)
		out << u8((bits >> 16) & 0xff)
		out << u8((bits >> 24) & 0xff)
	}
	if out.len != uniform_bytes_len {
		panic('render: uniform_bytes made ${out.len} bytes, want ${uniform_bytes_len}')
	}
	return out
}

// A frame as a straight-alpha RGBA PNG. `render_rgba` is premultiplied for the
// layered DIB; `image.RGBA` tells vlib's PNG encoder to unpremultiply it, so a
// viewer sees the shader's colours rather than premultiplied bytes.
pub fn write_png(path string, rgba []u8, width int, height int) ! {
	want := width * height * 4
	if rgba.len != want {
		return error('render: ${rgba.len} bytes for a ${width}x${height} frame, want ${want}')
	}
	img := image.RGBA{
		pix:    rgba
		stride: width * 4
		rect:   image.Rectangle{
			min: image.pt(0, 0)
			max: image.pt(width, height)
		}
	}
	bytes := png.encode_to_bytes(img)!
	os.write_file_array(path, bytes)!
}
