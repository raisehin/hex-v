// Port of hex 3.4.0's Dot scope simulation (src/rune_hud/dot_scope/scope.rs,
// dot_scope.rs, spring.rs) and the DotFrame packing from
// src/dictation/indicator.rs. Same field order, same operation order: this is
// meant to produce the same f32 values, so the u16 buffer matches
// oracle/out/dots.bin.
//
// The f32 libm entry points are declared here rather than taken from V's math
// module, because V exposes exp/sin/tan in f64 only: going through f64 would
// change the rounding and no longer match Rust's expf/sinf.
module main

fn C.sinf(x f32) f32
fn C.cosf(x f32) f32
fn C.tanf(x f32) f32
fn C.expf(x f32) f32
fn C.powf(x f32, y f32) f32
fn C.sqrtf(x f32) f32
fn C.tanhf(x f32) f32
fn C.floorf(x f32) f32
fn C.log10f(x f32) f32
fn C.fmodf(x f32, y f32) f32

const pi = f32(3.14159265358979323846)
const tau = f32(6.28318530717958647692)

const step_h = f32(1.0) / f32(240.0)
const history = 512
const samples_per_column = 3
const speeds = [f32(0.8), 1.25, 1.85, 2.6]!
const base_amp = [f32(0.55), 0.42, 0.3, 0.2]!
const spatial = [f32(1.4), 2.4, 3.8, 5.6]!
const start_width = f32(30.0)
const enter_time = f32(0.42)
const wipe = f32(0.3)
const pass_inset = f32(9.0)
const phosphor_head = f32(0.15)
const breath_period = f32(5.5)
const hidden_scale = f32(0.9)
const hidden_softness = f32(3.0)
const work_helix = f32(2.6)
const flow_spacing_k = f32(0.7)
const carrier_rest = f32(0.14)
const ring_birth = f32(0.15)
const beam_fade = f32(0.14)

const max_rows = 15
const max_dots = 1024
const plate_height = f32(26.0)

const auto_min_span = f32(16.0)
const auto_range = f32(24.0)
const auto_room_margin = f32(5.0)
const auto_attack = f32(0.04)
const room_fall = f32(0.3)
const room_rise = f32(6.0)

fn clamp32(x f32, lo f32, hi f32) f32 {
	if x < lo {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}

fn rem_euclid32(x f32, y f32) f32 {
	r := C.fmodf(x, y)
	if r < 0.0 {
		return r + if y < 0.0 { -y } else { y }
	}
	return r
}

fn smoothstep(a f32, b f32, x f32) f32 {
	t := clamp32((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
}

fn bump(d f32, w f32) f32 {
	return C.expf(-(d / w) * (d / w))
}

fn hermite(start f32, speed f32, end f32, t_in f32) f32 {
	t := clamp32(t_in, 0.0, 1.0)
	t2 := t * t
	t3 := t * t * t
	return (2.0 * t3 - 3.0 * t2 + 1.0) * start + (t3 - 2.0 * t2 + t) * wipe * speed + (3.0 * t2 - 2.0 * t3) * end
}

fn pass_position(p f32) f32 {
	return 0.5 - 0.5 * C.cosf(pi * clamp32(p, 0.0, 1.0))
}

fn demo_level(time f32) f32 {
	phrase := C.floorf(time / f32(2.4))
	t := time - phrase * f32(2.4)
	if t > 1.7 {
		return 0.04
	}
	shape := C.powf(C.sinf(pi * t / f32(1.7)), f32(0.4))
	rate := tau * (f32(4.3) + f32(0.6) * C.sinf(phrase * f32(1.7)))
	syllable := f32(0.5) + f32(0.5) * C.sinf(rate * t + phrase)
	stress := f32(0.75) + f32(0.25) * C.sinf(tau * f32(1.1) * t + f32(2.0) * phrase)
	return clamp32(f32(0.08) + f32(0.82) * shape * C.powf(syllable, f32(1.6)) * stress, 0.0, 1.0)
}

fn demo_loudness(time f32) f32 {
	return -58.0 + 28.0 * demo_level(time)
}

fn fixed_level(loudness f32) f32 {
	return clamp32((loudness + 40.0) / 30.0, 0.0, 1.0)
}

// --- spring ---------------------------------------------------------------

struct Spec {
	duration f32
	bounce   f32
}

fn spec_new(duration f32, bounce f32) Spec {
	return Spec{duration, bounce}
}

fn (s Spec) omega() f32 {
	return tau / fmax32(s.duration, f32(0.01))
}

fn (s Spec) zeta() f32 {
	if s.bounce >= 0.0 {
		return fmax32(1.0 - s.bounce, 0.0)
	}
	return 1.0 / fmax32(1.0 + s.bounce, f32(0.01))
}

const reduced_fade = Spec{f32(0.16), f32(0.0)}

fn fmin32(a f32, b f32) f32 {
	return if a < b { a } else { b }
}

fn fmin_int(a int, b int) int {
	return if a < b { a } else { b }
}

fn fmax32(a f32, b f32) f32 {
	return if a > b { a } else { b }
}

struct Spring {
mut:
	x      f32
	v      f32
	target f32
}

fn spring_at(x f32) Spring {
	return Spring{
		x:      x
		v:      0.0
		target: x
	}
}

fn (mut s Spring) jump(x f32) {
	s.x = x
	s.v = 0.0
	s.target = x
}

fn (mut s Spring) step_to(target f32, spec Spec, dt f32) {
	s.target = target
	s.step(spec, dt)
}

fn (mut s Spring) step(spec Spec, dt f32) {
	if dt <= 0.0 {
		return
	}
	omega := spec.omega()
	zeta := spec.zeta()
	x0 := s.x - s.target
	v0 := s.v
	if zeta < 1.0 - f32(1e-4) {
		decay := zeta * omega
		omega_d := omega * C.sqrtf(1.0 - zeta * zeta)
		ex := C.expf(-decay * dt)
		sin_v := C.sinf(omega_d * dt)
		cos_v := C.cosf(omega_d * dt)
		sin_over_d := sin_v / omega_d
		s.x = s.target + ex * (x0 * (cos_v + decay * sin_over_d) + v0 * sin_over_d)
		s.v = ex * (-x0 * omega * omega * sin_over_d + v0 * (cos_v - decay * sin_over_d))
	} else if zeta > 1.0 + f32(1e-4) {
		root := C.sqrtf(zeta * zeta - 1.0)
		root_sum := zeta + root
		slow_root := -omega / root_sum
		fast_root := -omega * root_sum
		denom := slow_root - fast_root
		slow_exp := C.expf(slow_root * dt)
		fast_exp := C.expf(fast_root * dt)
		p00 := (-fast_root * slow_exp + slow_root * fast_exp) / denom
		p01 := (slow_exp - fast_exp) / denom
		p10 := slow_root * fast_root * (fast_exp - slow_exp) / denom
		p11 := (slow_root * slow_exp - fast_root * fast_exp) / denom
		s.x = s.target + p00 * x0 + p01 * v0
		s.v = p10 * x0 + p11 * v0
	} else {
		ex := C.expf(-omega * dt)
		c := v0 + omega * x0
		s.x = s.target + (x0 + c * dt) * ex
		s.v = (v0 - omega * c * dt) * ex
	}
}

// --- tuning ---------------------------------------------------------------

enum Processing {
	sweep
	flow
	pulse
}

enum Placement {
	below
	menu_bar
	notch
}

struct Tuning {
mut:
	columns          f32
	rows             f32
	spacing          f32
	width            f32
	processing_width f32
	height           f32
	braid_speed      f32
	helix_cycles     f32
	gain             f32
	response         f32
	release          f32
	history_speed    f32
	phosphor         f32
	glow             f32
	saturation       f32
	shimmer_pass     f32
	shimmer          f32
	transition       f32
	bounce           f32
	auto_level       bool
	auto_release     f32
	noise_floor      f32
	processing       Processing
	placement        Placement
	pretend_notch    bool
	island_spread    f32
}

fn tuning_default() Tuning {
	return Tuning{
		columns:          43.0
		rows:             9.0
		spacing:          2.6
		width:            112.0
		processing_width: 76.0
		height:           plate_height
		braid_speed:      1.0
		helix_cycles:     1.6
		gain:             1.0
		response:         6.5
		release:          0.15
		history_speed:    150.0
		phosphor:         0.6
		glow:             1.0
		saturation:       1.0
		shimmer_pass:     0.55
		shimmer:          1.0
		transition:       0.30
		bounce:           0.15
		auto_level:       true
		auto_release:     3.0
		noise_floor:      -60.0
		processing:       .flow
		placement:        .below
		pretend_notch:    false
		island_spread:    28.0
	}
}

// Tuning::clamped walks KNOBS; every default is inside its range, so what is
// left is the finite guard and the row cap that decides how many dots exist.
fn (t Tuning) clamped() Tuning {
	mut o := t
	rows := fmin_int(max_dots / int(o.columns), max_rows)
	if int(o.rows) > rows {
		o.rows = f32(rows)
	}
	return o
}

// --- stages ---------------------------------------------------------------

enum Stage {
	recording
	processing
	done
	failed
}

struct Frame {
	stage         Stage
	visible       bool
	loudness      f32
	reduce_motion bool
}

struct Pose {
	width    f32
	height   f32
	opacity  f32
	scale    f32
	softness f32
	cool     f32
	fail     f32
	glow     f32
	grid     f32
	live     f32
	reveal   f32
	level    f32
	clock    f32
	done     f32
}

// --- voice and trace ------------------------------------------------------

struct Voice {
mut:
	level         f32
	reservoir     f32
	energy        f32
	kick          f32
	kick_velocity f32
	band          f32
}

fn (mut v Voice) step(raw f32, h f32) {
	previous := v.level
	time := if raw > v.level { f32(0.035) } else { f32(0.095) }
	v.level += (raw - v.level) * (1.0 - C.expf(-h / time))
	rise := fmax32((v.level - previous) / h, 0.0)
	v.reservoir += (1.75 * v.level * v.level - v.reservoir / 1.8) * h
	v.energy = 1.0 - C.expf(-v.reservoir * 1.45)
	w := tau * f32(1.3)
	z := f32(0.22)
	v.kick_velocity += (-w * w * v.kick - 2.0 * z * w * v.kick_velocity + 15.0 * rise + 2.2 * v.level) * h
	v.kick += v.kick_velocity * h
	time2 := if raw > v.band { f32(0.025) } else { f32(0.14) }
	v.band += (raw - v.band) * (1.0 - C.expf(-h / time2))
}

struct Trace {
mut:
	envelope             f32
	amplitude            f32
	amplitude_velocity   f32
	glow_fast            f32
	glow_spring          f32
	glow_spring_velocity f32
	glow_slow            f32
	glow                 f32
	phases               [4]f32
	history              [history * 5]f32
	head                 int
}

fn trace_new(phases [4]f32) Trace {
	return Trace{
		phases: phases
	}
}

fn (mut t Trace) tick(v &Voice, live f32, speed f32, tuning Tuning, h f32) {
	// follow(&mut value, target, rise, fall)
	t.envelope += (v.level - t.envelope) * (1.0 - C.expf(-h / if v.level > t.envelope { f32(0.022) } else { tuning.release }))
	w := tau * tuning.response
	z := f32(0.52)
	t.amplitude_velocity += (-w * w * (t.amplitude - t.envelope) - 2.0 * z * w * t.amplitude_velocity) * h
	t.amplitude += t.amplitude_velocity * h
	t.glow_fast += (v.level - t.glow_fast) * (1.0 - C.expf(-h / if v.level > t.glow_fast { f32(0.045) } else { f32(0.13) }))
	gw := tau * f32(3.6)
	gz := f32(0.5)
	t.glow_spring_velocity += (-gw * gw * (t.glow_spring - t.glow_fast) - 2.0 * gz * gw * t.glow_spring_velocity) * h
	t.glow_spring += t.glow_spring_velocity * h
	t.glow_slow += (v.level - t.glow_slow) * (1.0 - C.expf(-h / if v.level > t.glow_slow { f32(0.15) } else { f32(0.7) }))
	swell := 0.8 * fmax32(t.glow_spring - 0.25, 0.0) + 0.04 * fmax32(v.kick, -0.5)
	t.glow = fmin32(fmax32(swell, 0.0) + 0.42 * t.glow_slow + 0.2 * v.energy, f32(1.15)) * live
	span := 0.6 + 1.1 * fmin32(t.envelope * 1.6, 1.0)
	for i in 0 .. 4 {
		t.phases[i] = C.fmodf(t.phases[i] + h * tau * speeds[i] * span * speed, tau)
	}
	emphasis := 0.35 + 0.65 * fmin32(v.band / (v.band + 0.06), 2.0)
	offset := t.head * 5
	amplitude := fmax32(t.amplitude, 0.0) * live
	t.history[offset] = amplitude
	for c in 0 .. 4 {
		t.history[offset + 1 + c] = amplitude * base_amp[c] * emphasis
	}
	t.head = (t.head + 1) % history
}

fn (t &Trace) past(delay f32, channel int) f32 {
	d := fmin32(delay / step_h, f32(history - 2))
	i := int(C.floorf(d))
	k := d - f32(i)
	a := (t.head + 2 * history - 1 - i) % history
	b := (a + history - 1) % history
	return t.history[a * 5 + channel] * (1.0 - k) + t.history[b * 5 + channel] * k
}

// --- working light --------------------------------------------------------

struct Working {
	kind    int // 0 flow, 1 pulse
	offset  f32
	spacing f32
	time    f32
	period  f32
	speed   f32
}

fn (w Working) light(x f32, half_width f32) f32 {
	if w.kind == 0 {
		d := rem_euclid32(x - w.offset + w.spacing / 2.0, w.spacing) - w.spacing / 2.0
		return bump(d, 7.0)
	}
	d := if x < 0.0 { -x } else { x }
	mut light := f32(0.0)
	mut age := rem_euclid32(w.time, w.period)
	for age * w.speed < half_width + 12.0 && age <= w.time + f32(1e-4) {
		radius := age * w.speed
		fade := smoothstep(0.0, ring_birth, age) * (1.0 - 0.6 * smoothstep(0.3 * half_width, half_width, radius))
		light += bump(d - radius, 6.0) * fade
		age += w.period
	}
	return fmin32(light, 1.0)
}

// --- envelope and scan ----------------------------------------------------

struct Scan {
	helix    f32
	decay    f32
	tail     f32
	grid     f32
	kind     int // envelope tag
	// Enter
	reach  f32
	head   f32
	unfold f32
	// Process
	iron  f32
	front f32
	// Work / Clear
	working    Working
	swell      f32
	half_width f32
	// Clear
	beam    f32
	beam_at f32
	field   f32
	glow    f32
}

fn (s Scan) at(x f32) (f32, f32, f32) {
	match s.kind {
		0 { // Enter
			d := if x < 0.0 { -x } else { x }
			drawn := s.unfold * (1.0 - smoothstep(fmax32(s.reach - 14.0, 0.0), fmax32(s.reach, f32(0.001)), d))
			amplitude := drawn * (1.0 - smoothstep(fmax32(s.reach - 22.0, 0.0), fmax32(s.reach - 3.0, f32(0.001)), d))
			beam := s.head * bump(d - s.reach, 6.0)
			swell := 1.8 * s.unfold * (s.head / 2.8) * bump(d - fmax32(s.reach - 14.0, 0.0), 14.0)
			return amplitude, amplitude + beam, swell
		}
		1 { // Process
			return s.iron, s.iron + s.head * bump(x - s.front, 5.0), 0.0
		}
		2 { // Work
			light := s.working.light(x, s.half_width)
			return 1.0, 1.0 + s.head * light, s.swell * light
		}
		else { // Clear
			d := if x < 0.0 { -x } else { x }
			keep := s.field * smoothstep(s.front - 12.0, s.front - 2.0, d)
			light := s.working.light(x, s.half_width)
			return keep, keep * (1.0 + s.glow * light) + s.head * bump(d - s.front, 6.0) + s.beam * bump(x - s.beam_at, 5.0), keep * s.swell * light
		}
	}
}

// --- auto level -----------------------------------------------------------

struct AutoLevel {
mut:
	peak f32
	room f32
}

fn auto_level_default() AutoLevel {
	return AutoLevel{
		peak: -30.0
		room: -55.0
	}
}

fn (mut a AutoLevel) step(loudness f32, h f32, release f32, noise_floor f32) f32 {
	db := fmax32(loudness, -120.0)
	room_time := if db < a.room { room_fall } else { room_rise }
	a.room += (db - a.room) * (1.0 - C.expf(-h / fmax32(room_time, f32(1e-3))))
	lowest := fmax32(a.room, noise_floor) + auto_min_span
	if db > a.peak {
		a.peak += (db - a.peak) * (1.0 - C.expf(-h / fmax32(auto_attack, f32(1e-3))))
	} else {
		a.peak += (lowest - a.peak) * (1.0 - C.expf(-h / fmax32(release, f32(1e-3))))
	}
	a.peak = fmax32(a.peak, lowest)
	return a.level(db, noise_floor)
}

fn (a &AutoLevel) level(loudness f32, noise_floor f32) f32 {
	low := fmax32(fmax32(a.room, noise_floor) + auto_room_margin, a.peak - auto_range)
	return clamp32((loudness - low) / fmax32(a.peak - low, 1.0), 0.0, 1.0)
}

// --- scope ----------------------------------------------------------------

struct Scope {
mut:
	tuning        Tuning
	stage         Stage
	elapsed       f32
	speed_at_done f32
	done_from     f32
	flow_offset   f32
	flow_turn     f32
	auto          AutoLevel
	level         f32
	voices        [2]Voice
	traces        [2]Trace
	live          f32
	carrier       f32
	time          f32
	steps         u64
	pending       f32
	reduce_motion bool
	columns       int
	rows          int
	head          [2][]f32
	tail          [2][]f32
	dots          [][2]f32
	ys            [2][]f32
	brightness    [2][]f32
	grid          f32
	width         Spring
	opacity       Spring
	scale         Spring
	softness      Spring
	cool          Spring
	fail          Spring
}

fn scope_new(tuning Tuning) &Scope {
	mut s := &Scope{
		tuning:     tuning.clamped()
		stage:      .recording
		auto:       auto_level_default()
		traces:     [trace_new([f32(0.1), 1.7, 3.3, 4.6]!), trace_new([f32(2.4), 0.6, 5.1, 1.9]!)]!
		width:      spring_at(start_width)
		opacity:    spring_at(0.0)
		scale:      spring_at(hidden_scale)
		softness:   spring_at(hidden_softness)
		cool:       spring_at(0.0)
		fail:       spring_at(0.0)
	}
	s.resize()
	return s
}

fn (mut s Scope) resize() {
	columns := int(s.tuning.columns)
	rows := int(s.tuning.rows)
	if columns == s.columns && rows == s.rows {
		return
	}
	s.columns = columns
	s.rows = rows
	dots := columns * rows
	samples := (columns - 1) * samples_per_column + 1
	s.head = [[f32(0)].repeat(dots), [f32(0)].repeat(dots)]!
	s.tail = [[f32(0)].repeat(dots), [f32(0)].repeat(dots)]!
	s.dots = [[f32(0), 0]!].repeat(dots)
	s.ys = [[f32(0)].repeat(samples), [f32(0)].repeat(samples)]!
	s.brightness = [[f32(0)].repeat(samples), [f32(0)].repeat(samples)]!
}

fn (s &Scope) pose() Pose {
	mut glow_sum := f32(0.0)
	for k in 0 .. 2 {
		glow_sum += s.traces[k].glow
	}
	return Pose{
		width:    fmax32(s.width.x, s.tuning.height)
		height:   s.tuning.height
		opacity:  clamp32(s.opacity.x, 0.0, 1.0)
		scale:    fmax32(s.scale.x, f32(0.01))
		softness: clamp32(s.softness.x, 0.0, hidden_softness)
		cool:     clamp32(s.cool.x, 0.0, 1.0)
		fail:     clamp32(s.fail.x, 0.0, 1.0)
		glow:     glow_sum / 2.0 * s.tuning.glow
		grid:     s.grid
		live:     s.live
		reveal:   fmax32((s.scale.x - hidden_scale) / (1.0 - hidden_scale), 0.0)
		level:    clamp32(s.voices[0].level, 0.0, 1.0)
		clock:    if s.reduce_motion { 0.0 } else { s.time }
		done:     if s.stage == .done { 1.0 } else { 0.0 }
	}
}

fn (s &Scope) settled() bool {
	return s.opacity.target == 0.0 && s.opacity.x < 0.002
}

fn (mut s Scope) advance(dt f32, frame Frame) {
	if frame.stage != s.stage {
		if frame.stage == .done {
			s.arm_done()
		}
		if frame.stage == .processing {
			s.flow_offset = -s.width.x / 2.0 - 4.0
		}
		s.stage = frame.stage
		s.elapsed = 0.0
	}
	s.reduce_motion = frame.reduce_motion
	s.pending += clamp32(dt, 0.0, 0.25)
	for s.pending >= step_h {
		s.pending -= step_h
		s.step(frame)
	}
}

fn (mut s Scope) step(frame Frame) {
	h := step_h
	tuning := s.tuning
	recording := s.stage == .recording && frame.visible
	mut level := f32(0.0)
	if recording {
		s.level = if tuning.auto_level {
			s.auto.step(frame.loudness, h, tuning.auto_release, tuning.noise_floor)
		} else {
			fixed_level(frame.loudness)
		}
		level = clamp32(s.level * tuning.gain, 0.0, 1.0)
	} else {
		s.level = 0.0
		level = 0.0
	}
	s.voices[0].step(level, h)
	s.voices[1].step(level * 0.85, h)
	live_target := if recording { f32(1.0) } else { f32(0.0) }
	s.live += (live_target - s.live) * (1.0 - C.expf(-h / f32(0.55)))
	speed := if frame.reduce_motion { f32(0.0) } else { tuning.braid_speed }
	for k in 0 .. 2 {
		s.traces[k].tick(&s.voices[k], s.live, speed, tuning, h)
	}
	energy := fmax32(s.voices[0].energy, s.voices[1].energy)
	working := s.stage == .processing || s.stage == .done
	flowing := working && tuning.processing == .flow
	s.flow_turn += ((if flowing { f32(1.0) } else { f32(0.0) }) - s.flow_turn) * (1.0 - C.expf(-h / f32(0.25)))
	if working {
		s.flow_offset += s.flow_speed() * h
	}
	rest := carrier_rest + 0.22 * energy
	turn := rest + (s.flow_turn_hz() - rest) * s.flow_turn
	s.carrier = C.fmodf(s.carrier + h * tau * turn * speed, tau)

	width := match s.stage {
		.recording { tuning.width }
		.processing, .done { tuning.processing_width }
		.failed { s.width.target }
	}
	cool_target := if s.stage == .processing || s.stage == .done { f32(1.0) } else { f32(0.0) }
	fail_target := if s.stage == .failed { f32(1.0) } else { f32(0.0) }
	shown := if frame.visible { f32(1.0) } else { f32(0.0) }
	fade := spec_new(tuning.transition, 0.0)
	bouncy := spec_new(tuning.transition, tuning.bounce)
	if frame.reduce_motion {
		s.width.jump(width)
		s.scale.jump(1.0)
		s.softness.jump(0.0)
		s.opacity.step_to(shown, reduced_fade, h)
		s.cool.step_to(cool_target, reduced_fade, h)
		s.fail.step_to(fail_target, reduced_fade, h)
	} else {
		s.width.step_to(width, bouncy, h)
		s.opacity.step_to(shown, fade, h)
		s.scale.step_to(if frame.visible { f32(1.0) } else { hidden_scale }, bouncy, h)
		s.softness.step_to(if frame.visible { f32(0.0) } else { hidden_softness }, fade, h)
		s.cool.step_to(cool_target, fade, h)
		s.fail.step_to(fail_target, fade, h)
	}
	s.elapsed += h
	s.time += h
	s.steps += 1
	if s.steps % 2 == 0 {
		s.beam(2.0 * h)
	}
}

fn (s &Scope) work_period() f32 {
	return 2.0 * fmax32(s.tuning.shimmer_pass, f32(0.05))
}

fn (s &Scope) flow_spacing() f32 {
	return flow_spacing_k * s.tuning.processing_width
}

fn (s &Scope) flow_speed() f32 {
	return s.flow_spacing() / s.work_period()
}

fn (s &Scope) flow_turn_hz() f32 {
	return s.flow_speed() * s.tuning.helix_cycles / fmax32(s.width.x, f32(1.0))
}

fn (s &Scope) pulse_speed() f32 {
	return (s.tuning.processing_width / 2.0 + 12.0) / (1.4 * s.work_period())
}

fn (s &Scope) working(time f32) Working {
	if s.tuning.processing == .pulse {
		return Working{kind: 1, time: time, period: s.work_period(), speed: s.pulse_speed()}
	}
	return Working{kind: 0, offset: s.flow_offset, spacing: s.flow_spacing()}
}

fn (mut s Scope) arm_done() {
	s.speed_at_done = 1.5 * s.pulse_speed()
	s.done_from = if s.stage == .processing { s.elapsed } else { f32(0.0) }
}

fn (s &Scope) process_head(elapsed f32) f32 {
	pass := fmax32(s.tuning.shimmer_pass, f32(0.05))
	return (2.2 + fabs32(C.sinf(pi * (elapsed / pass + 0.5)))) * smoothstep(0.0, 0.14, elapsed) * s.tuning.shimmer
}

fn fabs32(x f32) f32 {
	return if x < 0.0 { -x } else { x }
}

fn (s &Scope) process_front(elapsed f32, width f32) f32 {
	pass := fmax32(s.tuning.shimmer_pass, f32(0.05))
	position := 0.5 - 0.5 * C.cosf(pi * (elapsed / pass + 0.5))
	return -width / 2.0 + pass_inset + (width - 2.0 * pass_inset) * position
}

fn (s &Scope) scan(width f32) Scan {
	e := s.elapsed
	if s.stage == .failed || s.reduce_motion {
		return Scan{kind: 0, helix: 1.0, decay: 1.0, tail: 1.0, grid: 1.0, reach: 1e4, head: 0.0, unfold: 1.0}
	}
	if s.stage == .recording {
		return Scan{
			kind:   0
			helix:  1.0
			decay:  1.0
			tail:   1.0
			grid:   fmin32(e / 0.3, 1.0)
			reach:  (width / 2.0 + 12.0) * pass_position(e / enter_time)
			head:   2.8 * (1.0 - smoothstep(0.08, enter_time, e))
			unfold: smoothstep(0.0, 0.1, e)
		}
	}
	if s.stage == .processing && s.tuning.processing != .sweep {
		enter := smoothstep(0.0, 0.35, e)
		return Scan{
			kind:       2
			helix:      1.0 + (work_helix - 1.0) * enter
			decay:      1.0
			tail:       1.0
			grid:       1.0
			working:    s.working(e)
			head:       2.5 * smoothstep(0.05, 0.3, e) * s.tuning.shimmer
			swell:      0.9 * enter
			half_width: width / 2.0
		}
	}
	if s.stage == .done {
		target := width / 2.0 + 8.0
		front := hermite(0.0, s.speed_at_done, target, e / wipe)
		sweep := s.tuning.processing == .sweep
		return Scan{
			kind:       3
			helix:      if sweep { f32(0.0) } else { work_helix }
			decay:      1.0 - 0.6 * smoothstep(0.0, 0.12, e)
			tail:       1.0 - smoothstep(0.0, 0.15, e)
			grid:       1.0 - smoothstep(0.2, 0.4, e)
			front:      front
			head:       2.8 * smoothstep(0.0, 0.04, e) * (1.0 - smoothstep(0.22, 0.32, e))
			beam:       if sweep && s.done_from > 0.0 { s.process_head(s.done_from + e) * (1.0 - smoothstep(0.0, beam_fade, e)) } else { f32(0.0) }
			beam_at:    s.process_front(s.done_from + e, width)
			field:      if sweep { f32(0.0) } else { f32(1.0) }
			working:    s.working(s.done_from + e)
			glow:       (if sweep { f32(0.0) } else { f32(2.5) }) * s.tuning.shimmer * (1.0 - smoothstep(0.0, 0.18, e))
			swell:      0.9
			half_width: width / 2.0
		}
	}
	iron := 1.0 - smoothstep(0.0, 0.28, e)
	head := s.process_head(e)
	return Scan{
		kind:  1
		helix: iron
		decay: 1.0
		tail:  1.0
		grid:  1.0
		iron:  iron
		front: s.process_front(e, width)
		head:  head
	}
}

fn (mut s Scope) beam(hb f32) {
	columns := s.columns
	rows := s.rows
	sub := samples_per_column
	samples := (columns - 1) * sub + 1
	pitch := s.tuning.spacing
	width := fmax32(s.width.x, s.tuning.height)
	scan := s.scan(width)
	s.grid = scan.grid
	mid := (f32(rows) - 1.0) / 2.0
	half := mid - 0.55
	breath := if s.reduce_motion { f32(0.5) } else { 0.5 + 0.5 * C.sinf(s.time * tau / breath_period) }
	rest := (0.55 + 0.35 * breath) * (0.4 + 0.6 * s.live) * scan.helix
	half_width := width / 2.0
	for k in 0 .. 2 {
		trace := &s.traces[k]
		sign := if k == 0 { f32(1.0) } else { f32(-1.0) }
		mut ys := s.ys[k]
		mut brightness := s.brightness[k]
		for si in 0 .. samples {
			x := (f32(si) / f32(sub) - (f32(columns) - 1.0) / 2.0) * pitch
			if fabs32(x) > half_width {
				ys[si] = mid
				brightness[si] = 0.0
				continue
			}
			amplitude, bright, swell := scan.at(x)
			own := fabs32(x)
			xn := (x + half_width) / width
			ends := fmin32(smoothstep(-half_width + 3.0, -half_width + 17.0, x), smoothstep(-half_width + 3.0, -half_width + 17.0, -x))
			reach := 1.0 - 0.8 * smoothstep(14.0, half_width, own)
			delay := own / s.tuning.history_speed
			a := trace.past(delay, 0)
			mut spread := f32(0.0)
			for c in 0 .. 4 {
				spread += trace.past(delay, 1 + c) * C.sinf(tau * spatial[c] * xn - trace.phases[c])
			}
			helix := (rest + swell + half * 0.55 * a * reach) * C.sinf(tau * s.tuning.helix_cycles * xn - s.carrier)
			y := half * C.tanhf((helix + half * 0.7 * spread * reach) / half) * ends * amplitude
			ys[si] = mid - sign * y
			spatial_amt := (0.3 + 0.7 * fmin32(a * 1.8, 1.0)) * (0.45 + 0.55 * ends)
			brightness[si] = spatial_amt * amplitude + 0.36 * fmax32(bright - amplitude, 0.0)
		}
		for si in 0 .. samples {
			prev := if si == 0 { ys[0] } else { ys[si - 1] }
			next_i := if si + 1 > samples - 1 { samples - 1 } else { si + 1 }
			slope := (ys[next_i] - prev) * f32(sub) / 2.0
			brightness[si] *= 1.0 - 0.55 + 0.55 / C.sqrtf(1.0 + 0.22 * slope * slope)
		}
	}
	head_keep := C.expf(-hb / (phosphor_head * scan.decay))
	tail_keep := C.expf(-hb / (s.tuning.phosphor * scan.decay))
	dx := 1.0 / f32(sub)
	for i in 0 .. columns {
		s0 := if i > 3 { i - 3 } else { 0 } * sub
		s1 := fmin_int((i + 3) * sub, samples - 1)
		for j in 0 .. rows {
			n := j * columns + i
			mut now := f32(0.0)
			mut total := f32(0.0)
			mut lit := [f32(0), 0]!
			for k in 0 .. 2 {
				ys := s.ys[k]
				mut best := max_f32
				mut nearest := i * sub
				for si in s0 .. s1 {
					ay := ys[si]
					dy := ys[si + 1] - ay
					px := f32(i) - f32(si) * dx
					py := f32(j) - ay
					t := clamp32((px * dx + py * dy) / (dx * dx + dy * dy), 0.0, 1.0)
					ex := px - t * dx
					ey := py - t * dy
					d2 := ex * ex + ey * ey
					if d2 < best {
						best = d2
						nearest = si
					}
				}
				bright := s.brightness[k][nearest]
				on_beam := C.expf(-best / 0.25)
				instant := fmin32(on_beam + 0.5 * C.expf(-C.sqrtf(best) / 0.8), f32(1.2)) * bright
				core := on_beam * bright
				s.head[k][n] = fmax32(s.head[k][n] * head_keep, core)
				s.tail[k][n] = fmax32(s.tail[k][n] * tail_keep, core)
				light := fmax32(fmax32(instant, s.head[k][n]), 0.55 * scan.tail * s.tail[k][n])
				lit[k] = light
				now += instant
				total += light
			}
			power := 1.0 - (1.0 - fmin32(lit[0], 1.0)) * (1.0 - fmin32(lit[1], 1.0))
			s.dots[n] = [clamp32(power, 0.0, 1.0), fmin32(now / fmax32(total, f32(1e-4)), 1.0)]!
		}
	}
}

const max_f32 = f32(3.4028234663852886e38)
