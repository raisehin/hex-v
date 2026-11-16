-- The 330-frame deterministic schedule from oracle/src/main.rs:17-42 and
-- v/indicator.v:204-250.  Only the Dot-scope core is replayed.

import DotScope

open System

inductive Phase where
  | hidden | recording | transcribing | completed | cancelled | failed
  deriving DecidableEq

structure Model where
  phase : Phase
  capturing : Bool
  pendingJobs : Nat
  phaseStarted : Float
  workingSince : Float
  completionPending : Bool
  scope : Scope
  stage : Stage
  tuning : Tuning
  loudness : F

structure DotFrame where
  pose : Pose
  columns : Nat
  rows : Nat
  dots : Array UInt16 -- 2048 little-endian u16 words: power, fresh, then zeros
  deriving Inhabited

def modelNew (tuning : Tuning) : Model :=
  { phase := .hidden, capturing := false, pendingJobs := 0,
    phaseStarted := 0, workingSince := 0, completionPending := false,
    scope := scopeNew tuning, stage := .recording, tuning := tuning,
    loudness := -120 }

def phaseStage (p : Phase) : Option Stage :=
  match p with
  | .recording => some .recording
  | .transcribing => some .processing
  | .completed => some .done
  | .failed => some .failed
  | .hidden | .cancelled => none

def phaseVisibleDuration (p : Phase) : Float :=
  match p with
  | .completed => 0.100
  | .cancelled => 0.0
  | .failed => 1.2
  | _ => -1.0

def showPipeline (m : Model) (now : Float) : Model :=
  if m.capturing then
    if m.phase != .recording then
      { m with phase := .recording, phaseStarted := now }
    else m
  else if m.pendingJobs > 0 then
    let working := if m.phase != .transcribing then now else m.workingSince
    { m with phase := .transcribing, phaseStarted := now, workingSince := working, completionPending := false }
  else m

def onStarted (m : Model) (now : Float) : Model :=
  let auto := m.scope.auto
  let sc := scopeNew m.tuning
  { m with capturing := true, pendingJobs := 0, phase := .recording, phaseStarted := now, completionPending := false, loudness := -120, stage := .recording, scope := { sc with auto := auto } }

def onSubmitted (m : Model) (now : Float) : Model :=
  showPipeline { m with capturing := false, pendingJobs := 1 } now

def onProcessing (m : Model) (now : Float) : Model :=
  showPipeline m now

def onCompleted (m : Model) (now : Float) : Model :=
  if m.pendingJobs == 0 then m
  else
    let m := { m with pendingJobs := 0 }
    if m.capturing then showPipeline m now
    else
      let m := if m.phase != .transcribing then
          { m with phase := .transcribing, workingSince := now }
        else m
      { m with completionPending := true }

def clampDt (dt : F) : F := clamp dt (1 / 240) (1 / 20)

def dotFrameOf (s : Scope) : DotFrame := Id.run do
  let mut words : Array UInt16 := Array.replicate (MAX_DOTS * 2) 0
  for n in [0:s.dots.size / 2] do
    words := words.set! (2 * n) (packU16 s.dots[2 * n]!)
    words := words.set! (2 * n + 1) (packU16 s.dots[2 * n + 1]!)
  return { pose := scopePose s, columns := s.columns, rows := s.rows, dots := words }

def modelStep (m : Model) (now : Float) (dt0 : F) (reduce : Bool) : Model × DotFrame :=
  Id.run do
    let mut mm := m
    let dt := clampDt dt0
    if mm.completionPending && now - mm.workingSince >= 0.200 then
      mm := { mm with phase := .completed, phaseStarted := now, completionPending := false }
    let elapsed := now - mm.phaseStarted
    let vd := phaseVisibleDuration mm.phase
    let terminalFinished := vd >= 0 && elapsed >= vd
    let visible := mm.phase != .hidden && !terminalFinished
    match phaseStage mm.phase with
    | some st => mm := { mm with stage := st }
    | none => pure ()
    let scope := scopeAdvance mm.scope dt
      { stage := mm.stage, visible := visible, loudness := mm.loudness,
        reduceMotion := reduce }
    mm := { mm with scope := scope }
    return (mm, dotFrameOf scope)

def runFrames : Array DotFrame :=
  Id.run do
    let mut m := modelNew tuningDefault
    let mut out : Array DotFrame := #[]
    for n in [0:FRAMES] do
      let t : F := fOfNat n / 60
      let now : Float := t.toFloat
      if n == 0 then m := onStarted m now
      if n == 180 then m := onSubmitted m now
      if n == 216 then m := onProcessing m now
      if n == 264 then m := onCompleted m now
      if t < 3 then
        let rms := Float32.pow 10 (demoLoudness t / 20)
        m := { m with loudness := loudnessOfRms rms }
      let (m', f) := modelStep m now FRAME_DT false
      m := m'
      out := out.push f
    return out

def zeros (n : Nat) : String := String.ofList (List.replicate n '0')

def fixed6 (x : F) : String :=
  let scaled := x.toFloat * 1000000.0 + 0.5
  let n := (Float.floor scaled).toUInt64.toNat
  let whole := n / 1000000
  let frac := n % 1000000
  let fs := toString frac
  s!"{whole}.{zeros (6 - fs.length)}{fs}"

def metaHeader : String :=
  "frame\tt\tcolumns\trows\twidth\theight\topacity\tscale\tsoftness\tcool\tglow\tgrid\tlive\tdone\treveal\n"

def metaLine (n : Nat) (f : DotFrame) : String :=
  let p := f.pose
  s!"{n}\t{fixed6 (fOfNat n / 60)}\t{f.columns}\t{f.rows}\t{fixed6 p.width}\t{fixed6 p.height}\t{fixed6 p.opacity}\t{fixed6 p.scale}\t{fixed6 p.softness}\t{fixed6 p.cool}\t{fixed6 p.glow}\t{fixed6 p.grid}\t{fixed6 p.live}\t{fixed6 p.done}\t{fixed6 p.reveal}\n"

def dotsBytes (frames : Array DotFrame) : ByteArray :=
  Id.run do
    let mut out := ByteArray.empty
    for f in frames do
      for i in [0:f.dots.size] do
        let v := f.dots[i]!.toNat
        out := out.push (UInt8.ofNat (v % 256))
        out := out.push (UInt8.ofNat (v / 256))
    return out

def metaText (frames : Array DotFrame) : String :=
  Id.run do
    let mut s := metaHeader
    for n in [0:frames.size] do
      s := s ++ metaLine n frames[n]!
    return s

-- Runtime assertions over every replayed frame.  These are concrete bounds,
-- not a claim about all possible tunings.
def frameOk (f : DotFrame) : Bool :=
  f.columns == 43 && f.rows == 9
    && f.dots.size == MAX_DOTS * 2
    && f.pose.width >= f.pose.height
    && f.pose.opacity >= 0 && f.pose.opacity <= 1
    && f.pose.scale >= 0.01
    && f.pose.softness >= 0 && f.pose.softness <= 3
    && f.pose.cool >= 0 && f.pose.cool <= 1
    && f.pose.fail >= 0 && f.pose.fail <= 1
    && (f.pose.done == 0 || f.pose.done == 1)
    && f.pose.reveal >= 0

def verifyFrames (frames : Array DotFrame) : Bool :=
  frames.size == FRAMES
    && (Id.run do
          let mut ok := true
          for f in frames do
            if !frameOk f then ok := false
          return ok)

def writeReplay (dir : FilePath) : IO Unit := do
  IO.FS.createDirAll dir
  let frames := runFrames
  if !verifyFrames frames then throw (IO.Error.userError "frame verification failed")
  IO.FS.writeBinFile (dir / "dots.bin") (dotsBytes frames)
  IO.FS.writeFile (dir / "meta.tsv") (metaText frames)
  IO.println s!"frames={frames.size} dot_bytes_per_frame={DOT_BYTES} total={(dotsBytes frames).size}"
