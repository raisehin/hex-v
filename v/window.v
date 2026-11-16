// Windows presenter: a layered WS_POPUP window that shows the Dot scope.
//
// Every frame the premultiplied RGBA raster is copied into a 32-bit top-down
// DIB section, the DIB is selected into a memory DC, and
// UpdateLayeredWindow(ULW_ALPHA) with a per-pixel alpha BLENDFUNCTION pushes
// it to the desktop. The simulation is driven by the real paint clock
// (QueryPerformanceCounter), and demo voice mode replays the schedule of
// oracle/src/main.rs: Started at 0 s, Submitted at 3.0 s, Processing at
// 3.6 s, JobCompleted at 4.4 s, then a fresh phrase at 6.0 s.
module main

import render
import time

#flag -luser32
#flag -lgdi32
#flag -lwinmm
#include <windows.h>
#include <mmsystem.h>

const window_width = 320 // CAPTURE_DOT_WINDOW in points; 1x on the Windows desktop
const window_height = 128
const window_class_name = 'hexv_surface'
const window_top_offset = 48

// Paint target: 240 Hz, matching the simulation's 1/240 s substep.
const paint_period = f64(1.0) / 240.0
const paint_sleep_floor = 0.002
const paint_probe_frames = 600

// Demo phrase schedule, from the replay in oracle/src/main.rs.
const demo_submit_at = f64(3.0)
const demo_pipeline_at = f64(3.6)
const demo_complete_at = f64(4.4)
const demo_restart_at = f64(6.0)

// Win32 constants, spelled out because the declarations below are hand-rolled.
const ws_popup = u32(0x80000000)
const ws_visible = u32(0x10000000)
const ws_ex_transparent = u32(0x20)
const ws_ex_topmost = u32(0x8)
const ws_ex_toolwindow = u32(0x80)
const ws_ex_layered = u32(0x80000)
const ws_ex_noactivate = u32(0x8000000)
const sw_hide = i32(0)
const sm_cxscreen = i32(0)
const cursor_arrow = i32(32512)
const ulw_alpha = u32(2)
const ac_src_over = u8(0)
const ac_src_alpha = u8(1)
const bi_rgb = u32(0)
const dib_rgb_colors = u32(0)
const wm_destroy = u32(2)
const wm_close = u32(0x10)
const wm_queryendsession = u32(0x11)
const wm_endsession = u32(0x16)
const wm_keydown = u32(0x100)
const wm_quit = u32(0x12)
const pm_remove = u32(1)
const gwlp_userdata = i32(-21)
const gwl_exstyle = i32(-20)
// GWLP_USERDATA carries two independent flags: a restart request from Space
// and whether the tray icon is currently added. They must not overwrite each
// other, so both live in the same word.
const ui_restart_bit = i64(1)
const ui_tray_added_bit = i64(2)
const vk_escape = u64(0x1b)
const vk_space = u64(0x20)
const vk_control = u64(0x11)
const vk_alt = u64(0x12)
const vk_q = u64(0x51)

// Win32 structures, laid out by hand: only #include <windows.h> is used, so the
// module never depends on V bindings for the SDK types it passes by pointer.
// V's `int` is 64-bit, so every C `int`, UINT and DWORD field is spelled i32 or
// u32 and only pointer-sized fields use i64.
struct W32Point {
	x i32
	y i32
}

struct W32Size {
	cx i32
	cy i32
}

struct W32Blend {
	op     u8
	flags  u8
	alpha  u8
	format u8
}

struct W32BmiHeader {
	bi_size          u32
	bi_width         i32
	bi_height        i32
	bi_planes        u16
	bi_bit_count     u16
	bi_compression   u32
	bi_size_image    u32
	bi_x_pels        i32
	bi_y_pels        i32
	bi_clr_used      u32
	bi_clr_important u32
}

struct W32BitmapInfo {
	header W32BmiHeader
	colors u32
}

struct W32Msg {
	hwnd     voidptr
	message  u32
	pad      u32
	wparam   u64
	lparam   i64
	time     u32
	pt       W32Point
	lprivate u32
}

// WNDCLASS, not WNDCLASSEX: the Ex form starts with a cbSize field, the plain
// one keeps the class registration free of size bookkeeping.
struct W32WndClass {
mut:
	style      u32
	wnd_proc   voidptr
	cls_extra  i32
	wnd_extra  i32
	instance   voidptr
	icon       voidptr
	cursor     voidptr
	background voidptr
	menu_name  voidptr
	class_name voidptr
}

fn C.RegisterClassA(wc &W32WndClass) u16
fn C.CreateWindowExA(ex_style u32, class_name voidptr, title voidptr, style u32, x i32, y i32, w i32, h i32, parent voidptr, menu voidptr, instance voidptr, param voidptr) voidptr
fn C.DestroyWindow(hwnd voidptr)
fn C.DefWindowProcA(hwnd voidptr, msg u32, wparam u64, lparam i64) i64
fn C.GetModuleHandleA(name voidptr) voidptr
fn C.LoadCursorA(instance voidptr, name i32) voidptr
fn C.GetSystemMetrics(index i32) i32
fn C.GetConsoleWindow() voidptr
fn C.SetProcessDPIAware() i32
fn C.ShowWindow(hwnd voidptr, cmd i32) i32
fn C.SetWindowLongPtrA(hwnd voidptr, index i32, value i64) i64
fn C.GetWindowLongPtrA(hwnd voidptr, index i32) i64
fn C.GetAsyncKeyState(key i32) i16
fn C.GetLastError() u32
fn C.CreateCompatibleDC(hdc voidptr) voidptr
fn C.DeleteDC(hdc voidptr) i32
fn C.CreateDIBSection(hdc voidptr, bmi &W32BitmapInfo, usage u32, bits &voidptr, section voidptr, offset u32) voidptr
fn C.SelectObject(hdc voidptr, obj voidptr) voidptr
fn C.DeleteObject(obj voidptr) i32
fn C.UpdateLayeredWindow(hwnd voidptr, hdc_screen voidptr, dst &W32Point, size &W32Size, hdc_src voidptr, src &W32Point, key u32, blend &W32Blend, flags u32) i32
fn C.PeekMessageA(msg &W32Msg, hwnd voidptr, filter_min u32, filter_max u32, remove u32) i32
fn C.TranslateMessage(msg &W32Msg) i32
fn C.DispatchMessageA(msg &W32Msg) i64
fn C.PostQuitMessage(code i32)
fn C.Sleep(ms u32)
fn C.timeBeginPeriod(ms u32) u32
fn C.timeEndPeriod(ms u32) u32

// --- clock ----------------------------------------------------------------

// PaintClock is the real paint clock. time.sys_mono_now is
// QueryPerformanceCounter divided by QueryPerformanceFrequency
// (vlib/time/time_windows.c.v:100), so the stamps below are the paint
// timestamps and nothing else.
struct PaintClock {
mut:
	started u64
}

fn paint_clock_new() PaintClock {
	return PaintClock{
		started: time.sys_mono_now()
	}
}

// nanos is the raw monotonic timestamp, in nanoseconds.
fn (clock &PaintClock) nanos() u64 {
	return time.sys_mono_now()
}

// seconds is monotonic seconds since the clock was created.
fn (clock &PaintClock) seconds() f64 {
	return f64(clock.nanos() - clock.started) / 1_000_000_000.0
}

// pace waits until the paint deadline, one millisecond at a time once
// timeBeginPeriod(1) is in effect.
fn pace(deadline f64, clock &PaintClock) {
	for {
		remain := deadline - clock.seconds()
		if remain <= 0.0 {
			return
		}
		if remain > paint_sleep_floor {
			C.Sleep(1)
		} else {
			C.Sleep(0)
		}
	}
}

// paint_deadline is the next paint time. A frame that overran its budget drops
// the backlog instead of bursting to catch up.
fn paint_deadline(previous f64, now f64) f64 {
	deadline := previous + paint_period
	if deadline < now {
		return now
	}
	return deadline
}

// --- demo phrase ----------------------------------------------------------

struct DemoPhrase {
mut:
	started   f64
	submitted bool
	pipelined bool
	completed bool
}

// begin starts a phrase and hands the loudness curve to the indicator:
// on_started clears demo_voice, so it is set again right after.
fn (mut phrase DemoPhrase) begin(mut indicator Indicator, now f64, reduce bool) {
	indicator.on_started(now, reduce)
	indicator.demo_voice = true
	indicator.demo_time = 0
	phrase.started = now
	phrase.submitted = false
	phrase.pipelined = false
	phrase.completed = false
}

fn (mut phrase DemoPhrase) tick(mut indicator Indicator, now f64, reduce bool) {
	t := now - phrase.started
	if !phrase.submitted && t >= demo_submit_at {
		indicator.on_submitted(now)
		phrase.submitted = true
	}
	if !phrase.pipelined && t >= demo_pipeline_at {
		indicator.show_pipeline(now)
		phrase.pipelined = true
	}
	if !phrase.completed && t >= demo_complete_at {
		indicator.on_completed(now)
		phrase.completed = true
	}
	if t >= demo_restart_at {
		phrase.begin(mut indicator, now, reduce)
	}
}

// --- window ---------------------------------------------------------------

// wnd_proc records a restart request in the window's user data. Cancellation is
// left to KeyPoll, which knows the host state: an unconditional Esc quit here
// would contradict README's "Esc does nothing when idle" and bypass the polled
// path that the WS_EX_NOACTIVATE window usually has to rely on anyway. The tray
// callback, session-end messages and window close arrive on this queue.
fn wnd_proc(hwnd voidptr, msg u32, wparam u64, lparam i64) i64 {
	if tray_handle_message(hwnd, msg, wparam, lparam) {
		return 0
	}
	if msg == wm_close || msg == wm_destroy {
		hexv_log('window: close requested')
		tray_remove_once(hwnd)
		C.PostQuitMessage(0)
		return 0
	}
	if msg == wm_queryendsession {
		// TRUE allows the logoff/shutdown; WM_ENDSESSION follows if it proceeds.
		return 1
	}
	if msg == wm_endsession {
		if wparam != 0 {
			hexv_log('window: WM_ENDSESSION, ending')
			tray_remove_once(hwnd)
			C.PostQuitMessage(0)
		}
		return 0
	}
	if msg == wm_keydown {
		if wparam == vk_escape {
			return 0
		}
		if wparam == vk_space {
			flags := C.GetWindowLongPtrA(hwnd, gwlp_userdata)
			C.SetWindowLongPtrA(hwnd, gwlp_userdata, flags | ui_restart_bit)
		}
		return 0
	}
	return C.DefWindowProcA(hwnd, msg, wparam, lparam)
}

struct LayeredSurface {
mut:
	hwnd    voidptr
	mem_dc  voidptr
	dib     voidptr
	old_dib voidptr
	bits    &u8 = unsafe { nil }
	origin  W32Point
}

fn layered_surface_open(visible bool) !LayeredSurface {
	// Without DPI awareness the window is virtualized and scaled by the
	// compositor, so 640x256 would not be 640x256 device pixels.
	C.SetProcessDPIAware()
	mut surface := LayeredSurface{}
	instance := C.GetModuleHandleA(voidptr(0))
	class_name := window_class_name.str
	mut wc := W32WndClass{
		wnd_proc:   voidptr(wnd_proc)
		instance:   instance
		icon:       app_icon(instance, int(C.GetSystemMetrics(sm_cxicon)), int(C.GetSystemMetrics(sm_cyicon)))
		cursor:     C.LoadCursorA(voidptr(0), cursor_arrow)
		class_name: voidptr(class_name)
	}
	// A second register attempt for the same class fails harmlessly.
	C.RegisterClassA(&wc)
	screen := C.GetSystemMetrics(sm_cxscreen)
	surface.origin = W32Point{
		x: i32((screen - window_width) / 2)
		y: i32(window_top_offset)
	}
	style := if visible { ws_popup | ws_visible } else { ws_popup }
	ex_style := ws_ex_layered | ws_ex_topmost | ws_ex_toolwindow | ws_ex_noactivate | ws_ex_transparent
	surface.hwnd = C.CreateWindowExA(ex_style, voidptr(class_name), voidptr(0), style,
		surface.origin.x, surface.origin.y, window_width, window_height, voidptr(0),
		voidptr(0), instance, voidptr(0))
	if surface.hwnd == voidptr(0) {
		return error('CreateWindowExA failed: ${C.GetLastError()}')
	}
	tray_set_window_icon(surface.hwnd)
	surface.mem_dc = C.CreateCompatibleDC(voidptr(0))
	if surface.mem_dc == voidptr(0) {
		C.DestroyWindow(surface.hwnd)
		return error('CreateCompatibleDC failed: ${C.GetLastError()}')
	}
	bmi := W32BitmapInfo{
		header: W32BmiHeader{
			bi_size:        40 // sizeof(BITMAPINFOHEADER)
			bi_width:       window_width
			bi_height:      -window_height
			bi_planes:      1
			bi_bit_count:   32
			bi_compression: bi_rgb
		}
	}
	mut bits := voidptr(0)
	surface.dib = C.CreateDIBSection(surface.mem_dc, &bmi, dib_rgb_colors, &bits,
		voidptr(0), u32(0))
	if surface.dib == voidptr(0) || bits == voidptr(0) {
		C.DeleteDC(surface.mem_dc)
		C.DestroyWindow(surface.hwnd)
		return error('CreateDIBSection failed: ${C.GetLastError()}')
	}
	surface.old_dib = C.SelectObject(surface.mem_dc, surface.dib)
	surface.bits = unsafe { &u8(bits) }
	return surface
}

fn (mut surface LayeredSurface) close() {
	if surface.mem_dc != voidptr(0) {
		C.SelectObject(surface.mem_dc, surface.old_dib)
		C.DeleteDC(surface.mem_dc)
		surface.mem_dc = voidptr(0)
	}
	if surface.dib != voidptr(0) {
		C.DeleteObject(surface.dib)
		surface.dib = voidptr(0)
	}
	if surface.hwnd != voidptr(0) {
		C.DestroyWindow(surface.hwnd)
		surface.hwnd = voidptr(0)
	}
	surface.bits = unsafe { nil }
}

// present copies the raster into the DIB and blits it to the desktop with
// ULW_ALPHA. render_rgba already returns premultiplied RGBA, so only the
// channel order changes: the DIB is premultiplied BGRA.
fn (mut surface LayeredSurface) present(rgba []u8) bool {
	bytes := window_width * window_height * 4
	if rgba.len < bytes {
		return false
	}
	mut dst := surface.bits
	unsafe {
		mut i := 0
		for i < bytes {
			dst[i] = rgba[i + 2]
			dst[i + 1] = rgba[i + 1]
			dst[i + 2] = rgba[i]
			dst[i + 3] = rgba[i + 3]
			i += 4
		}
	}
	src := W32Point{}
	size := W32Size{
		cx: i32(window_width)
		cy: i32(window_height)
	}
	blend := W32Blend{
		op:     ac_src_over
		alpha:  255
		format: ac_src_alpha
	}
	return C.UpdateLayeredWindow(surface.hwnd, voidptr(0), &surface.origin, &size,
		surface.mem_dc, &src, u32(0), &blend, ulw_alpha) != 0
}

// pump drains the message queue; false means the window asked to quit.
fn (mut surface LayeredSurface) pump(mut msg W32Msg) bool {
	for C.PeekMessageA(&msg, voidptr(0), u32(0), u32(0), pm_remove) != 0 {
		if msg.message == wm_quit {
			return false
		}
		C.TranslateMessage(&msg)
		C.DispatchMessageA(&msg)
	}
	return true
}

fn (mut surface LayeredSurface) take_restart_request() bool {
	flags := C.GetWindowLongPtrA(surface.hwnd, gwlp_userdata)
	if flags & ui_restart_bit == 0 {
		return false
	}
	C.SetWindowLongPtrA(surface.hwnd, gwlp_userdata, flags & ~ui_restart_bit)
	return true
}

// quit_save_take keeps the audio from a take that is still recording when the
// user quits. It saves exactly what Host.stop() saves, but deliberately does
// not start the tail transcription: quitting must not launch inference.
fn quit_save_take(mut host Host) {
	host.stop_segmenter()
	samples := host.capture.stop() or {
		hexv_log('quit: capture stop failed: ${err}')
		return
	}
	wav_write_f32(host.last_wav, samples, 16000) or {
		hexv_log('quit: could not save last recording: ${err}')
	}
	hexv_log('quit: saved ${samples.len} samples (${f64(samples.len) / 16000.0:.2f} s) -> ${host.last_wav}')
	host.seg_mu.lock()
	host.seg_active = false
	host.seg_mu.unlock()
	host.state = .idle
}

// The window is WS_EX_NOACTIVATE, so it may never receive WM_KEYDOWN; poll the
// keys as well so Esc and Space always work.
struct KeyPoll {
mut:
	escape_down  bool
	space_down   bool
	control_down bool
	alt_down     bool
	q_down       bool
}

struct KeyPress {
	escape bool
	toggle bool // Ctrl+Space edge
	quit   bool // Ctrl+Alt+Q edge
}

fn (mut keys KeyPoll) poll() KeyPress {
	escape := C.GetAsyncKeyState(i32(vk_escape)) < 0
	space := C.GetAsyncKeyState(i32(vk_space)) < 0
	control := C.GetAsyncKeyState(i32(vk_control)) < 0
	alt := C.GetAsyncKeyState(i32(vk_alt)) < 0
	q := C.GetAsyncKeyState(i32(vk_q)) < 0
	toggle := control && space && !(keys.control_down && keys.space_down)
	quit := control && alt && q && !(keys.control_down && keys.alt_down && keys.q_down)
	press := KeyPress{
		escape: escape && !keys.escape_down
		toggle: toggle
		quit:   quit
	}
	keys.escape_down = escape
	keys.space_down = space
	keys.control_down = control
	keys.alt_down = alt
	keys.q_down = q
	return press
}

// --- frames ---------------------------------------------------------------

fn build_scene(f DotFrame) render.Scene {
	pose := f.pose
	return render.Scene{
		width:         window_width
		height:        window_height
		backing_scale: 1.0
		dark:          true
		pitch:         2.6
		columns:       f.columns
		rows:          f.rows
		dots:          f.dots
		pose_width:    pose.width
		pose_height:   pose.height
		pose_opacity:  pose.opacity
		pose_scale:    pose.scale
		pose_softness: pose.softness
		pose_cool:     pose.cool
		pose_fail:     pose.fail
		pose_glow:     pose.glow
		pose_grid:     pose.grid
		pose_live:     pose.live
		pose_reveal:   pose.reveal
		pose_level:    pose.level
		pose_clock:    pose.clock
		pose_done:     pose.done
	}
}

// --- entry points ---------------------------------------------------------

// run_window shows the real dictation host: Ctrl+Space starts/stops,
// Ctrl+Alt+Q quits, Esc cancels only while dictating/transcribing.
pub fn run_window() {
	// Validate before hiding the console: otherwise a config error would be
	// printed to a window nobody can see and the HUD simply would not appear.
	cfg := host_config()
	if cfg.config_error.len > 0 {
		hexv_log('config error: ${cfg.config_error}')
		eprintln('hexv: ${cfg.config_error}')
		return
	}
	C.ShowWindow(C.GetConsoleWindow(), sw_hide)
	mut surface := layered_surface_open(true) or {
		eprintln('hexv: ${err}')
		return
	}
	if !tray_add(surface.hwnd) {
		hexv_log('tray: continuing without a notification-area icon')
	}
	C.timeBeginPeriod(1)
	mut clock := paint_clock_new()
	mut indicator := indicator_new(tuning_default())
	mut host := new_host(cfg)
	// The HUD and tray are ready; warm the shim/VAD/model once for this process.
	// The take's Ctrl+Space path must never own the 1.1 s cold-load cost.
	hexv_log('startup: model preload started')
	spawn preload_worker(host.asr, host.cfg.model_path(), host.cfg.threads, host.cfg.vad_path())
	mut keys := KeyPoll{}
	mut msg := W32Msg{}
	mut last_step := clock.seconds()
	mut next_paint := last_step
	mut running := true
	for running {
		if !surface.pump(mut msg) {
			break
		}
		now := clock.seconds()
		press := keys.poll()
		if press.quit {
			hexv_log('quit: requested (Ctrl+Alt+Q)')
			break
		}
		if press.escape && (host.state != .idle || host.busy) {
			host.cancel()
			indicator.on_cancelled(now)
		}
		if press.toggle {
			match host.state {
				.recording {
					host.stop(now) or {
						hexv_log('stop failed: ${err}')
						indicator.on_failed(now)
					}
					if host.state == .processing {
						indicator.on_submitted(now)
					}
				}
				.idle {
					if host.busy {
						hexv_log('dictation ignored: model busy')
					} else {
						host.start(now) or {
							hexv_log('start failed: ${err}')
							indicator.on_failed(now)
						}
						if host.state == .recording {
							indicator.on_started(now, false)
							indicator.demo_voice = false
						}
					}
				}
				else {
					hexv_log('dictation ignored: model busy')
				}
			}
		}
		if host.state == .recording {
			indicator.loudness = host.pump_level()
		}
		result, accepted := host.poll(now)
		if accepted {
			if result.err.len > 0 {
				hexv_log('transcription failed: ${result.err}')
				indicator.on_failed(now)
			} else {
				// Off the paint thread: the paste leg can block for ~1 s, and
				// blocking here froze the HUD and made keys.poll miss a quick
				// Ctrl+Space tap entirely.
				host.start_paste(result.text)
			}
		} else if result.generation != 0 {
			hexv_log('transcription discarded')
		}
		mut pasted := PasteResult{}
		if host.paste_ch.try_pop(mut pasted) == .success {
			if pasted.generation != host.generation {
				hexv_log('paste result dropped: dictation superseded')
			} else if pasted.err.len > 0 {
				hexv_log('paste failed: ${pasted.err}')
				indicator.on_failed(now)
			} else {
				hexv_log('pasted: ${pasted.text}')
				indicator.on_completed(now)
			}
		}
		host.idle_check(now)
		dt := now - last_step
		last_step = now
		frame := indicator.step(now, f32(dt), false)
		scene := build_scene(frame)
		rgba := render.render_rgba(&scene)
		surface.present(rgba)
		next_paint = paint_deadline(next_paint, clock.seconds())
		pace(next_paint, &clock)
	}
	hexv_log('quit: leaving the message loop')
	if host.state == .recording {
		quit_save_take(mut host)
	}
	host.shutdown()
	C.timeEndPeriod(1)
	tray_remove_once(surface.hwnd)
	surface.close()
}

// run_exstyle_probe opens the HUD window exactly as run_window does and prints
// its extended style. That number, not a screenshot, says whether a taskbar
// button can appear: WS_EX_TOOLWINDOW (0x80) set means no button and no Alt-Tab
// entry, because Windows excludes tool windows from both.
pub fn run_exstyle_probe() {
	mut surface := layered_surface_open(false) or {
		eprintln('hexv: ${err}')
		return
	}
	ex := u64(C.GetWindowLongPtrA(surface.hwnd, gwl_exstyle))
	println('hwnd=0x${u64(uint(surface.hwnd)):x} GWL_EXSTYLE=0x${ex:x}')
	if ex & u64(ws_ex_toolwindow) != 0 {
		println('  WS_EX_TOOLWINDOW set -> no taskbar button, no Alt-Tab entry')
	} else {
		println('  WS_EX_TOOLWINDOW clear -> a taskbar button can appear')
	}
	println('  WS_EX_NOACTIVATE=${ex & u64(ws_ex_noactivate) != 0} WS_EX_LAYERED=${ex & u64(ws_ex_layered) != 0} WS_EX_TRANSPARENT=${ex & u64(ws_ex_transparent) != 0}')
	println('  tray icon resource 1: ${if tray_icon() != voidptr(0) { 'present' } else { 'MISSING' }}')
	surface.close()
}

// run_paint_pacing paints the same frames through the same present path 601
// times with no visible window and reports the 600 inter-paint intervals.
pub fn run_paint_pacing() {
	mut surface := layered_surface_open(false) or {
		println('paint pacing: ${err}')
		return
	}
	C.timeBeginPeriod(1)
	mut clock := paint_clock_new()
	mut indicator := indicator_new(tuning_default())
	mut phrase := DemoPhrase{}
	mut msg := W32Msg{}
	mut last_step := clock.seconds()
	phrase.begin(mut indicator, last_step, false)
	mut next_paint := last_step
	mut intervals := []f64{cap: paint_probe_frames}
	mut previous := u64(0)
	mut paints := 0
	for _ in 0 .. paint_probe_frames + 1 {
		surface.pump(mut msg)
		now := clock.seconds()
		phrase.tick(mut indicator, now, false)
		dt := now - last_step
		last_step = now
		frame := indicator.step(now, f32(dt), false)
		scene := build_scene(frame)
		rgba := render.render_rgba(&scene)
		surface.present(rgba)
		stamp := clock.nanos()
		if paints > 0 {
			intervals << f64(stamp - previous) / 1_000_000.0
		}
		previous = stamp
		paints++
		next_paint = paint_deadline(next_paint, now)
		pace(next_paint, &clock)
	}
	C.timeEndPeriod(1)
	surface.close()
	if intervals.len == 0 {
		println('paint pacing: no paints recorded')
		return
	}
	mut sorted := intervals.clone()
	sorted.sort()
	p50 := sorted[sorted.len / 2]
	p95 := sorted[int(f64(sorted.len - 1) * 0.95)]
	println('paint pacing: paints=${paints} intervals=${intervals.len} p50=${p50:.2f}ms p95=${p95:.2f}ms max=${sorted.last():.2f}ms')
}
