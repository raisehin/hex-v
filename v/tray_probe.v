// Exercises the tray quit path without a mouse. It opens the same surface the
// real app uses, adds the icon, posts the WM_COMMAND that a menu selection now
// dispatches, pumps until WM_QUIT, and removes the icon. Exit 0 only when both
// the pump reported quit and NIM_DELETE succeeded.
module main

pub fn run_tray_probe() {
	mut surface := layered_surface_open(false) or {
		eprintln('tray probe: ${err}')
		exit(1)
	}
	if !tray_add(surface.hwnd) {
		println('tray probe: tray_add failed')
		surface.close()
		exit(1)
	}
	if !C.PostMessageW(surface.hwnd, wm_command, u64(tray_menu_quit), 0) {
		println('tray probe: PostMessageW(WM_COMMAND, ${tray_menu_quit}) failed')
		surface.close()
		exit(1)
	}
	mut msg := W32Msg{}
	quit := !surface.pump(mut msg)
	removed := tray_remove_once(surface.hwnd)
	println('tray probe: quit=${quit} icon_removed=${removed}')
	surface.close()
	if quit && removed {
		exit(0)
	}
	exit(1)
}
