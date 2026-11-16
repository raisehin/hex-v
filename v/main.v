module main

import os

@[console]
fn main() {
	mode := if os.args.len > 1 { os.args[1] } else { 'run' }
	match mode {
		'run' { run_window() }
		'replay' { run_replay(if os.args.len > 2 { os.args[2] } else { 'out' }) }
		'render' { run_render(if os.args.len > 2 { os.args[2] } else { 'out' }) }
		'probe' { run_probe() }
		'exstyle' { run_exstyle_probe() }
		'paint-probe' { run_paint_pacing() }
		'transcribe' {
			if os.args.len < 3 {
				println('usage: hexv transcribe <file.wav> [model] [language]')
				return
			}
			run_transcribe_cli(os.args[2], if os.args.len > 3 { os.args[3] } else { '' }, if os.args.len > 4 {
				os.args[4]
			} else {
				''
			})
		}
		'record' {
			if os.args.len < 4 {
				println('usage: hexv record <seconds> <file.wav>')
				return
			}
			run_record_cli(os.args[2].f64(), os.args[3])
		}
		'paste-file' {
			if os.args.len < 3 {
				println('usage: hexv paste-file <file.wav>')
				return
			}
			run_paste_cli(os.args[2])
		}
		else {
			println('usage: hexv [run|replay [dir]|render [dir]|probe|paint-probe|transcribe <wav>|record <sec> <wav>|paste-file <wav>]')
		}
	}
}
