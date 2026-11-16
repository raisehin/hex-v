import Lake
open Lake DSL

package "lean_comparison" where
  version := v!"0.1.0"

lean_lib DotScope
lean_lib Replay

@[default_target]
lean_exe "replay" where
  root := `Main

lean_exe "verify" where
  root := `Verify

lean_exe "tests" where
  root := `Tests
  supportInterpreter := true
