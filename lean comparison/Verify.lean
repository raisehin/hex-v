-- Byte-for-byte replay gate against the committed oracle artefacts.
import Replay

open System

def first15 (line : String) : List String := (line.splitOn "\t").take 15

def metaMatches15 (oracle generated : String) : Bool :=
  let a := oracle.splitOn "\n"
  let b := generated.splitOn "\n"
  if a.length != b.length then false
  else
    Id.run do
      let mut ok := true
      for i in [0:a.length] do
        if first15 a[i]! != first15 b[i]! then ok := false
      return ok

def main (args : List String) : IO Unit := do
  let oracleDir : FilePath := args.head?.getD "../oracle/out"
  let frames := runFrames
  if !verifyFrames frames then throw (IO.Error.userError "concrete frame bounds failed")
  let dots := dotsBytes frames
  if dots.size != FRAMES * DOT_BYTES then throw (IO.Error.userError "byte count failed")
  let expectedDots <- IO.FS.readBinFile (oracleDir / "dots.bin")
  if dots != expectedDots then throw (IO.Error.userError "dots.bin differs from oracle")
  let expectedMeta <- IO.FS.readFile (oracleDir / "meta.tsv")
  if !metaMatches15 expectedMeta (metaText frames) then
    throw (IO.Error.userError "meta.tsv first 15 columns differ from oracle")
  let golden <- System.FilePath.isDir (oracleDir / "frames")
  IO.println "dots.bin: byte-exact match (330 x 4096)"
  IO.println "meta.tsv: first 15 columns match"
  if golden then
    IO.println "PNG golden gate: CLOSED (oracle/out/frames present)"
  else
    IO.println "PNG golden gate: OPEN (oracle/out/frames absent; README.md:106)"
