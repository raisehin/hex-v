// Dictation host: mic -> 16 kHz f32 -> VAD segmenter -> shim -> clipboard
// paste, with the existing Indicator driving the Dot scope.
module main

import sync
import time

const min_recording_samples = 3200 // 0.2 s at 16 kHz
const seg_min_samples = 16000
const seg_ctx_samples = 3200
const seg_poll_ms = 500
const seg_silence_ms = 500

enum HostState {
	idle
	recording
	processing
	cancelling
}

struct SegmentJob {
	samples    []f32
	generation int
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
	seg_jobs     chan SegmentJob
	seg_threads  []thread
	seg_mu       sync.Mutex
	seg_texts    []string
	seg_cursor   int
	seg_last_poll f64
	seg_active   bool
	last_use     f64
	last_wav     string
	busy         bool
}

fn new_host(cfg HostConfig) &Host {
	return &Host{
		cfg:      cfg
		asr:      &AsrShim{}
		ch:       chan TranscribeResult{cap: 4}
		seg_jobs: chan SegmentJob{cap: 1}
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

fn segment_worker(mut h Host, jobs chan SegmentJob) {
	for {
		job := <-jobs or { break }
		if job.generation != h.generation {
			continue
		}
		trimmed, trim_ms := trim_trailing_silence(job.samples)
		t0 := time.sys_mono_now()
		text, _ := h.asr.transcribe(trimmed, h.cfg.language) or {
			hexv_log('segment inference failed: ${err}')
			continue
		}
		if text.len > 0 && job.generation == h.generation {
			h.seg_mu.lock()
			h.seg_texts << text
			h.seg_mu.unlock()
		}
		elapsed := f64(time.sys_mono_now() - t0) / 1_000_000.0
		hexv_log('segment: samples=${job.samples.len} trim=${trim_ms} ms inference=${elapsed:.0f} ms chars=${text.len}')
	}
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
	h.seg_mu.unlock()
	h.seg_jobs = chan SegmentJob{cap: 8}
	jobs := h.seg_jobs
	h.seg_threads << spawn segment_worker(mut h, jobs)
	h.seg_active = true
	h.seg_last_poll = now
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

// segment_tick polls the VAD every SEG_POLL_MS and sends a closed segment to
// the segment worker. The main loop stays free to paint the HUD.
fn (mut h Host) segment_tick(now f64) {
	if !h.seg_active || h.state != .recording {
		return
	}
	if now - h.seg_last_poll < f64(seg_poll_ms) / 1000.0 {
		return
	}
	h.seg_last_poll = now
	samples := h.capture.snapshot_16k()
	if samples.len <= seg_ctx_samples {
		return
	}
	end := int(h.asr.vad_speech_end(samples, seg_silence_ms))
	if end <= h.seg_cursor + seg_min_samples || end > samples.len {
		return
	}
	lo := if h.seg_cursor > seg_ctx_samples { h.seg_cursor - seg_ctx_samples } else { 0 }
	slice := samples[lo..end].clone()
	old_cursor := h.seg_cursor
	h.seg_cursor = end
	h.seg_jobs <- SegmentJob{
		samples:    slice
		generation: h.generation
	}
	hexv_log('segment boundary: ${old_cursor}..${end} (${end - old_cursor} new samples)')
}

fn (mut h Host) stop_segmenter() {
	h.seg_active = false
	if h.seg_threads.len > 0 {
		h.seg_jobs.close()
		h.seg_threads.wait()
		h.seg_threads.clear()
	}
}

fn (mut h Host) stop(now f64) ! {
	if h.state != .recording {
		return error('not recording')
	}
	samples := h.capture.stop()!
	h.last_use = now
	wav_write_f32(h.last_wav, samples, 16000) or {
		hexv_log('could not save last recording: ${err}')
	}
	hexv_log('recording stopped: ${samples.len} samples (${f64(samples.len) / 16000.0:.2f} s) -> ${h.last_wav}')
	h.stop_segmenter()
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

fn (mut h Host) idle_check(now f64) {
	if h.busy {
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
