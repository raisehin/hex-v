// Minimal 16-bit PCM RIFF/WAVE reader and writer. The reader downmixes to mono
// and linearly resamples to 16 kHz, matching odin-hex/src/wav.odin so hex.exe
// and hexv hear the same samples.
module main

import os

fn wav_read_mono16k(path string) ![]f32 {
	data := os.read_bytes(path)!
	if data.len < 44 || data[0..4].bytestr() != 'RIFF' || data[8..12].bytestr() != 'WAVE' {
		return error('not a RIFF/WAVE file: ${path}')
	}
	mut channels := u16(1)
	mut bits := u16(16)
	mut src_rate := u32(16000)
	mut frames := []i16{}
	mut off := 12
	for off + 8 <= data.len {
		id := data[off..off + 4].bytestr()
		mut size := int(u32(data[off + 4]) | (u32(data[off + 5]) << 8) | (u32(data[off + 6]) << 16) | (u32(data[off + 7]) << 24))
		body := off + 8
		if body + size > data.len {
			size = data.len - body
		}
		if id == 'fmt ' && size >= 16 {
			channels = u16(data[body + 2]) | (u16(data[body + 3]) << 8)
			src_rate = u32(data[body + 4]) | (u32(data[body + 5]) << 8) | (u32(data[body + 6]) << 16) | (u32(data[body + 7]) << 24)
			bits = u16(data[body + 14]) | (u16(data[body + 15]) << 8)
		} else if id == 'data' && bits == 16 {
			n := size / 2
			frames = []i16{len: n}
			for i in 0 .. n {
				frames[i] = i16(u16(data[body + i * 2]) | (u16(data[body + i * 2 + 1]) << 8))
			}
		}
		off = body + size + (size & 1)
	}
	if frames.len == 0 || channels == 0 {
		return error('no 16-bit PCM frames in ${path}')
	}
	mut mono := []f32{len: frames.len / int(channels)}
	for i in 0 .. mono.len {
		mut sum := f32(0)
		for c in 0 .. int(channels) {
			sum += f32(frames[i * int(channels) + c]) / 32768.0
		}
		mono[i] = sum / f32(channels)
	}
	return resample_linear(mono, src_rate, 16000)
}

fn resample_linear(input []f32, src_rate u32, dst_rate u32) []f32 {
	if input.len == 0 || src_rate == 0 || dst_rate == 0 {
		return []f32{}
	}
	if src_rate == dst_rate {
		return input.clone()
	}
	n_out := int(f64(input.len) * f64(dst_rate) / f64(src_rate))
	if n_out <= 0 {
		return []f32{}
	}
	mut out := []f32{len: n_out}
	for i in 0 .. n_out {
		src := f32(i) * f32(src_rate) / f32(dst_rate)
		i0 := int(src)
		t := src - f32(i0)
		a := input[if i0 < input.len { i0 } else { input.len - 1 }]
		b := input[if i0 + 1 < input.len { i0 + 1 } else { input.len - 1 }]
		out[i] = a + (b - a) * t
	}
	return out
}

fn wav_write_f32(path string, samples []f32, rate u32) ! {
	data_bytes := samples.len * 2
	mut b := []u8{len: 44 + data_bytes}
	copy(mut b[0..4], 'RIFF'.bytes())
	put_le32(mut b, 4, u32(36 + data_bytes))
	copy(mut b[8..12], 'WAVE'.bytes())
	copy(mut b[12..16], 'fmt '.bytes())
	put_le32(mut b, 16, 16)
	put_le16(mut b, 20, 1)
	put_le16(mut b, 22, 1)
	put_le32(mut b, 24, rate)
	put_le32(mut b, 28, rate * 2)
	put_le16(mut b, 32, 2)
	put_le16(mut b, 34, 16)
	copy(mut b[36..40], 'data'.bytes())
	put_le32(mut b, 40, u32(data_bytes))
	for i, s in samples {
		v := clamp_f32(s, -1.0, 1.0)
		put_le16(mut b, 44 + i * 2, u16(i16(v * 32767.0)))
	}
	os.write_file_array(path, b)!
}

fn clamp_f32(x f32, lo f32, hi f32) f32 {
	if x < lo {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}

fn put_le16(mut b []u8, off int, v u16) {
	b[off] = u8(v & 0xff)
	b[off + 1] = u8((v >> 8) & 0xff)
}

fn put_le32(mut b []u8, off int, v u32) {
	b[off] = u8(v & 0xff)
	b[off + 1] = u8((v >> 8) & 0xff)
	b[off + 2] = u8((v >> 16) & 0xff)
	b[off + 3] = u8((v >> 24) & 0xff)
}
