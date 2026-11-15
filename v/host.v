// Dictation host: mic -> 16 kHz f32 -> VAD segmenter -> shim -> clipboard
// paste, with the existing Indicator driving the Dot scope.
module main

import sync
import time

const min_recording_samples = 3200 // 0.2 s at 16 kHz
const seg_min_samples = 16000
const seg_ctx_samples = 3200
const vad_ctx_samples = 16384
const seg_poll_ms = 500
const seg_silence_ms = 500

// A segment used to close only on `seg_silence_ms` of silence, so continuous
// speech never checkpointed at all: in the log a 120 s take closed its last
// segment at 88.5 s and the whole 31.6 s remainder was transcribed in one tail
// call after the key came up (7,679 ms). Past this many unsegmented samples the
// worker cuts anyway, which bounds release-to-text latency at one segment.
const seg_force_cut_samples = 96000 // 6 s at 16 kHz
const seg_force_search_samples = 19200 // 1.2 s window to look for the quietest cut
const seg_frame_samples = 320 // 20 ms at 16 kHz

enum HostState {
	idle
	recording
	processing
	cancelling
}


struct TranscribeResult {
mut:
	text       string
	err        string
	load_ms    f64
	infer_ms   f64
	trim_ms    int
	samples    int
	generation int
}

struct Host {
mut:
	cfg          HostConfig
	asr          &AsrShim = unsafe { nil }
	capture      Capture
	state        HostState
	generation   int
	ch           chan TranscribeResult
	seg_threads  []thread
	seg_mu       sync.Mutex
	seg_texts    []string
	seg_cursor   int
	seg_active   bool
	seg_fail     int
	last_use     f64
	last_wav     string
	busy         bool
}

fn new_host(cfg HostConfig) &Host {
	return &Host{
		cfg:      cfg
		asr:      &AsrShim{}
		ch:       chan TranscribeResult{cap: 4}
		state:    .idle
		last_wav: '${cfg.data_dir}\\hexv-last.wav'
	}
}

// trim_trailing_silence is the same algorithm and constants as
// odin-hex/src/transcribe.odin: 20 ms frames, -30 dB relative floor, five-frame
// speech runs, 250 ms tail pad, and no cut shorter than 100 ms.
fn trim_trailing_silence(samples []f32) ([]f32, int) {
	rate := 16000
	frame := rate * 20 / 1000
	if samples.len < frame * 8 {
		return samples, 0
	}
	mut peak_ms := f32(0)
	frames := (samples.len + frame - 1) / frame
	mut energy := []f32{len: frames}
	for i in 0 .. frames {
		off := i * frame
		end := if off + frame < samples.len { off + frame } else { samples.len }
		mut acc := f32(0)
		for s in samples[off..end] {
			acc += s * s
		}
		energy[i] = acc / f32(frame)
		if energy[i] > peak_ms {
			peak_ms = energy[i]
		}
	}
	if peak_ms < f32(1e-8) {
		return samples, 0
	}
	limit := peak_ms * f32(0.001)
	mut last := 0
	mut run := 0
	for i in 0 .. frames {
		if energy[i] > limit {
			run++
			if run >= 5 {
				last = (i + 1) * frame
			}
		} else {
			run = 0
		}
	}
	mut keep := last + rate * 250 / 1000
	if keep > samples.len {
		keep = samples.len
	}
	cut := samples.len - keep
	if cut < rate * 100 / 1000 {
		return samples, 0
	}
	return samples[..keep], cut * 1000 / rate
}

fn preload_worker(asr &AsrShim, model_path string, threads int, vad_path string) {
	asr.ensure_vad(vad_path) or { hexv_log('preload: ${err}') }
	asr.ensure_model(model_path, threads) or { hexv_log('preload: ${err}') }
}

// segment_worker polls on a deadline rather than sleeping a fixed 500 ms after
// each poll. The old loop slept *after* the poll finished, so with 0.34-0.55 s
// of inference the real cadence was 0.9-1.05 s and a forced cut at 6 s landed at
// 6-7 s. It also slept before the first poll, which delayed the first checkpoint
// of every take by a full interval.
//
// The wait is sliced so stop_segmenter() is not held hostage by it: a release
// used to wait out whatever was left of the sleep, up to 500 ms, with nothing in
// flight.
fn segment_worker(mut h Host) {
	mut next_poll := time.sys_mono_now()
	for h.segmenter_running() {
		h.segment_poll()
		next_poll += time.Duration(seg_poll_ms) * time.millisecond
		for h.segmenter_running() {
			now := time.sys_mono_now()
			if now >= next_poll {
				break
			}
			remain := next_poll - now
			if remain > 2 * time.millisecond {
				time.sleep(2 * time.millisecond)
			} else {
				time.sleep(remain)
			}
		}
	}
}

fn (mut h Host) segmenter_running() bool {
	h.seg_mu.lock()
	defer {
		h.seg_mu.unlock()
	}
	return h.seg_active
}

// quietest_frame_end returns the sample just past the lowest-energy 20 ms frame
// in [from, to), so a forced cut lands in the quietest part of the window rather
// than in the middle of a word. Returns `to` when the window holds no whole
// frame.
fn quietest_frame_end(samples []f32, from int, to int) int {
	if to - from < seg_frame_samples {
		return to
	}
	mut best := from
	mut best_energy := f32(-1.0)
	mut i := from
	for i + seg_frame_samples <= to {
		mut acc := f32(0.0)
		for s in samples[i..i + seg_frame_samples] {
			acc += s * s
		}
		if best_energy < 0.0 || acc < best_energy {
			best_energy = acc
			best = i
		}
		i += seg_frame_samples
	}
	return best + seg_frame_samples
}

// segment_poll runs entirely on the segment worker: VAD, then inference. The
// paint thread only pumps the mic and draws. Only the suffix is copied, and
// the VAD gets 1.024 s of left context so its splice point stays close to the
// old whole-buffer answer.
fn (mut h Host) segment_poll() {
	h.seg_mu.lock()
	mut cursor := h.seg_cursor
	h.seg_mu.unlock()

	mut lo := cursor - vad_ctx_samples
	if lo < 0 {
		lo = 0
	}
	// The VAD consumes 512-sample frames; keeping its start on that grid makes
	// a suffix call match the whole-buffer boundary instead of shifting it.
	lo -= lo % 512
	sfx := h.capture.snapshot_16k_from(lo)
	if sfx.len == 0 {
		return
	}

	t_vad := time.sys_mono_now()
	mut rel_end := int(h.asr.vad_speech_end(sfx, seg_silence_ms))
	vad_ms := f64(time.sys_mono_now() - t_vad) / 1_000_000.0
	mut forced := false
	if rel_end < 0 {
		// No silence has closed a segment. Without this a monologue never
		// checkpoints, because the cursor only moves on a closed segment and
		// stop() then hands the whole remainder to one tail inference.
		need := cursor + seg_force_cut_samples - lo
		if need > 0 && sfx.len >= need {
			mut from := need - seg_force_search_samples
			floor := (cursor - lo) + seg_min_samples
			if from < floor {
				from = floor
			}
			if from < 0 {
				from = 0
			}
			if from < need {
				rel_end = quietest_frame_end(sfx, from, need)
				forced = true
			}
		}
		if !forced {
			// No segment is closed yet: defer, do not retry/advance.
			return
		}
	}
	abs_end := lo + rel_end

	h.seg_mu.lock()
	cursor = h.seg_cursor
	h.seg_mu.unlock()
	if abs_end <= cursor + seg_min_samples || abs_end <= cursor || rel_end > sfx.len {
		return
	}

	mut slice_start := cursor - seg_ctx_samples
	if slice_start < 0 {
		slice_start = 0
	}
	slice_start -= lo
	if slice_start < 0 {
		slice_start = 0
	}
	if rel_end <= slice_start || rel_end > sfx.len {
		return
	}
	// If the session is not open yet, leave this audio for the tail instead of
	// spinning on the same span.
	if !h.asr.is_loaded() {
		return
	}

	slice := sfx[slice_start..rel_end]
	trimmed, trim_ms := trim_trailing_silence(slice)
	t_infer := time.sys_mono_now()
	text, _ := h.asr.transcribe(trimmed, h.cfg.language) or {
		h.seg_mu.lock()
		h.seg_fail += 1
		fails := h.seg_fail
		if fails >= 3 {
			h.seg_cursor = abs_end
			h.seg_fail = 0
		}
		h.seg_mu.unlock()
		hexv_log('segment inference failed: ${err} (fail=${fails})')
		return
	}
	elapsed := f64(time.sys_mono_now() - t_infer) / 1_000_000.0

	h.seg_mu.lock()
	if h.seg_active {
		if text.len > 0 {
			h.seg_texts << text
		}
		h.seg_cursor = abs_end
		h.seg_fail = 0
	}
	h.seg_mu.unlock()
	hexv_log('segment boundary: ${cursor}..${abs_end} (${abs_end - cursor} new samples) forced=${forced} vad=${vad_ms:.0f} ms')
	hexv_log('segment: samples=${trimmed.len} trim=${trim_ms} ms inference=${elapsed:.0f} ms chars=${text.len}')
}

fn tail_worker(asr &AsrShim, model_path string, threads int, language string,
	tail []f32, prefix []string, generation int, ch chan TranscribeResult) {
	mut result := TranscribeResult{generation: generation}
	if tail.len == 0 {
		result.text = prefix.join(' ')
		ch <- result
		return
	}
	trimmed, trim_ms := trim_trailing_silence(tail)
	result.trim_ms = trim_ms
	result.samples = trimmed.len
	t0 := time.sys_mono_now()
	result.load_ms = asr.ensure_model(model_path, threads) or {
		result.err = err.msg()
		ch <- result
		return
	}
	model_wait := f64(time.sys_mono_now() - t0) / 1_000_000.0
	text, infer_ms := asr.transcribe(trimmed, language) or {
		result.err = err.msg()
		ch <- result
		return
	}
	result.infer_ms = infer_ms
	result.text = text
	if prefix.len > 0 {
		mut parts := prefix.clone()
		if text.len > 0 {
			parts << text
		}
		result.text = parts.join(' ')
	}
	hexv_log('tail: model-wait=${model_wait:.0f} ms inference=${infer_ms:.0f} ms samples=${trimmed.len} trim=${trim_ms} ms prefix=${prefix.len}')
	ch <- result
}

fn (mut h Host) start(now f64) ! {
	h.last_use = now
	if h.state == .recording {
		return error('already recording')
	}
	if h.busy || h.state == .processing || h.state == .cancelling {
		return error('model busy')
	}
	h.stop_segmenter()
	h.capture.start()!
	h.generation++
	h.seg_mu.lock()
	h.seg_texts.clear()
	h.seg_cursor = 0
	h.seg_fail = 0
	h.seg_active = true
	h.seg_mu.unlock()
	h.seg_threads << spawn segment_worker(mut h)
	h.state = .recording
	power_eco(false)
	spawn preload_worker(h.asr, h.cfg.model_path(), h.cfg.threads, h.cfg.vad_path())
	hexv_log('listening: model preload started')
}

fn (mut h Host) pump_level() f32 {
	if h.state != .recording {
		return -120.0
	}
	h.capture.pump()
	return h.capture.rms_db()
}

// segment_tick is gone: the segment worker owns the 500 ms cadence, so the
// paint thread never calls the VAD or waits on the shim lock.
fn (mut h Host) stop_segmenter() {
	h.seg_mu.lock()
	h.seg_active = false
	h.seg_mu.unlock()
	if h.seg_threads.len > 0 {
		h.seg_threads.wait()
		h.seg_threads.clear()
	}
}

fn (mut h Host) stop(now f64) ! {
	if h.state != .recording {
		return error('not recording')
	}
	// Join the segmenter before tearing down capture: the worker reads the
	// capture buffer, so stopping first could let it snapshot a cleared take.
	h.stop_segmenter()
	samples := h.capture.stop()!
	h.last_use = now
	wav_write_f32(h.last_wav, samples, 16000) or {
		hexv_log('could not save last recording: ${err}')
	}
	hexv_log('recording stopped: ${samples.len} samples (${f64(samples.len) / 16000.0:.2f} s) -> ${h.last_wav}')
	h.seg_mu.lock()
	prefix := h.seg_texts.clone()
	cursor := h.seg_cursor
	h.seg_mu.unlock()
	if samples.len < min_recording_samples {
		h.state = .idle
		power_eco(true)
		return error('recording too short (${samples.len} samples)')
	}
	if prefix.len == 0 {
		mut vad_ok := true
		h.asr.ensure_vad(h.cfg.vad_path()) or { vad_ok = false }
		if vad_ok && !h.asr.vad_has_speech(samples) {
			h.state = .idle
			power_eco(true)
			return error('no speech detected')
		}
	}
	tail := if cursor < samples.len { samples[cursor..].clone() } else { []f32{} }
	h.state = .processing
	h.busy = true
	gen := h.generation
	spawn tail_worker(h.asr, h.cfg.model_path(), h.cfg.threads, h.cfg.language, tail,
		prefix, gen, h.ch)
}

// poll returns a finished transcription and whether it still belongs to the
// current dictation. A cancelled job is consumed and discarded.
fn (mut h Host) poll(now f64) (TranscribeResult, bool) {
	mut result := TranscribeResult{}
	if h.ch.try_pop(mut result) != .success {
		return result, false
	}
	h.busy = false
	h.last_use = now
	accepted := result.generation == h.generation && h.state != .cancelling
	h.state = .idle
	power_eco(true)
	if !accepted {
		hexv_log('discarded cancelled transcription')
	}
	return result, accepted
}

fn (mut h Host) cancel() {
	h.generation++
	h.stop_segmenter()
	match h.state {
		.recording {
			h.capture.cancel()
			h.state = .idle
			power_eco(true)
			hexv_log('dictation cancelled while recording')
		}
		.processing {
			h.state = .cancelling
			hexv_log('dictation cancelled while the model runs')
		}
		else {
			h.state = .idle
		}
	}
}

// idle_check releases the model after a quiet spell. It must only fire when the
// host is genuinely idle: `busy` is false for the whole of `.recording` (it is
// set in stop() and cleared in poll()), so gating on `busy` alone released the
// model - and re-enabled EcoQoS throttling - in the middle of any take longer
// than idle_model_seconds(). Every later poll then deferred on the
// `!is_loaded()` guard without advancing the cursor, so the rest of the take was
// uncheckpointed and the tail paid for a fresh model load on the release path.
fn (mut h Host) idle_check(now f64) {
	if h.state != .idle {
		return
	}
	if h.asr.is_loaded() && now - h.last_use >= idle_model_seconds() {
		h.asr.close_model()
		power_eco(true)
	}
}

fn (mut h Host) shutdown() {
	if h.state == .recording {
		h.capture.cancel()
	}
	h.stop_segmenter()
	if !h.busy {
		h.asr.close_all()
	}
	power_eco(true)
}

// --- CLI ------------------------------------------------------------------

fn run_transcribe_cli(wav_path string, model_override string, language_override string) {
	mut cfg := host_config()
	if model_override.len > 0 {
		cfg.model_id = model_override
		cfg.model_file = model_filename(model_override)
		if cfg.model_file.len == 0 {
			eprintln('hexv: unknown model ${model_override}')
			exit(1)
		}
	}
	lang := if language_override.len > 0 { language_override } else { cfg.language }
	samples := wav_read_mono16k(wav_path) or {
		eprintln('hexv: ${err}')
		exit(1)
	}
	trimmed, trim_ms := trim_trailing_silence(samples)
	mut asr := &AsrShim{}
	load_ms := asr.ensure_model(cfg.model_path(), cfg.threads) or {
		eprintln('hexv: ${err}')
		exit(1)
	}
	text, infer_ms := asr.transcribe(trimmed, lang) or {
		eprintln('hexv: ${err}')
		exit(1)
	}
	hexv_log('cli: model=${load_ms:.0f} ms inference=${infer_ms:.0f} ms samples=${trimmed.len} trim=${trim_ms} ms threads=${asr_worker_threads(cfg.threads)}')
	eprintln('[hexv] model load ${load_ms:.0f} ms, inference ${infer_ms:.0f} ms (${trimmed.len} samples, ${trim_ms} ms tail trimmed, ${asr_worker_threads(cfg.threads)} threads)')
	println(text)
	asr.close_all()
}

fn run_record_cli(seconds f64, out_path string) {
	mut cap := Capture{}
	cap.start() or {
		eprintln('hexv: ${err}')
		exit(1)
	}
	start := time.sys_mono_now()
	limit := u64(seconds * 1_000_000_000.0)
	for time.sys_mono_now() - start < limit {
		cap.pump()
		time.sleep(10 * time.millisecond)
	}
	samples := cap.stop() or {
		eprintln('hexv: ${err}')
		exit(1)
	}
	wav_write_f32(out_path, samples, 16000) or {
		eprintln('hexv: ${err}')
		exit(1)
	}
	println('recorded ${samples.len} samples (${f64(samples.len) / 16000.0:.2f} s) -> ${out_path}')
}

fn run_paste_cli(wav_path string) {
	cfg := host_config()
	samples := wav_read_mono16k(wav_path) or {
		eprintln('hexv: ${err}')
		exit(1)
	}
	trimmed, trim_ms := trim_trailing_silence(samples)
	mut asr := &AsrShim{}
	asr.ensure_model(cfg.model_path(), cfg.threads) or {
		eprintln('hexv: ${err}')
		exit(1)
	}
	text, _ := asr.transcribe(trimmed, cfg.language) or {
		eprintln('hexv: ${err}')
		exit(1)
	}
	hexv_log('cli paste: samples=${trimmed.len} trim=${trim_ms} ms')
	asr.close_all()
	paste_text(text) or {
		eprintln('hexv: ${err}')
		exit(1)
	}
	println(text)
}
