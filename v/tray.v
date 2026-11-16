// Notification-area icon. The HUD is a NOACTIVATE tool window that paints itself
// transparent when idle, so a taskbar button would be a permanent, dead entry:
// it can never take focus and it outlives every take. The reference app keeps
// itself out of the taskbar for the same reason and advertises the mark from the
// tray instead, which is what this file does.
module main

#flag -lshell32
#include <windows.h>
// windows.h only pulls shellapi.h when WIN32_LEAN_AND_MEAN is undefined, and V
// builds lean, so Shell_NotifyIconW has to be declared explicitly.
#include <shellapi.h>

const tray_uid = u32(1)
const tray_message = u32(0x8001) // WM_APP + 1
const tray_menu_quit = u32(1)

const nim_add = u32(0)
const nim_delete = u32(2)
const nif_message = u32(0x1)
const nif_icon = u32(0x2)
const nif_tip = u32(0x4)
const nif_showtip = u32(0x80)

const wm_command = u32(0x111)
const wm_contextmenu = u32(0x7b)
const wm_rbuttonup = u32(0x205)
const wm_lbuttonup = u32(0x202)
const wm_seticon = u32(0x80)
const wm_null = u32(0)

const image_icon = u32(1)
const lr_shared = u32(0x8000)
const lr_defaultsize = u32(0x40)
const sm_cxsmicon = i32(49)
const sm_cysmicon = i32(50)
const sm_cxicon = i32(11)
const sm_cyicon = i32(12)

const icon_small = u64(0)
const icon_big = u64(1)

const tpm_rightbutton = u32(0x2)
const tpm_returncmd = u32(0x100)
const tray_tip_cells = 128

// NOTIFYICONDATAW, Vista layout: 976 bytes on x64. cbSize is derived from the
// struct, so a layout mistake surfaces as a refused NIM_ADD (logged) instead of
// as an icon that silently never appears.
struct NotifyIconData {
mut:
	cb_size            u32
	hwnd               voidptr
	uid                u32
	flags              u32
	callback_message   u32
	icon               voidptr
	tip                [tray_tip_cells]u16
	state              u32
	state_mask         u32
	info               [256]u16
	timeout_or_version u32
	info_title         [64]u16
	info_flags         u32
	guid_item          [16]u8
	balloon_icon       voidptr
}

fn C.Shell_NotifyIconW(message u32, data &NotifyIconData) bool
fn C.LoadImageW(instance voidptr, name voidptr, kind u32, cx int, cy int, flags u32) voidptr
fn C.CreatePopupMenu() voidptr
fn C.AppendMenuW(menu voidptr, flags u32, id uint, item &u16) bool
fn C.TrackPopupMenu(menu voidptr, flags u32, x int, y int, reserved int, wnd voidptr, rect voidptr) int
fn C.DestroyMenu(menu voidptr) bool
fn C.GetCursorPos(point &W32Point) bool
fn C.SetForegroundWindow(wnd voidptr) bool
fn C.PostMessageW(wnd voidptr, message u32, wparam u64, lparam u64) bool
fn C.SendMessageW(wnd voidptr, message u32, wparam u64, lparam u64) i64

// app_icon returns an HICON from resource id 1 — the RT_GROUP_ICON that the
// `-icon` compile flag embeds. 0 means the exe really has no icon resource.
fn app_icon(instance voidptr, cx int, cy int) voidptr {
	return C.LoadImageW(instance, voidptr(tray_uid), image_icon, cx, cy, lr_defaultsize | lr_shared)
}

// tray_tip_text fills the fixed szTip block with the tooltip. V's to_wide returns
// a bare pointer, so the copy goes through MultiByteToWideChar like paste.v does.
fn tray_tip_text() [tray_tip_cells]u16 {
	mut out := [tray_tip_cells]u16{}
	text := 'hexv - Ctrl+Space to dictate'
	n := C.MultiByteToWideChar(cp_utf8, mb_err_invalid_chars, text.str, i32(text.len),
		&out[0], tray_tip_cells)
	if n <= 0 {
		return out
	}
	return out
}

fn tray_icon() voidptr {
	instance := C.GetModuleHandleA(voidptr(0))
	return app_icon(instance, int(C.GetSystemMetrics(sm_cxsmicon)),
		int(C.GetSystemMetrics(sm_cysmicon)))
}

fn tray_add(hwnd voidptr) bool {
	icon := tray_icon()
	if icon == voidptr(0) {
		hexv_log('tray: icon resource 1 is missing from the exe')
		return false
	}
	mut nid := NotifyIconData{
		cb_size:          u32(sizeof(NotifyIconData))
		hwnd:             hwnd
		uid:              tray_uid
		flags:            nif_message | nif_icon | nif_tip | nif_showtip
		callback_message: tray_message
		icon:             icon
	}
	tip := tray_tip_text()
	for i in 0 .. tray_tip_cells {
		nid.tip[i] = tip[i]
	}
	if !C.Shell_NotifyIconW(nim_add, &nid) {
		hexv_log('tray: Shell_NotifyIconW(NIM_ADD) failed (cbSize=${sizeof(NotifyIconData)})')
		return false
	}
	hexv_log('tray: icon added (cbSize=${sizeof(NotifyIconData)})')
	return true
}

fn tray_remove(hwnd voidptr) {
	mut nid := NotifyIconData{
		cb_size: u32(sizeof(NotifyIconData))
		hwnd:    hwnd
		uid:     tray_uid
	}
	C.Shell_NotifyIconW(nim_delete, &nid)
}

// tray_menu shows the context menu. SetForegroundWindow before TrackPopupMenu and
// a posted WM_NULL after it is the documented workaround for a menu that would
// otherwise stay up after the click that dismissed it.
fn tray_menu(hwnd voidptr) {
	menu := C.CreatePopupMenu()
	if menu == voidptr(0) {
		return
	}
	C.AppendMenuW(menu, 0, uint(tray_menu_quit), 'Quit hexv'.to_wide())
	mut pt := W32Point{}
	C.GetCursorPos(&pt)
	C.SetForegroundWindow(hwnd)
	C.TrackPopupMenu(menu, tpm_rightbutton | tpm_returncmd, pt.x, pt.y, 0, hwnd, voidptr(0))
	C.PostMessageW(hwnd, wm_null, 0, 0)
	C.DestroyMenu(menu)
}

// tray_handle_message consumes the notification-area callback and the menu
// command. Returns true when the message belonged to the tray.
fn tray_handle_message(hwnd voidptr, msg u32, wparam u64, lparam i64) bool {
	if msg == tray_message {
		if lparam == i64(wm_contextmenu) || lparam == i64(wm_rbuttonup)
			|| lparam == i64(wm_lbuttonup) {
			tray_menu(hwnd)
		}
		return true
	}
	if msg == wm_command && wparam == u64(tray_menu_quit) {
		C.PostQuitMessage(0)
		return true
	}
	return false
}

// tray_set_window_icon puts the mark on the window itself, so the image is the
// app's own and not a default, whatever surface asks for it later.
fn tray_set_window_icon(hwnd voidptr) {
	instance := C.GetModuleHandleA(voidptr(0))
	small := app_icon(instance, int(C.GetSystemMetrics(sm_cxsmicon)),
		int(C.GetSystemMetrics(sm_cysmicon)))
	big := app_icon(instance, int(C.GetSystemMetrics(sm_cxicon)), int(C.GetSystemMetrics(sm_cyicon)))
	if small != voidptr(0) {
		C.SendMessageW(hwnd, wm_seticon, icon_small, u64(uint(small)))
	}
	if big != voidptr(0) {
		C.SendMessageW(hwnd, wm_seticon, icon_big, u64(uint(big)))
	}
}
