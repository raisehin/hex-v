// Runtime shim loader for the transcribe.cpp DLL. The DLL is used in place: no
// model copy, no second ASR implementation. ABI from native/transcribe_shim.h.
module main

import dl
import os
import runtime
import sync
import time

#flag -lkernel32
#include <windows.h>

// Resolve the runtime shim next to the executable, or from HEX_SHIM. The DLL
// is not needed to compile this app.
fn resolve_shim_path() string {
	p := os.getenv('HEX_SHIM')
	if p.len > 0 {
		return p
	}
	exe := os.executable()
	if exe.len > 0 {
		dir := os.dir(exe)
		candidate := '${dir}\\transcribe_shim.dll'
		if os.exists(candidate) {
			return candidate
		}
		candidate_bin := '${dir}\\bin\\transcribe_shim.dll'
		if os.exists(candidate_bin) {
			return candidate_bin
		}
	}
	return 'transcribe_shim.dll'
}
const vad_filename = 'silero-vad-v6.2-F32.gguf'

const above_normal_priority_class = u32(0x00008000)
const normal_priority_class = u32(0x00000020)
const process_power_throttling = i32(4)
const process_power_throttling_execution_speed = u32(0x1)

type HexModelInit = fn (path &char) i32
type HexTranscribe = fn (samples &f32, count i32, language &char) &char
type HexFree = fn (p &char)
type HexVadInit = fn (path &char) i32
type HexVadHas = fn (samples &f32, count i32) i32
type HexVadEnd = fn (samples &f32, count i32, min_silence_ms i32) i64
type HexSetThreads = fn (n i32)
type HexVoid = fn ()
type HexLastError = fn () &char

fn C.GetCurrentProcess() voidptr
fn C.SetPriorityClass(process voidptr, class u32) i32
fn C.SetProcessInformation(process voidptr, class i32, info voidptr, size u32) i32

struct AsrShim {
mut:
	mu             sync.Mutex
	lib            voidptr
	f_init         voidptr
	f_transcribe   voidptr
	f_free         voidptr
	f_vad_init     voidptr
	f_vad_has      voidptr
	f_vad_end      voidptr
	f_vad_free     voidptr
	f_set_threads  voidptr
	f_close        voidptr
	f_last_error   voidptr
	loaded         bool
	model_path     string
	threads        int
	vad_loaded     bool
	vad_path       string
}

struct HostConfig {
mut:
	model_id     string
	model_file   string
	language     string
	paste_keys   string
	threads      int
	data_dir     string
	models_dir   string
	logs_dir     string
	// config_error names an odin-config value this build cannot honour. It is a
	// field rather than an error return so hexv_log(), which calls this to find
	// logs_dir, cannot recurse through the failure path.
	config_error string
}

struct PowerThrottlingState {
	version     u32
	control_mask u32
	state_mask  u32
}

fn appdata_dir() string {
	a := os.getenv('APPDATA')
	if a.len == 0 {
		return '.'
	}
	return '${a}\\hex'
}

fn host_config() HostConfig {
	data_dir := appdata_dir()
	mut c := HostConfig{
		model_id:   'phonon25_en'
		model_file: 'phonon-2.5-en-Q8_0.gguf'
		language:   'en'
		paste_keys: 'ctrl_v'
		data_dir:   data_dir
		models_dir: '${data_dir}\\models'
		logs_dir:   '${data_dir}\\logs'
	}
	text := os.read_file('${data_dir}\\odin-config') or { '' }
	for line in text.split_into_lines() {
		parts := line.split_nth('=', 2)
		if parts.len != 2 {
			continue
		}
		key := parts[0].trim_space()
		val := parts[1].trim_space()
		match key {
			'model' { c.model_id = val }
			'language' { c.language = val }
			'paste_keys' { c.paste_keys = val }
			'threads' { c.threads = val.int() }
			// 'engine' is not a hex-v setting: hex-v has exactly one engine (the
			// transcribe shim), so the value was parsed and never read; it is
			// ignored rather than pretended to do something.
			else {}
		}
	}
	c.model_file = model_filename(c.model_id)
	if c.model_file.len == 0 {
		// Fail loudly at the call sites instead of loading phonon while the
		// config still names something else. Keep the default populated so
		// hexv_log() and error paths still have a usable logs_dir/model.
		c.config_error = 'unsupported model "${c.model_id}" in odin-config; this build supports: ${supported_models()}'
		c.model_id = 'phonon25_en'
		c.model_file = 'phonon-2.5-en-Q8_0.gguf'
	}
	if c.language.len == 0 {
		c.language = 'en'
	}
	return c
}

// model_filename maps the only model id hex-v can load. Anything else returns
// '' so host_config() can report it instead of silently substituting phonon.
fn model_filename(id string) string {
	return match id {
		'phonon25_en' { 'phonon-2.5-en-Q8_0.gguf' }
		else { '' }
	}
}

fn supported_models() string {
	return 'phonon25_en'
}

fn (c &HostConfig) model_path() string {
	return '${c.models_dir}\\${c.model_file}'
}

fn (c &HostConfig) vad_path() string {
	return '${c.models_dir}\\${vad_filename}'
}

// hexv_log appends one line to %APPDATA%\hex\logs\hexv.log.
fn hexv_log(msg string) {
	c := host_config()
	os.mkdir_all(c.logs_dir) or {}
	path := '${c.logs_dir}\\hexv.log'
	old := os.read_file(path) or { '' }
	stamp := time.now().str()
	os.write_file(path, '${old}[${stamp}] ${msg}\n') or {}
}

// asr_worker_threads: 0 means three quarters of the logical CPUs, leaving one
// SMT sibling per physical core free for ggml's spinning pool.
fn asr_worker_threads(want int) int {
	if want > 0 {
		return want
	}
	n := runtime.nr_cpus()
	if n <= 2 {
		return n
	}
	return n - n / 4
}

// set_transcribe_priority raises the process for a single transcribe call.
// Standalone CLI calls use it directly. The HUD host holds the boost across the
// whole release path and re-applies it after each transcribe returns.
fn set_transcribe_priority(elevated bool) {
	cls := if elevated { above_normal_priority_class } else { normal_priority_class }
	C.SetPriorityClass(C.GetCurrentProcess(), cls)
}

// power_eco turns Windows 11 EcoQoS execution-speed throttling off while
// dictating and back on when the host is idle.
fn power_eco(on bool) {
	mut st := PowerThrottlingState{
		version:      u32(1)
		control_mask: process_power_throttling_execution_speed
		state_mask:   if on { process_power_throttling_execution_speed } else { u32(0) }
	}
	C.SetProcessInformation(C.GetCurrentProcess(), process_power_throttling, &st,
		u32(sizeof(PowerThrottlingState)))
}

fn (s &AsrShim) last_error_text() string {
	if s.f_last_error == 0 {
		return ''
	}
	p := HexLastError(s.f_last_error)()
	if p == unsafe { nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(p) }
}

fn (mut s AsrShim) load_shim_locked(path string) ! {
	if s.lib != 0 {
		return
	}
	if !os.exists(path) {
		return error('transcribe shim missing: ${path}')
	}
	lib := dl.open_opt(path, dl.rtld_lazy) or { return error('load ${path}: ${err}') }
	s.lib = lib
	s.f_init = dl.sym(lib, 'hex_model_init')
	s.f_transcribe = dl.sym(lib, 'hex_transcribe')
	s.f_free = dl.sym(lib, 'hex_free')
	s.f_vad_init = dl.sym(lib, 'hex_vad_init')
	s.f_vad_has = dl.sym(lib, 'hex_vad_has_speech')
	s.f_vad_end = dl.sym(lib, 'hex_vad_speech_end')
	s.f_vad_free = dl.sym(lib, 'hex_vad_free')
	s.f_set_threads = dl.sym(lib, 'hex_set_threads')
	s.f_close = dl.sym(lib, 'hex_model_close')
	s.f_last_error = dl.sym(lib, 'hex_last_error')
	if s.f_init == 0 || s.f_transcribe == 0 || s.f_free == 0 {
		dl.close(lib)
		s.lib = 0
		return error('transcribe shim is missing required exports')
	}
	hexv_log('shim loaded: ${path}')
}

fn (mut s AsrShim) close_model_locked() {
	if s.loaded && s.f_close != 0 {
		HexVoid(s.f_close)()
		hexv_log('model released')
	}
	s.loaded = false
	s.model_path = ''
}

fn (mut s AsrShim) ensure_model_locked(path string, threads int) !f64 {
	want := asr_worker_threads(threads)
	if s.loaded {
		if s.model_path == path && s.threads == want {
			return 0.0
		}
		s.close_model_locked()
	}
	s.load_shim_locked(resolve_shim_path())!
	if !os.exists(path) {
		return error('model missing: ${path}')
	}
	if s.f_set_threads != 0 {
		HexSetThreads(s.f_set_threads)(i32(want))
	}
	t0 := time.sys_mono_now()
	init := HexModelInit(s.f_init)
	rc := init(path.str)
	elapsed := f64(time.sys_mono_now() - t0) / 1_000_000.0
	if rc != 0 {
		detail := s.last_error_text()
		if detail.len > 0 {
			return error('model init failed (${rc}): ${detail}')
		}
		return error('model init failed (${rc})')
	}
	s.loaded = true
	s.model_path = path
	s.threads = want
	hexv_log('model load ${elapsed:.0f} ms threads=${want} path=${path}')
	return elapsed
}

fn (mut s AsrShim) ensure_model(path string, threads int) !f64 {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	return s.ensure_model_locked(path, threads)
}

fn (mut s AsrShim) transcribe(samples []f32, language string) !(string, f64) {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if !s.loaded {
		return error('model is not loaded')
	}
	if samples.len == 0 {
		return error('no samples')
	}
	tr := HexTranscribe(s.f_transcribe)
	t0 := time.sys_mono_now()
	set_transcribe_priority(true)
	res := tr(samples.data, i32(samples.len), language.str)
	set_transcribe_priority(false)
	elapsed := f64(time.sys_mono_now() - t0) / 1_000_000.0
	if res == unsafe { nil } {
		detail := s.last_error_text()
		if detail.len > 0 {
			return error('transcribe failed: ${detail}')
		}
		return error('transcribe returned no text')
	}
	text := unsafe { cstring_to_vstring(res) }
	HexFree(s.f_free)(res)
	hexv_log('inference ${elapsed:.0f} ms threads=${s.threads} samples=${samples.len} chars=${text.len}')
	return text, elapsed
}

fn (mut s AsrShim) ensure_vad(path string) ! {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if s.vad_loaded {
		return
	}
	if s.lib == 0 {
		s.load_shim_locked(resolve_shim_path())!
	}
	if s.f_vad_init == 0 || !os.exists(path) {
		return error('VAD unavailable')
	}
	rc := HexVadInit(s.f_vad_init)(path.str)
	if rc != 0 {
		return error('vad load failed (${rc})')
	}
	s.vad_loaded = true
	s.vad_path = path
	hexv_log('vad load ok path=${path}')
}

fn (mut s AsrShim) vad_has_speech(samples []f32) bool {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if !s.vad_loaded || s.f_vad_has == 0 || samples.len == 0 {
		return true
	}
	return HexVadHas(s.f_vad_has)(samples.data, i32(samples.len)) == 1
}

// vad_speech_end returns the end sample of the last closed speech segment, or
// -1 while none is closed yet.
fn (mut s AsrShim) vad_speech_end(samples []f32, min_silence_ms int) i64 {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if !s.vad_loaded || s.f_vad_end == 0 || samples.len == 0 {
		return -1
	}
	return HexVadEnd(s.f_vad_end)(samples.data, i32(samples.len), i32(min_silence_ms))
}

fn (mut s AsrShim) is_loaded() bool {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	return s.loaded
}

fn (mut s AsrShim) close_model() {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	s.close_model_locked()
}

fn (mut s AsrShim) close_all() {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	s.close_model_locked()
	if s.vad_loaded && s.lib != 0 && s.f_vad_free != 0 {
		HexVoid(s.f_vad_free)()
	}
	s.vad_loaded = false
	if s.lib != 0 {
		dl.close(s.lib)
		s.lib = 0
	}
}

// idle_model_seconds is opt-in. An unset or non-positive HEX_MODEL_IDLE_SECS
// keeps the already-loaded model resident, so an idle HUD never creates the
// next take's cold-load outlier.
fn idle_model_seconds() f64 {
	v := os.getenv('HEX_MODEL_IDLE_SECS')
	if v.len > 0 {
		n := v.int()
		if n > 0 {
			return f64(n)
		}
	}
	return 0.0
}
