// Port of src/dictation/indicator.rs: the state machine above the scope that
// turns dictation events into the Frame the simulation steps with.
module main

import os

const silent = f32(-120.0)
const processing_min_duration = f64(0.200)
const completed_visible_duration = f64(0.100)

enum Phase {
	hidden
	recording
	transcribing
	completed
	cancelled
	failed
}

struct StagePick {
	stage Stage
	ok    bool
}

fn phase_stage(p Phase) StagePick {
	return match p {
		.recording { StagePick{Stage.recording, true} }
		.transcribing { StagePick{Stage.processing, true} }
		.completed { StagePick{Stage.done, true} }
		.failed { StagePick{Stage.failed, true} }
		.hidden, .cancelled { StagePick{Stage.recording, false} }
	}
}

fn phase_visible_duration(p Phase) f64 {
	return match p {
		.completed { completed_visible_duration }
		.cancelled { 0.0 }
		.failed { 1.2 }
		else { -1.0 }
	}
}

fn loudness_db(rms f32) f32 {
	return 20.0 * C.log10f(f32_max(rms, 0.0) + f32(1e-6))
}

struct Indicator {
mut:
	phase              Phase
	capturing          bool
	pending_jobs       int
	phase_started      f64
	working_since      f64
	completion_pending bool
	scope              &Scope = unsafe { nil }
	stage              Stage
	tuning             Tuning
	loudness           f32 = silent
	demo_voice         bool
	demo_time          f32
	active             bool
}

fn indicator_new(tuning Tuning) &Indicator {
	return &Indicator{
		phase:         .hidden
		scope:         scope_new(tuning)
		stage:         .recording
		tuning:        tuning
		phase_started: 0.0
		working_since: 0.0
	}
}

fn (mut m Indicator) show_pipeline(now f64) {
	if m.capturing {
		if m.phase != .recording {
			m.phase = .recording
			m.phase_started = now
		}
		return
	}
	if m.pending_jobs > 0 {
		if m.phase != .transcribing {
			m.working_since = now
		}
		m.phase = .transcribing
		m.phase_started = now
		m.completion_pending = false
	}
}

fn (mut m Indicator) on_started(now f64) {
	m.demo_voice = false
	m.capturing = true
	// A new take starts with no outstanding jobs: without this, a paste or
	// completion result left over from the previous take satisfies
	// on_completed() and ends this take's HUD early.
	m.pending_jobs = 0
	m.phase = .recording
	m.phase_started = now
	m.completion_pending = false
	m.loudness = silent
	m.stage = .recording
	m.scope = scope_new(m.tuning)
}

fn (mut m Indicator) on_submitted(now f64) {
	m.capturing = false
	m.pending_jobs = 1
	m.show_pipeline(now)
}

fn (mut m Indicator) on_cancelled(now f64) {
	m.capturing = false
	m.pending_jobs = 0
	m.completion_pending = false
	m.phase = .cancelled
	m.phase_started = now
}

fn (mut m Indicator) on_failed(now f64) {
	m.capturing = false
	m.pending_jobs = 0
	m.completion_pending = false
	m.phase = .failed
	m.phase_started = now
}

fn (mut m Indicator) on_completed(now f64) {
	if m.pending_jobs == 0 {
		return
	}
	m.pending_jobs = 0
	if m.capturing {
		m.show_pipeline(now)
		return
	}
	if m.phase != .transcribing {
		m.phase = .transcribing
		m.working_since = now
	}
	m.completion_pending = true
}

fn (mut m Indicator) step(now f64, dt f32, reduce bool) DotFrame {
	d := clamp32(dt, f32(1.0) / 240.0, f32(1.0) / 20.0)
	if m.completion_pending && now - m.working_since >= processing_min_duration {
		m.phase = .completed
		m.phase_started = now
		m.completion_pending = false
	}
	elapsed := now - m.phase_started
	vd := phase_visible_duration(m.phase)
	terminal_finished := vd >= 0.0 && elapsed >= vd
	visible := m.phase != .hidden && !terminal_finished
	pick := phase_stage(m.phase)
	if pick.ok {
		m.stage = pick.stage
	}
	mut loud := m.loudness
	if m.demo_voice {
		m.demo_time += d
		loud = demo_loudness(m.demo_time)
	}
	m.scope.advance(d, Frame{
		stage:         m.stage
		visible:       visible
		loudness:      loud
		reduce_motion: reduce
	})
	m.active = visible || !m.scope.settled()
	return DotFrame{
		pose:    m.scope.pose()
		columns: m.scope.columns
		rows:    m.scope.rows
		dots:    pack_dots(m.scope.dots)
	}
}

struct DotFrame {
	pose    Pose
	columns int
	rows    int
	dots    []u16
}

// indicator.rs:452: (v.clamp(0,1) * 65535.0).round() as u16, power then fresh.
fn pack_dots(dots [][2]f32) []u16 {
	mut out := []u16{len: dots.len * 2}
	for i, d in dots {
		for c in 0 .. 2 {
			v := clamp32(d[c], 0.0, 1.0) * 65535.0
			// f32 round-half-away-from-zero, as Rust's f32::round.
			r := C.floorf(v + 0.5)
			out[i * 2 + c] = u16(r)
		}
	}
	return out
}

// --- replay ---------------------------------------------------------------
//
// The schedule from src/rune_hud/tests.rs:50-77: 330 frames at 1/60 s,
// demo_loudness for the first 3 s, then Submitted at 3.0, Processing at 3.6
// and JobCompleted at 4.4.

fn run_replay(out_dir string) {
	os.mkdir_all(out_dir) or { panic(err) }
	mut m := indicator_new(tuning_default())
	mut dots := []u8{cap: 330 * 4096}
	mut meta := []string{}
	meta << 'frame\tt\tcolumns\trows\twidth\theight\topacity\tscale\tsoftness\tcool\tglow\tgrid\tlive\tdone\treveal\tfail'
	mut events := [Event{0.0, 'started'}, Event{3.0, 'submitted'}, Event{3.6, 'processing'}, Event{4.4, 'completed'}]!
	mut ev_i := 0
	for n in 0 .. 330 {
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
		mut frame := []u8{len: 4096}
		for i in 0 .. fmin_int(f.dots.len, 2048) {
			frame[i * 2] = u8(f.dots[i] & 0xff)
			frame[i * 2 + 1] = u8(f.dots[i] >> 8)
		}
		dots << frame
		p := f.pose
		meta << '${n}\t${t:.6f}\t${f.columns}\t${f.rows}\t${p.width:.6f}\t${p.height:.6f}\t${p.opacity:.6f}\t${p.scale:.6f}\t${p.softness:.6f}\t${p.cool:.6f}\t${p.glow:.6f}\t${p.grid:.6f}\t${p.live:.6f}\t${p.done:.6f}\t${p.reveal:.6f}\t${p.fail:.6f}'
	}
	os.write_file_array('${out_dir}/dots.bin', dots) or { panic(err) }
	os.write_file_array('${out_dir}/meta.tsv', meta.join('\n').bytes()) or { panic(err) }
	println('frames=330 dot_bytes=4096 total=${dots.len}')
}

struct Event {
	at   f64
	kind string
}
