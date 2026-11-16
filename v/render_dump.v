// `hexv render [dir]`: draws the replay's frames through the CPU port of the
// Dot scope shader (v/render) and writes them out for review: a PNG and the
// shader's uniform block per frame, plus one file holding every frame's
// uniforms and dot buffer.
//
// The inputs are the Replay's own output, `dots.bin` (4096 bytes a frame) and
// `meta.tsv` (the `Pose` columns `DotUniforms` takes); a replay of the
// 330-frame schedule stands in when the table has no pose columns.
module main

import os
import render

// The review clip's window: `CAPTURE_DOT_WINDOW` (320 x 128 pt) at 2x, as
// hex 3.4.0's rune_hud/tests.rs:59-231 draws it.
const render_width = 640
const render_height = 256
const render_scale = f32(2.0)
const render_frames = 330

// One frame of the schedule: the pose the shader takes as uniforms, the grid,
// and its u16 dot pairs.
struct FrameInput {
	columns   int
	rows      int
	width     f32
	height    f32
	opacity   f32
	scale     f32
	softness  f32
	cool      f32
	glow      f32
	grid      f32
	live      f32
	done      f32
	reveal    f32
	fail      f32
	dots      []u16
	dot_bytes []u8 // the frame's dots.bin payload, `render.dot_frame_bytes`
}

fn (f FrameInput) scene(pitch f32) render.Scene {
	return render.Scene{
		width:         render_width
		height:        render_height
		backing_scale: render_scale
		dark:          true
		pitch:         pitch
		columns:       f.columns
		rows:          f.rows
		dots:          f.dots
		pose_width:    f.width
		pose_height:   f.height
		pose_opacity:  f.opacity
		pose_scale:    f.scale
		pose_softness: f.softness
		pose_cool:     f.cool
		pose_fail:     f.fail
		pose_glow:     f.glow
		pose_grid:     f.grid
		pose_live:     f.live
		pose_reveal:   f.reveal
		pose_level:    f32(0.0)
		pose_clock:    f32(0.0)
		pose_done:     f.done
	}
}

// The u16 halves of one frame's `MAX_DOTS` `[u16 power, u16 fresh]` pairs.
fn frame_dots(bytes []u8, columns int, rows int) []u16 {
	needed := columns * rows * 2
	mut out := []u16{len: needed}
	for i in 0 .. needed {
		out[i] = u16(bytes[i * 2]) | (u16(bytes[i * 2 + 1]) << 8)
	}
	return out
}

// `packed_dots` (src/rune_hud.rs:824): 4096 bytes, zero-padded past the dots.
fn frame_dot_bytes(dots []u16) []u8 {
	mut out := []u8{len: render.dot_frame_bytes}
	limit := if dots.len * 2 < out.len { dots.len } else { out.len / 2 }
	for i in 0 .. limit {
		out[i * 2] = u8(dots[i] & 0xff)
		out[i * 2 + 1] = u8(dots[i] >> 8)
	}
	return out
}

// The Replay's `meta.tsv` as frames, in file order.
fn load_frames(dir string) ![]FrameInput {
	dots_path := '${dir}/dots.bin'
	meta_path := '${dir}/meta.tsv'
	if !os.exists(dots_path) || !os.exists(meta_path) {
		return error('${dir} holds no dots.bin and meta.tsv')
	}
	dots := os.read_bytes(dots_path)!
	if dots.len != render_frames * render.dot_frame_bytes {
		return error('${dots_path} is ${dots.len} bytes, want ${render_frames * render.dot_frame_bytes}')
	}
	lines := os.read_file(meta_path)!.split_into_lines().filter(it.len > 0)
	if lines.len != render_frames + 1 {
		return error('${meta_path} has ${lines.len - 1} frames, want ${render_frames}')
	}
	header := lines[0].split('\t')
	mut at := map[string]int{}
	for k, name in header {
		at[name] = k
	}
	for name in ['columns', 'rows', 'width', 'height', 'opacity', 'scale', 'softness', 'cool',
		'glow', 'grid', 'live', 'done', 'reveal'] {
		if name !in at {
			return error('${meta_path} has no ${name} column: replay without pose columns')
		}
	}
	fail_at := at['fail'] or { -1 }
	mut frames := []FrameInput{cap: render_frames}
	for row in lines[1..] {
		fields := row.split('\t')
		columns := fields[at['columns']].int()
		rows := fields[at['rows']].int()
		mut fail := f32(0.0)
		if fail_at >= 0 && fail_at < fields.len {
			fail = fields[fail_at].f32()
		}
		offset := frames.len * render.dot_frame_bytes
		payload := dots[offset..offset + render.dot_frame_bytes]
		frames << FrameInput{
			columns:   columns
			rows:      rows
			width:     fields[at['width']].f32()
			height:    fields[at['height']].f32()
			opacity:   fields[at['opacity']].f32()
			scale:     fields[at['scale']].f32()
			softness:  fields[at['softness']].f32()
			cool:      fields[at['cool']].f32()
			glow:      fields[at['glow']].f32()
			grid:      fields[at['grid']].f32()
			live:      fields[at['live']].f32()
			done:      fields[at['done']].f32()
			reveal:    fields[at['reveal']].f32()
			fail:      fail
			dots:      frame_dots(payload, columns, rows)
			dot_bytes: payload
		}
	}
	return frames
}

// The same 330-frame schedule the Replay runs (indicator.v:185-232), for a
// `meta.tsv` that predates the pose columns.
fn replay_frames() []FrameInput {
	mut m := indicator_new(tuning_default())
	mut events := [Event{0.0, 'started'}, Event{3.0, 'submitted'}, Event{3.6, 'processing'},
		Event{4.4, 'completed'}]!
	mut ev_i := 0
	mut frames := []FrameInput{cap: render_frames}
	for n in 0 .. render_frames {
		t := f32(n) / 60.0
		now := f64(t)
		for ev_i < events.len && events[ev_i].at <= now {
			match events[ev_i].kind {
				'started' { m.on_started(now) }
				'submitted' { m.on_submitted(now) }
				'processing' { m.show_pipeline(now) }
				'completed' { m.on_completed(now) }
				else {}
			}
			ev_i++
		}
		if t < 3.0 {
			rms := C.powf(f32(10.0), demo_loudness(t) / 20.0)
			m.loudness = loudness_db(rms)
		}
		f := m.step(now, f32(1.0) / 60.0, false)
		p := f.pose
		frames << FrameInput{
			columns:   f.columns
			rows:      f.rows
			width:     p.width
			height:    p.height
			opacity:   p.opacity
			scale:     p.scale
			softness:  p.softness
			cool:      p.cool
			glow:      p.glow
			grid:      p.grid
			live:      p.live
			done:      p.done
			reveal:    p.reveal
			fail:      p.fail
			dots:      f.dots
			dot_bytes: frame_dot_bytes(f.dots)
		}
	}
	return frames
}

fn push_le_u32(mut out []u8, v u32) {
	out << u8(v & 0xff)
	out << u8((v >> 8) & 0xff)
	out << u8((v >> 16) & 0xff)
	out << u8((v >> 24) & 0xff)
}

// Draw every frame into `<out_dir>/frames` and print how many.
pub fn run_render(out_dir string) {
	frames_dir := '${out_dir}/frames'
	os.mkdir_all(frames_dir) or { panic(err) }
	frames := load_frames(out_dir) or {
		println('render: ${err}; replaying the schedule')
		replay_frames()
	}
	pitch := tuning_default().spacing
	frame_bytes := render.uniform_bytes_len + render.dot_frame_bytes
	mut pack := []u8{cap: 8 + frames.len * frame_bytes}
	push_le_u32(mut pack, u32(render_width))
	push_le_u32(mut pack, u32(render_height))
	for n, frame in frames {
		scene := frame.scene(pitch)
		rgba := render.render_rgba(&scene)
		render.write_png('${frames_dir}/${n:04}.png', rgba, render_width, render_height) or {
			panic(err)
		}
		uniforms := render.uniform_bytes(&scene)
		if uniforms.len != render.uniform_bytes_len {
			panic('render: ${uniforms.len}-byte uniform, want ${render.uniform_bytes_len}')
		}
		os.write_file_array('${frames_dir}/${n:04}.uniform.bin', uniforms) or { panic(err) }
		pack << uniforms
		pack << frame.dot_bytes
		if n == 0 {
			println('render: frame 0 ${render_width}x${render_height} rgba=${rgba.len}B uniform=${uniforms.len}B dots=${frame.dot_bytes.len}B')
		}
	}
	os.write_file_array('${frames_dir}/frames.bin', pack) or { panic(err) }
	println('frames=${frames.len} png=${frames_dir}/NNNN.png uniform=${frames_dir}/NNNN.uniform.bin frames.bin=${pack.len}B columns=${frames[0].columns} rows=${frames[0].rows}')
}
