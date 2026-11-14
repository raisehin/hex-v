// Measures the real WM_TIMER spacing that SetTimer(42) produces on a
// message-only window, so the HUD can tell a true 24 fps cadence (42 ms) from
// the Win32 default 15.625 ms tick rounding (46.875 ms = 3 ticks).
// timeBeginPeriod(1) is deliberately NOT called: the default system timer
// resolution is what the HUD has to live with.
module main

#include <windows.h>
#flag -luser32

const probe_hwnd_message = voidptr(-3)
const probe_wm_timer = u32(0x0113)
const probe_intervals = 600

fn C.CreateWindowExW(dw_ex_style u32, class_name &u16, window_name &u16, dw_style u32, x int, y int, w int, h int, parent voidptr, menu voidptr, instance voidptr, param voidptr) C.HWND
fn C.SetTimer(hwnd C.HWND, id uint, elapse u32, proc voidptr) uint
fn C.KillTimer(hwnd C.HWND, id uint) bool
fn C.DestroyWindow(hwnd C.HWND)
fn C.GetMessageW(msg &W32Msg, hwnd C.HWND, lo u32, hi u32) int
fn C.DispatchMessageW(msg &W32Msg) C.LRESULT
fn C.QueryPerformanceCounter(count &u64) C.BOOL
fn C.QueryPerformanceFrequency(freq &u64) C.BOOL

// probe_percentile picks from an ascending slice, clamped to its last element.
fn probe_percentile(sorted []f64, q f64) f64 {
	idx := int(f64(sorted.len) * q)
	return sorted[if idx < sorted.len { idx } else { sorted.len - 1 }]
}

// run_probe prints the WM_TIMER spacing distribution for SetTimer(42).
pub fn run_probe() {
	mut freq := u64(0)
	C.QueryPerformanceFrequency(&freq)
	hwnd := C.CreateWindowExW(0, 'STATIC'.to_wide(), 'hexv probe'.to_wide(), 0, 0, 0, 0, 0,
		probe_hwnd_message, unsafe { nil }, unsafe { nil }, unsafe { nil })
	if hwnd == unsafe { nil } {
		println('probe: CreateWindowExW(HWND_MESSAGE) failed')
		return
	}
	// STATIC's DefWindowProc ignores WM_TIMER, so a nil TIMERPROC is enough:
	// every tick still lands in this thread's queue and is timestamped here.
	C.SetTimer(hwnd, 1, 42, unsafe { nil })
	mut msg := W32Msg{}
	mut prev := u64(0)
	mut ticks := 0
	mut intervals := []f64{cap: probe_intervals}
	for ticks <= probe_intervals {
		if C.GetMessageW(&msg, unsafe { nil }, 0, 0) <= 0 {
			break
		}
		C.TranslateMessage(&msg)
		C.DispatchMessageW(&msg)
		if msg.message == probe_wm_timer {
			mut now := u64(0)
			C.QueryPerformanceCounter(&now)
			if ticks > 0 {
				intervals << f64(now - prev) * 1000.0 / f64(freq)
			}
			prev = now
			ticks++
		}
	}
	C.KillTimer(hwnd, 1)
	C.DestroyWindow(hwnd)
	if intervals.len != probe_intervals {
		println('probe: expected ${probe_intervals} intervals, got ${intervals.len}')
	}
	mut sorted := intervals.clone()
	sorted.sort()
	mut sum := 0.0
	mut hist := map[int]int{}
	for t in intervals {
		sum += t
		hist[int(t * 2.0 + 0.5)]++ // round to 0.5 ms buckets
	}
	near_42 := intervals.filter(it > 40.5 && it < 43.5).len
	near_46 := intervals.filter(it > 45.4 && it < 48.4).len
	dominant := if near_42 > near_46 {
		'~42 ms (24 fps)'
	} else {
		'~46.875 ms (15.625 ms tick rounding)'
	}
	println('SetTimer(42): n=${intervals.len} p50=${probe_percentile(sorted, 0.50):.3f} p95=${probe_percentile(sorted, 0.95):.3f} max=${probe_percentile(sorted, 1.0):.3f} ms')
	println('mean=${sum / f64(intervals.len):.3f} ms; dominant mode ${dominant} [~42:${near_42} ~46.875:${near_46}]')
	mut buckets := hist.keys()
	buckets.sort()
	mut cells := []string{cap: buckets.len}
	for b in buckets {
		cells << '${f64(b) / 2.0:.1f}:${hist[b]}'
	}
	println('hist(0.5ms): ' + cells.join(' '))
}
