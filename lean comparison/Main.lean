import Replay

def main (args : List String) : IO Unit := do
  let dir : System.FilePath := args.head?.getD "out"
  writeReplay dir
