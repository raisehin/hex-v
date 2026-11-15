// Default-microphone capture through the legacy waveIn API.
//
// waveIn is used instead of WASAPI because it needs no COM, no activation and
// no device enumeration: WAVE_MAPPER opens the default capture endpoint, and a
// ring of prepared WAVEHDRs hands 50 ms of 16-bit PCM at a time to pump(). The
// chunk arrives interleaved at the device rate, is downmixed to f32 mono at
// that rate, and only the finished recording is linearly resampled to 16 kHz in
// stop(), so no resampler state spans chunks and no seam can appear.
module main

import math
import sync

#flag -lwinmm
#include <windows.h>
#include <mmsystem.h>

// Win32 constants, spelled out because the declarations below are hand-rolled.
const wave_mapper = u32(0xFFFFFFFF)
const callback_null = u64(0)
const wave_format_pcm = u16(1)
const whdr_done = u32(0x00000001)
const mmsyserr_noerror = u32(0)
const mmsyserr_baddeviceid = u32(2)
const mmsyserr_allocated = u32(4)
const mmsyserr_invalhandle = u32(5)
const mmsyserr_nodriver = u32(6)
const mmsyserr_nomem = u32(7)
const mmsyserr_notsupported = u32(8)
const mmsyserr_invalparam = u32(11)
const mmsyserr_notenabled = u32(14)
const wav_err_badformat = u32(32)
const wav_err_stillplaying = u32(33)

// Output contract: mono f32 at 16 kHz, the rate transcribe.cpp consumes.
const capture_out_rate = 16000
// 50 buffers of 20 ms each: one second of slack for a long pump() gap, small
// enough that pump() stays cheap at HUD cadence.
const capture_buffer_count = 50
const capture_buffer_divisor = 50
// Level window: 50 ms at 16 kHz, per the HUD spec.
const capture_rms_window = 800
const capture_rms_floor = f32(-120.0)

// Candidate device formats, 16-bit PCM only, most preferred first.
struct CaptureFormat {
	rate     u32
	channels u16
}

const capture_formats = [
	CaptureFormat{
		rate:     16000
		channels: 1
	},
	CaptureFormat{
		rate:     48000
		channels: 1
	},
	CaptureFormat{
		rate:     44100
		channels: 1
	},
	CaptureFormat{
		rate:     48000
		channels: 2
	},
	CaptureFormat{
		rate:     44100
		channels: 2
	},
	CaptureFormat{
		rate:     32000
		channels: 1
	},
]

// WAVEFORMATEX, field for field. V's `int` is 64-bit, so every C WORD/DWORD is
// spelled u16/u32 and the struct stays byte-exact for waveInOpen. V pads the
// struct to 20 bytes where the SDK type is 18; only the fields up to cbSize are
// read, so the tail padding is inert.
struct HexWaveFormatEx {
	format_tag        u16
	channels          u16
	samples_per_sec   u32
	avg_bytes_per_sec u32
	block_align       u16
	bits_per_sample   u16
	extra_size        u16
}

// WAVEHDR, field for field. lpData is a pointer, dwUser is DWORD_PTR (u64 on
// x64) and reserved is ULONG_PTR, so those three are pointer-sized; the rest
// are 32-bit.
struct HexWaveHdr {
mut:
	lp_data         voidptr
	buffer_length   u32
	bytes_recorded  u32
	user            u64
	flags           u32
	loops           u32
	lp_next         voidptr
	reserved        u64
}

fn C.waveInGetNumDevs() u32
fn C.waveInOpen(handle &voidptr, device u32, format &HexWaveFormatEx, callback u64, instance u64, flags u32) u32
fn C.waveInPrepareHeader(handle voidptr, hdr &HexWaveHdr, size u32) u32
fn C.waveInUnprepareHeader(handle voidptr, hdr &HexWaveHdr, size u32) u32
fn C.waveInAddBuffer(handle voidptr, hdr &HexWaveHdr, size u32) u32
fn C.waveInStart(handle voidptr) u32
fn C.waveInStop(handle voidptr) u32
fn C.waveInReset(handle voidptr) u32
fn C.waveInClose(handle voidptr) u32

// capture_error_text names the MMRESULT codes the driver can return here.
fn capture_error_text(code u32) string {
	return match code {
		mmsyserr_baddeviceid { 'MMSYSERR_BADDEVICEID' }
		mmsyserr_allocated { 'MMSYSERR_ALLOCATED' }
		mmsyserr_invalhandle { 'MMSYSERR_INVALHANDLE' }
		mmsyserr_nodriver { 'MMSYSERR_NODRIVER' }
		mmsyserr_nomem { 'MMSYSERR_NOMEM' }
		mmsyserr_notsupported { 'MMSYSERR_NOTSUPPORTED' }
		mmsyserr_invalparam { 'MMSYSERR_INVALPARAM' }
		mmsyserr_notenabled { 'MMSYSERR_NOTENABLED' }
		wav_err_badformat { 'WAVERR_BADFORMAT' }
		wav_err_stillplaying { 'WAVERR_STILLPLAYING' }
		else { 'unknown' }
	}
}

// capture_available is the number of capture endpoints the waveIn mapper can
// reach; 0 means there is no microphone at all.
fn capture_available() int {
	return int(C.waveInGetNumDevs())
}

// Capture owns one waveIn handle plus the prepared buffer ring. The header and
// PCM arrays are allocated once in start() and never grow afterwards, because
// every WAVEHDR.lpData points into that PCM allocation for as long as the
// device holds the buffer.
struct Capture {
mut:
	mu                sync.Mutex
	active            bool
	device            voidptr // HWAVEIN
	rate              u32 // device sample rate of the open stream
	channels          int
	block_align       int
	frames_per_buffer int
	buffers           []HexWaveHdr
	pcm               []i16 // interleaved device-rate input; never resized
	samples           []f32 // downmixed mono at `rate`; appended by pump()
}

// start opens the default microphone with the first format the driver accepts,
// prepares the buffer ring and begins recording. Every failure path returns a
// descriptive error and leaves the handle closed.
fn (mut c Capture) start() ! {
	if c.active {
		return error('capture: start called while already recording')
	}
	devices := capture_available()
	if devices <= 0 {
		return error('capture: no capture device (waveInGetNumDevs returned 0)')
	}
	mut last_result := u32(0)
	for format in capture_formats {
		mut fmt := HexWaveFormatEx{
			format_tag:         wave_format_pcm
			channels:           format.channels
			samples_per_sec:    format.rate
			avg_bytes_per_sec:  format.rate * u32(format.channels) * 2
			block_align:        format.channels * 2
			bits_per_sample:    16
			extra_size:         0
		}
		mut handle := voidptr(0)
		result := C.waveInOpen(&handle, wave_mapper, &fmt, callback_null, callback_null,
			u32(0))
		if result != mmsyserr_noerror {
			last_result = result
			continue
		}
		c.device = handle
		c.rate = format.rate
		c.channels = int(format.channels)
		break
	}
	if c.device == voidptr(0) {
		return error('capture: waveInOpen failed for every format (last MMRESULT ${last_result} ${capture_error_text(last_result)})')
	}

	// Fresh recording: the ring and the downmixed tail both start empty.
	c.samples.clear()
	c.block_align = c.channels * 2
	c.frames_per_buffer = int(c.rate) / capture_buffer_divisor
	if c.frames_per_buffer < 1 {
		c.frames_per_buffer = 1
	}
	block_samples := c.frames_per_buffer * c.channels
	c.pcm = []i16{len: block_samples * capture_buffer_count}
	// The ring is built completely before the first prepare: each lpData points
	// into c.pcm, so the slice must never grow once the driver owns it.
	c.buffers = []HexWaveHdr{cap: capture_buffer_count}
	for i in 0 .. capture_buffer_count {
		c.buffers << HexWaveHdr{
			lp_data:        unsafe { voidptr(c.pcm[i * block_samples..(i + 1) * block_samples].data) }
			buffer_length:  u32(block_samples * 2)
			bytes_recorded: 0
			user:           0
			flags:          0
			loops:          0
			lp_next:        voidptr(0)
			reserved:       0
		}
	}
	for i in 0 .. c.buffers.len {
		result := C.waveInPrepareHeader(c.device, unsafe { &c.buffers[i] }, u32(sizeof(HexWaveHdr)))
		if result != mmsyserr_noerror {
			c.teardown(false)
			return error('capture: waveInPrepareHeader failed (MMRESULT ${result} ${capture_error_text(result)})')
		}
		result_add := C.waveInAddBuffer(c.device, unsafe { &c.buffers[i] }, u32(sizeof(HexWaveHdr)))
		if result_add != mmsyserr_noerror {
			c.teardown(false)
			return error('capture: waveInAddBuffer failed (MMRESULT ${result_add} ${capture_error_text(result_add)})')
		}
	}
	result_start := C.waveInStart(c.device)
	if result_start != mmsyserr_noerror {
		c.teardown(false)
		return error('capture: waveInStart failed (MMRESULT ${result_start} ${capture_error_text(result_start)})')
	}
	c.active = true
}

// pump drains every buffer the driver has filled, appends its audio to the
// recording and re-queues it. Call it at HUD cadence; it never allocates the
// ring, only grows the downmixed sample tail.
fn (mut c Capture) pump() {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	if !c.active {
		return
	}
	c.drain_locked(true)
}

// rms_db is the level of the last ~50 ms of the recording, clamped to
// [-120, 0]. With no data it reports the floor.
fn (c &Capture) rms_db() f32 {
	n := if c.samples.len < capture_rms_window { c.samples.len } else { capture_rms_window }
	if n == 0 {
		return capture_rms_floor
	}
	mut sum := f64(0)
	for i in c.samples.len - n .. c.samples.len {
		s := f64(c.samples[i])
		sum += s * s
	}
	mean_square := sum / f64(n)
	db := 10.0 * math.log10(mean_square + 1e-12)
	if db < f64(capture_rms_floor) {
		return capture_rms_floor
	}
	if db > 0.0 {
		return f32(0.0)
	}
	return f32(db)
}


// snapshot_16k returns the whole recording as mono 16 kHz f32. The segmenter
// uses snapshot_16k_from; this remains for callers that need the complete take.
fn (mut c Capture) snapshot_16k() []f32 {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	return c.snapshot_16k_from_locked(0)
}

// snapshot_16k_from returns only the 16 kHz suffix starting at start_16k. At
// 16 kHz this is a direct slice clone; otherwise the resample starts at the
// absolute device index so the suffix grid matches stop()'s whole-take grid.
fn (mut c Capture) snapshot_16k_from(start_16k int) []f32 {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	return c.snapshot_16k_from_locked(start_16k)
}

fn (mut c Capture) snapshot_16k_from_locked(start_16k int) []f32 {
	mut s16 := start_16k
	if s16 < 0 {
		s16 = 0
	}
	rate := int(c.rate)
	if rate <= 0 || c.samples.len == 0 {
		return []f32{}
	}
	if rate == capture_out_rate {
		if s16 >= c.samples.len {
			return []f32{}
		}
		return c.samples[s16..].clone()
	}
	n_out_abs := int(f64(c.samples.len) * f64(capture_out_rate) / f64(rate))
	if s16 >= n_out_abs {
		return []f32{}
	}
	n_out := n_out_abs - s16
	mut out := []f32{len: n_out}
	last := c.samples.len - 1
	for i in 0 .. n_out {
		src := f64(s16 + i) * f64(rate) / f64(capture_out_rate)
		i0 := int(src)
		t := f32(src - f64(i0))
		a := c.samples[if i0 < last { i0 } else { last }]
		b := c.samples[if i0 + 1 < last { i0 + 1 } else { last }]
		out[i] = a + (b - a) * t
	}
	return out
}

// native_len is the number of mono samples recorded at the device rate so far.
fn (c &Capture) native_len() int {
	return c.samples.len
}

// stop ends the stream, keeps what was recorded, and returns the whole
// recording as mono f32 linearly resampled to 16 kHz. Calling it when nothing
// is recording returns an empty slice.
fn (mut c Capture) stop() ![]f32 {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	if !c.active {
		return []f32{}
	}
	rate := int(c.rate)
	c.teardown_locked(true)
	out := capture_resample_16k(c.samples, rate)
	c.samples.clear()
	return out
}

// cancel ends the stream and throws the recording away. Safe to call when
// nothing is recording.
fn (mut c Capture) cancel() {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	if !c.active {
		// A start() that failed mid-way already tore itself down; make sure no
		// stale tail survives either way.
		c.samples.clear()
		return
	}
	c.teardown_locked(false)
	c.samples.clear()
}

// drain collects the done buffers. When requeue is set they go back to the
// driver, otherwise (during shutdown) they are only harvested. Callers hold
// c.mu; drain_locked is the shared body.
fn (mut c Capture) drain(requeue bool) {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	c.drain_locked(requeue)
}

fn (mut c Capture) drain_locked(requeue bool) {
	for i in 0 .. c.buffers.len {
		if c.buffers[i].flags & whdr_done == 0 {
			continue
		}
		recorded := int(c.buffers[i].bytes_recorded)
		if recorded > 0 {
			c.append_block(i, recorded)
		}
		c.buffers[i].bytes_recorded = 0
		// Clear only WHDR_DONE: WHDR_PREPARED has to survive so the header can be
		// handed back to the driver as-is.
		c.buffers[i].flags &= ~whdr_done
		if requeue {
			C.waveInAddBuffer(c.device, unsafe { &c.buffers[i] }, u32(sizeof(HexWaveHdr)))
		}
	}
}

// append_block downmixes the interleaved i16 of buffer `index` into mono f32 in
// [-1, 1]: each channel sample is divided by 32768 and averaged across channels.
// The caller holds c.mu.
fn (mut c Capture) append_block(index int, bytes int) {
	frames := bytes / c.block_align
	if frames <= 0 {
		return
	}
	base := index * c.frames_per_buffer * c.channels
	limit := (index + 1) * c.frames_per_buffer * c.channels
	for f in 0 .. frames {
		mut sum := f32(0)
		for ch in 0 .. c.channels {
			sample_index := base + f * c.channels + ch
			if sample_index >= limit {
				break
			}
			sum += f32(c.pcm[sample_index]) / 32768.0
		}
		c.samples << sum / f32(c.channels)
	}
}

// teardown stops and closes the stream. waveInReset marks every queued buffer
// WHDR_DONE, so the harvest after it sees the driver's final data.
fn (mut c Capture) teardown(harvest bool) {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	c.teardown_locked(harvest)
}

fn (mut c Capture) teardown_locked(harvest bool) {
	handle := c.device
	if handle != voidptr(0) {
		C.waveInStop(handle)
		C.waveInReset(handle)
		if harvest {
			c.drain_locked(false)
		}
		for i in 0 .. c.buffers.len {
			C.waveInUnprepareHeader(handle, unsafe { &c.buffers[i] }, u32(sizeof(HexWaveHdr)))
		}
		C.waveInClose(handle)
	}
	c.device = voidptr(0)
	c.active = false
	c.buffers.clear()
	c.pcm.clear()
}

// capture_resample_16k is the same linear interpolation as the reference
// wav_read_mono16k: output sample i reads the source at i * rate / 16000 and
// blends the two neighbouring samples.
fn capture_resample_16k(mono []f32, rate int) []f32 {
	if mono.len == 0 || rate <= 0 {
		return []f32{}
	}
	if rate == capture_out_rate {
		return mono.clone()
	}
	n_out := int(f64(mono.len) * f64(capture_out_rate) / f64(rate))
	mut out := []f32{len: n_out}
	last := mono.len - 1
	for i in 0 .. n_out {
		src := f64(i) * f64(rate) / f64(capture_out_rate)
		i0 := int(src)
		t := f32(src - f64(i0))
		a := mono[if i0 < last { i0 } else { last }]
		b := mono[if i0 + 1 < last { i0 + 1 } else { last }]
		out[i] = a + (b - a) * t
	}
	return out
}
