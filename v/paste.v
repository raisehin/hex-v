// Clipboard paste bridge: puts a UTF-8 transcript on the clipboard, sends the
// configured paste chord to the window that currently holds keyboard focus,
// then restores the previous clipboard text.
//
// Restore is text-only: images/HTML/file lists are not preserved. A previous
// clipboard with no Unicode text is reported after the paste.
module main

import clipboard
import encoding.utf8
import time

#flag -luser32
#include <windows.h>

const paste_input_keyboard = u32(1)
const paste_keyeventf_keyup = u32(0x0002)
const paste_keyeventf_unicode = u32(0x0004)
const paste_vk_control = u16(0x11)
const paste_vk_shift = u16(0x10)
const paste_vk_menu = u16(0x12)
const paste_vk_lwin = u16(0x5B)
const paste_vk_rwin = u16(0x5C)
const paste_vk_v = u16(0x56)
const paste_vk_insert = u16(0x2D)
const paste_key_down_mask = 0x8000
const paste_restore_delay_ms = 500
const paste_wait_modifiers_ms = 500
const cp_utf8 = u32(65001)
const mb_err_invalid_chars = u32(8)
const cf_unicodetext = u32(13)

enum PasteMode {
	ctrl_v
	ctrl_shift_v
	shift_insert
	type
}

// INPUT, flattened to its 40-byte x64 layout.
struct W32Input {
	kind       u32
	align_pad  u32
	w_vk       u16
	w_scan     u16
	flags      u32
	stamp      u32
	union_pad  u32
	extra_info u64
	union_tail [8]u8
}

fn C.GetClipboardSequenceNumber() u32
fn C.SendInput(count u32, inputs voidptr, size i32) u32
fn C.IsClipboardFormatAvailable(format u32) i32
fn C.CountClipboardFormats() i32
fn C.MultiByteToWideChar(code_page u32, flags u32, text &char, text_len i32, out &u16, out_len i32) i32

fn paste_mode() PasteMode {
	return match host_config().paste_keys {
		'ctrl_shift_v' { .ctrl_shift_v }
		'shift_insert' { .shift_insert }
		'type' { .type }
		else { .ctrl_v }
	}
}

// sanitize_transcript repairs raw detokenizer bytes: invalid UTF-8 becomes
// U+FFFD and C0 controls other than tab/newline/CR and DEL are dropped.
fn sanitize_transcript(text string) (string, int) {
	mut out := []u8{}
	mut fixups := 0
	mut i := 0
	for i < text.len {
		r, mut n := utf8.decode_rune_at(text, i)
		if n <= 0 {
			n = 1
		}
		if n == 1 && r == rune(0xFFFD) {
			out << u8(0xef)
			out << u8(0xbf)
			out << u8(0xbd)
			fixups++
			i++
			continue
		}
		if (r < 0x20 && r != rune(0x09) && r != rune(0x0a) && r != rune(0x0d)) || r == rune(0x7f) {
			fixups++
			i += n
			continue
		}
		for k in 0 .. n {
			if i + k < text.len {
				out << text[i + k]
			}
		}
		i += n
	}
	return out.bytestr(), fixups
}

fn paste_key_held(vk u16) bool {
	return int(C.GetAsyncKeyState(i32(vk))) & paste_key_down_mask != 0
}

fn paste_wait_for_modifiers() {
	for _ in 0 .. paste_wait_modifiers_ms / 10 {
		if !paste_key_held(paste_vk_control) && !paste_key_held(paste_vk_shift)
			&& !paste_key_held(paste_vk_menu) && !paste_key_held(paste_vk_lwin)
			&& !paste_key_held(paste_vk_rwin) {
			return
		}
		time.sleep(10 * time.millisecond)
	}
}

fn paste_key_event(vk u16, release bool) W32Input {
	return W32Input{
		kind:       paste_input_keyboard
		align_pad:  u32(0)
		w_vk:       vk
		w_scan:     u16(0)
		flags:      if release { paste_keyeventf_keyup } else { u32(0) }
		stamp:      u32(0)
		union_pad:  u32(0)
		extra_info: u64(0)
		union_tail: [u8(0), 0, 0, 0, 0, 0, 0, 0]!
	}
}

fn paste_unicode_event(unit u16, release bool) W32Input {
	return W32Input{
		kind:       paste_input_keyboard
		align_pad:  u32(0)
		w_vk:       u16(0)
		w_scan:     unit
		flags:      paste_keyeventf_unicode | if release { paste_keyeventf_keyup } else { u32(0) }
		stamp:      u32(0)
		union_pad:  u32(0)
		extra_info: u64(0)
		union_tail: [u8(0), 0, 0, 0, 0, 0, 0, 0]!
	}
}

fn send_input_events(events []W32Input) bool {
	if events.len == 0 {
		return true
	}
	mut sent_total := u32(0)
	for start := 0; start < events.len; start += 128 {
		end := if start + 128 < events.len { start + 128 } else { events.len }
		n := C.SendInput(u32(end - start), events[start..].data, i32(sizeof(W32Input)))
		sent_total += n
		if int(n) != end - start {
			return false
		}
	}
	return int(sent_total) == events.len
}

fn send_paste_chord(mode PasteMode) bool {
	if mode == .type {
		return false
	}
	ctrl_held := paste_key_held(paste_vk_control)
	shift_held := paste_key_held(paste_vk_shift)
	mut events := []W32Input{cap: 6}
	need_ctrl := mode != .shift_insert
	if need_ctrl && !ctrl_held {
		events << paste_key_event(paste_vk_control, false)
	}
	if mode == .ctrl_shift_v {
		if !shift_held {
			events << paste_key_event(paste_vk_shift, false)
		}
		events << paste_key_event(paste_vk_v, false)
		events << paste_key_event(paste_vk_v, true)
		if !shift_held {
			events << paste_key_event(paste_vk_shift, true)
		}
	} else if mode == .shift_insert {
		if !shift_held {
			events << paste_key_event(paste_vk_shift, false)
		}
		events << paste_key_event(paste_vk_insert, false)
		events << paste_key_event(paste_vk_insert, true)
		if !shift_held {
			events << paste_key_event(paste_vk_shift, true)
		}
	} else {
		events << paste_key_event(paste_vk_v, false)
		events << paste_key_event(paste_vk_v, true)
	}
	if need_ctrl && !ctrl_held {
		events << paste_key_event(paste_vk_control, true)
	}
	return send_input_events(events)
}

fn type_text(text string) bool {
	if text.len == 0 {
		return true
	}
	units := C.MultiByteToWideChar(cp_utf8, mb_err_invalid_chars, text.str, i32(text.len),
		0, 0)
	if units <= 0 {
		return false
	}
	mut wide := []u16{len: int(units)}
	n := C.MultiByteToWideChar(cp_utf8, mb_err_invalid_chars, text.str, i32(text.len),
		wide.data, i32(units))
	if n != units {
		return false
	}
	mut events := []W32Input{len: wide.len * 2}
	for i, unit in wide {
		events[i * 2] = paste_unicode_event(unit, false)
		events[i * 2 + 1] = paste_unicode_event(unit, true)
	}
	return send_input_events(events)
}

fn paste_restore_text(mut cb &clipboard.Clipboard, old_text string, old_had_text bool, clip_seq u32) {
	if C.GetClipboardSequenceNumber() != clip_seq {
		hexv_log('paste: clipboard changed after paste, previous text not restored')
		return
	}
	if !cb.copy(old_text) {
		hexv_log('paste: could not restore previous clipboard text')
		return
	}
	if !old_had_text {
		hexv_log('paste: clipboard held no Unicode text before, it is now empty')
	}
}

fn paste_text(text string) ! {
	mut payload, fixups := sanitize_transcript(text)
	payload = payload.trim_space()
	if payload == '' {
		return error('paste_text: the transcript is empty')
	}
	if fixups > 0 {
		hexv_log('paste: repaired ${fixups} undecodable/control byte(s)')
	}
	mode := paste_mode()
	if mode == .type {
		paste_wait_for_modifiers()
		if !type_text(payload) {
			return error('paste_text: SendInput rejected typed text')
		}
		hexv_log('pasted ${payload.len} chars via type')
		return
	}
	paste_wait_for_modifiers()
	mut cb := clipboard.new()
	defer {
		cb.destroy()
	}
	old_text := cb.paste()
	old_had_text := old_text != ''
	non_text := !old_had_text && C.CountClipboardFormats() > 0
	old_seq := C.GetClipboardSequenceNumber()
	if !cb.copy(payload) {
		return error('paste_text: could not put the transcript on the clipboard')
	}
	clip_seq := C.GetClipboardSequenceNumber()
	if clip_seq == old_seq {
		return error('paste_text: the clipboard write did not take effect')
	}
	if non_text {
		hexv_log('paste: replacing non-restorable clipboard content')
	}
	if !send_paste_chord(mode) {
		paste_restore_text(mut cb, old_text, old_had_text, clip_seq)
		return error('paste_text: SendInput rejected the paste chord')
	}
	time.sleep(paste_restore_delay_ms * time.millisecond)
	paste_restore_text(mut cb, old_text, old_had_text, clip_seq)
	hexv_log('pasted ${payload.len} chars via ${mode}')
}
