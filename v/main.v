module main

import os

fn main() {
	mode := if os.args.len > 1 { os.args[1] } else { 'replay' }
	match mode {
		'replay' { run_replay(if os.args.len > 2 { os.args[2] } else { 'out' }) }
		else { println('usage: hexv replay [dir]') }
	}
}
