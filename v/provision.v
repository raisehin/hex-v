// Terminal-only model provisioning. build-github.ps1 never calls this path;
// users invoke `hexv models check` or `hexv models install` explicitly.
module main

import os

fn run_provision_cli(args []string) {
	script := '${os.dir(os.dir(os.dir(os.executable())))}\\provision-models.ps1'
	if !os.exists(script) {
		eprintln('hexv: provisioning script missing: ${script}')
		exit(1)
	}
	mut exec_args := ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script]
	if args.len > 0 && args[0] == 'check' {
		exec_args << '-CheckOnly'
	}
	result := os.exec(exec_args)
	if result.exit_code != 0 {
		if result.output.len > 0 {
			eprint(result.output)
		}
		exit(result.exit_code)
	}
	if result.output.len > 0 {
		print(result.output)
	}
}
