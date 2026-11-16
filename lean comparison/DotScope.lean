-- Deterministic Dot-scope core, translated from oracle/src/rune_hud/dot_scope/scope.rs
-- and v/dotscope.v.  Float32 operations are IEEE binary32 and the transcendental
-- operations are the same C libm entry points V declares at v/dotscope.v:10-20.
-- No Win32 window, ASR shim, models, or Rust app are represented here.


abbrev F := Float32

@[extern "fmodf"] opaque c_fmodf : F → F → F

def fOfNat (n : Nat) : F := (UInt32.ofNat n).toFloat32

def PI : F := 3.14159265358979323846
def TAU : F := 6.28318530717958647692

def STEP : F := (1 : F) / 240
def HISTORY : Nat := 512
def SAMPLES_PER_COLUMN : Nat := 3
def MAX_DOTS : Nat := 1024
def DOT_BYTES : Nat := MAX_DOTS * 4
def FRAMES : Nat := 330
def FRAME_DT : F := (1 : F) / 60

def SPEEDS : Array F := #[(0.8 : F), 1.25, 1.85, 2.6]
def BASE : Array F := #[(0.55 : F), 0.42, 0.3, 0.2]
def SPATIAL : Array F := #[(1.4 : F), 2.4, 3.8, 5.6]

def START_WIDTH : F := 30
def ENTER : F := 0.42
def WIPE : F := 0.3
def PASS_INSET : F := 9
def PHOSPHOR_HEAD : F := 0.15
def BREATH_PERIOD : F := 5.5
def HIDDEN_SCALE : F := 0.9
def HIDDEN_SOFTNESS : F := 3
def WORK_HELIX : F := 2.6
def FLOW_SPACING : F := 0.7
def CARRIER_REST : F := 0.14
def RING_BIRTH : F := 0.15
def BEAM_FADE : F := 0.14
def MAX_F32 : F := Float32.ofBits 0x7f7fffff

@[inline] def fmin (a b : F) : F := if a < b then a else b
@[inline] def fmax (a b : F) : F := if a > b then a else b
@[inline] def fabs (x : F) : F := Float32.abs x
@[inline] def clamp (x lo hi : F) : F :=
  if x < lo then lo else if x > hi then hi else x

def remEuclid (x y : F) : F :=
  let r := c_fmodf x y
  if r < 0 then r + (if y < 0 then -y else y) else r

def smoothstep (a b x : F) : F :=
  let t := clamp ((x - a) / (b - a)) 0 1
  t * t * (3 - 2 * t)

def bump (d w : F) : F := Float32.exp (-(d / w) * (d / w))

def hermite (start speed end_ tIn : F) : F :=
  let t := clamp tIn 0 1
  let t2 := t * t
  let t3 := t * t * t
  (2 * t3 - 3 * t2 + 1) * start
    + (t3 - 2 * t2 + t) * WIPE * speed
    + (3 * t2 - 2 * t3) * end_

def passPosition (p : F) : F := 0.5 - 0.5 * Float32.cos (PI * clamp p 0 1)

def demoLevel (time : F) : F :=
  let phrase := Float32.floor (time / 2.4)
  let t := time - phrase * 2.4
  if t > 1.7 then
    0.04
  else
    let shape := Float32.pow (Float32.sin (PI * t / 1.7)) 0.4
    let rate := TAU * (4.3 + 0.6 * Float32.sin (phrase * 1.7))
    let syllable := 0.5 + 0.5 * Float32.sin (rate * t + phrase)
    let stress := 0.75 + 0.25 * Float32.sin (TAU * 1.1 * t + 2 * phrase)
    clamp (0.08 + 0.82 * shape * Float32.pow syllable 1.6 * stress) 0 1

def demoLoudness (time : F) : F := -58 + 28 * demoLevel time

def fixedLevel (loudness : F) : F := clamp ((loudness + 40) / 30) 0 1

def loudnessOfRms (rms : F) : F := 20 * Float32.log10 (fmax rms 0 + 1e-6)

-- Spring ------------------------------------------------------------------

structure Spec where
  duration : F
  bounce : F

def MORPH : Spec := ⟨0.30, 0.15⟩
def REDUCED_FADE : Spec := ⟨0.16, 0⟩

structure Spring where
  x : F
  v : F
  target : F

def springAt (x : F) : Spring := ⟨x, 0, x⟩

def springStep (s : Spring) (spec : Spec) (dt : F) : Spring :=
  if dt <= 0 then s else
    let omega := TAU / fmax spec.duration 0.01
    let zeta :=
      if spec.bounce >= 0 then fmax (1 - spec.bounce) 0
      else 1 / fmax (1 + spec.bounce) 0.01
    let x0 := s.x - s.target
    let v0 := s.v
    if zeta < 1 - 1e-4 then
      let decay := zeta * omega
      let omegaD := omega * Float32.sqrt (1 - zeta * zeta)
      let ex := Float32.exp (-decay * dt)
      let sv := Float32.sin (omegaD * dt)
      let cv := Float32.cos (omegaD * dt)
      let sod := sv / omegaD
      { s with
        x := s.target + ex * (x0 * (cv + decay * sod) + v0 * sod)
        v := ex * (-x0 * omega * omega * sod + v0 * (cv - decay * sod)) }
    else if zeta > 1 + 1e-4 then
      let root := Float32.sqrt (zeta * zeta - 1)
      let rootSum := zeta + root
      let slowRoot := -omega / rootSum
      let fastRoot := -omega * rootSum
      let denom := slowRoot - fastRoot
      let slowExp := Float32.exp (slowRoot * dt)
      let fastExp := Float32.exp (fastRoot * dt)
      let p00 := (-fastRoot * slowExp + slowRoot * fastExp) / denom
      let p01 := (slowExp - fastExp) / denom
      let p10 := slowRoot * fastRoot * (fastExp - slowExp) / denom
      let p11 := (slowRoot * slowExp - fastRoot * fastExp) / denom
      { s with
        x := s.target + p00 * x0 + p01 * v0
        v := p10 * x0 + p11 * v0 }
    else
      let ex := Float32.exp (-omega * dt)
      let c := v0 + omega * x0
      { s with
        x := s.target + (x0 + c * dt) * ex
        v := (v0 - omega * c * dt) * ex }

def springTo (s : Spring) (target : F) (spec : Spec) (dt : F) : Spring :=
  springStep { s with target := target } spec dt

-- Tuning and stages -------------------------------------------------------

inductive Processing where
  | sweep | flow | pulse
  deriving DecidableEq

structure Tuning where
  columns : F
  rows : F
  spacing : F
  width : F
  processingWidth : F
  height : F
  braidSpeed : F
  helixCycles : F
  gain : F
  response : F
  release : F
  historySpeed : F
  phosphor : F
  glow : F
  saturation : F
  shimmerPass : F
  shimmer : F
  transition : F
  bounce : F
  autoLevel : Bool
  autoRelease : F
  noiseFloor : F
  processing : Processing
  islandSpread : F

def tuningDefault : Tuning :=
  { columns := 43, rows := 9, spacing := 2.6, width := 112,
    processingWidth := 76, height := 26, braidSpeed := 1,
    helixCycles := 1.6, gain := 1, response := 6.5, release := 0.15,
    historySpeed := 150, phosphor := 0.6, glow := 1, saturation := 1,
    shimmerPass := 0.55, shimmer := 1, transition := 0.30, bounce := 0.15,
    autoLevel := true, autoRelease := 3, noiseFloor := -60,
    processing := .flow, islandSpread := 28 }

def tuningClamped (t : Tuning) : Tuning :=
  let rows := Nat.min (MAX_DOTS / t.columns.toUInt32.toNat) 15
  if t.rows.toUInt32.toNat > rows then { t with rows := fOfNat rows } else t

inductive Stage where
  | recording | processing | done | failed
  deriving DecidableEq

structure Frame where
  stage : Stage
  visible : Bool
  loudness : F
  reduceMotion : Bool

structure Pose where
  width : F
  height : F
  opacity : F
  scale : F
  softness : F
  cool : F
  fail : F
  glow : F
  grid : F
  live : F
  reveal : F
  level : F
  clock : F
  done : F
  deriving Inhabited

-- Voice, trace, auto level ------------------------------------------------

structure Voice where
  level : F
  reservoir : F
  energy : F
  kick : F
  kickVelocity : F
  band : F
  deriving Inhabited

def voiceStep (v : Voice) (raw h : F) : Voice :=
  let previous := v.level
  let time := if raw > v.level then 0.035 else 0.095
  let level := v.level + (raw - v.level) * (1 - Float32.exp (-h / time))
  let rise := fmax ((level - previous) / h) 0
  let reservoir := v.reservoir + (1.75 * level * level - v.reservoir / 1.8) * h
  let energy := 1 - Float32.exp (-reservoir * 1.45)
  let w := TAU * 1.3
  let z : F := 0.22
  let kickVelocity :=
    v.kickVelocity
      + (-w * w * v.kick - 2 * z * w * v.kickVelocity + 15 * rise + 2.2 * level) * h
  let kick := v.kick + kickVelocity * h
  let time2 := if raw > v.band then 0.025 else 0.14
  let band := v.band + (raw - v.band) * (1 - Float32.exp (-h / time2))
  { level := level, reservoir := reservoir, energy := energy,
    kick := kick, kickVelocity := kickVelocity, band := band }

structure Trace where
  envelope : F
  amplitude : F
  amplitudeVelocity : F
  glowFast : F
  glowSpring : F
  glowSpringVelocity : F
  glowSlow : F
  glow : F
  phases : Array F
  history : Array F
  head : Nat
  deriving Inhabited

def traceNew (phases : Array F) : Trace :=
  { envelope := 0, amplitude := 0, amplitudeVelocity := 0,
    glowFast := 0, glowSpring := 0, glowSpringVelocity := 0,
    glowSlow := 0, glow := 0, phases := phases,
    history := Array.replicate (HISTORY * 5) 0, head := 0 }

def follow (value target rise fall h : F) : F :=
  let time := if target > value then rise else fall
  value + (target - value) * (1 - Float32.exp (-h / time))

def traceTick (tr : Trace) (v : Voice) (live speed : F) (tuning : Tuning) (h : F) : Trace :=
  Id.run do
    let mut t := tr
    t := { t with envelope := follow t.envelope v.level 0.022 tuning.release h }
    let w := TAU * tuning.response
    let z : F := 0.52
    let av := t.amplitudeVelocity
      + (-w * w * (t.amplitude - t.envelope) - 2 * z * w * t.amplitudeVelocity) * h
    t := { t with amplitudeVelocity := av, amplitude := t.amplitude + av * h }
    t := { t with glowFast := follow t.glowFast v.level 0.045 0.13 h }
    let gw := TAU * 3.6
    let gz : F := 0.5
    let gsv := t.glowSpringVelocity
      + (-gw * gw * (t.glowSpring - t.glowFast) - 2 * gz * gw * t.glowSpringVelocity) * h
    t := { t with glowSpringVelocity := gsv, glowSpring := t.glowSpring + gsv * h }
    t := { t with glowSlow := follow t.glowSlow v.level 0.15 0.7 h }
    let swell := 0.8 * fmax (t.glowSpring - 0.25) 0 + 0.04 * fmax v.kick (-0.5)
    let glow := fmin (fmax swell 0 + 0.42 * t.glowSlow + 0.2 * v.energy) 1.15 * live
    t := { t with glow := glow }
    let span := 0.6 + 1.1 * fmin (t.envelope * 1.6) 1
    let mut phases := t.phases
    for i in [0:4] do
      phases := phases.set! i (c_fmodf (phases[i]! + h * TAU * SPEEDS[i]! * span * speed) TAU)
    t := { t with phases := phases }
    let emphasis := 0.35 + 0.65 * fmin (v.band / (v.band + 0.06)) 2
    let offset := t.head * 5
    let amplitude := fmax t.amplitude 0 * live
    let mut hist := t.history
    hist := hist.set! offset amplitude
    for c in [0:4] do
      hist := hist.set! (offset + 1 + c) (amplitude * BASE[c]! * emphasis)
    t := { t with history := hist, head := (t.head + 1) % HISTORY }
    return t

def tracePast (tr : Trace) (delay : F) (channel : Nat) : F :=
  let d := fmin (delay / STEP) (fOfNat (HISTORY - 2))
  let i := (Float32.floor d).toUInt32.toNat
  let k := d - fOfNat i
  let a := (tr.head + 2 * HISTORY - 1 - i) % HISTORY
  let b := (a + HISTORY - 1) % HISTORY
  tr.history[a * 5 + channel]! * (1 - k) + tr.history[b * 5 + channel]! * k

-- Working light and scan --------------------------------------------------

structure Working where
  kind : Nat -- 0 flow, 1 pulse
  offset : F
  spacing : F
  time : F
  period : F
  speed : F

def workingLight (w : Working) (x halfWidth : F) : F :=
  if w.kind == 0 then
    let d := remEuclid (x - w.offset + w.spacing / 2) w.spacing - w.spacing / 2
    bump d 7
  else
    let d := fabs x
    Id.run do
      let mut light : F := 0
      let mut age := remEuclid w.time w.period
      while age * w.speed < halfWidth + 12 && age <= w.time + 1e-4 do
        let radius := age * w.speed
        let fade := smoothstep 0 RING_BIRTH age
          * (1 - 0.6 * smoothstep (0.3 * halfWidth) halfWidth radius)
        light := light + bump (d - radius) 6 * fade
        age := age + w.period
      return fmin light 1

structure Scan where
  helix : F
  decay : F
  tail : F
  grid : F
  kind : Nat -- 0 enter, 1 process, 2 work, 3 clear
  reach : F
  head : F
  unfold : F
  iron : F
  front : F
  working : Working
  swell : F
  halfWidth : F
  beam : F
  beamAt : F
  field : F
  glow : F

def defaultWorking : Working := ⟨0, 0, 1, 0, 1, 0⟩

def scanAt (s : Scan) (x : F) : F × F × F :=
  match s.kind with
  | 0 =>
      let d := fabs x
      let drawn := s.unfold
        * (1 - smoothstep (fmax (s.reach - 14) 0) (fmax s.reach 0.001) d)
      let amplitude := drawn
        * (1 - smoothstep (fmax (s.reach - 22) 0) (fmax (s.reach - 3) 0.001) d)
      let beam := s.head * bump (d - s.reach) 6
      let swell := 1.8 * s.unfold * (s.head / 2.8) * bump (d - fmax (s.reach - 14) 0) 14
      (amplitude, amplitude + beam, swell)
  | 1 =>
      (s.iron, s.iron + s.head * bump (x - s.front) 5, 0)
  | 2 =>
      let light := workingLight s.working x s.halfWidth
      (1, 1 + s.head * light, s.swell * light)
  | _ =>
      let d := fabs x
      let keep := s.field * smoothstep (s.front - 12) (s.front - 2) d
      let light := workingLight s.working x s.halfWidth
      (keep, keep * (1 + s.glow * light) + s.head * bump (d - s.front) 6
        + s.beam * bump (x - s.beamAt) 5, keep * s.swell * light)

structure AutoLevel where
  peak : F
  room : F

def autoDefault : AutoLevel := ⟨-30, -55⟩

def autoLevelOf (a : AutoLevel) (loudness noiseFloor : F) : F :=
  let low := fmax (fmax a.room noiseFloor + 5) (a.peak - 24)
  clamp ((loudness - low) / fmax (a.peak - low) 1) 0 1

def autoStep (a : AutoLevel) (loudness h release noiseFloor : F) : F × AutoLevel :=
  let db := fmax loudness (-120)
  let roomTime := if db < a.room then 0.3 else 6
  let room := a.room + (db - a.room) * (1 - Float32.exp (-h / fmax roomTime 1e-3))
  let lowest := fmax room noiseFloor + 16
  let peak :=
    if db > a.peak then
      a.peak + (db - a.peak) * (1 - Float32.exp (-h / fmax 0.04 1e-3))
    else
      a.peak + (lowest - a.peak) * (1 - Float32.exp (-h / fmax release 1e-3))
  let peak := fmax peak lowest
  let a' : AutoLevel := ⟨peak, room⟩
  (autoLevelOf a' db noiseFloor, a')

-- Scope -------------------------------------------------------------------

structure Scope where
  tuning : Tuning
  stage : Stage
  elapsed : F
  speedAtDone : F
  doneFrom : F
  flowOffset : F
  flowTurn : F
  auto : AutoLevel
  level : F
  voices : Array Voice
  traces : Array Trace
  live : F
  carrier : F
  time : F
  steps : Nat
  pending : F
  reduceMotion : Bool
  columns : Nat
  rows : Nat
  head : Array (Array F)
  tail : Array (Array F)
  dots : Array F
  ys : Array (Array F)
  brightness : Array (Array F)
  grid : F
  width : Spring
  opacity : Spring
  scale : Spring
  softness : Spring
  cool : Spring
  fail : Spring

def scopePose (s : Scope) : Pose :=
  let glow := (s.traces[0]!.glow + s.traces[1]!.glow) / 2 * s.tuning.glow
  { width := fmax s.width.x s.tuning.height
    height := s.tuning.height
    opacity := clamp s.opacity.x 0 1
    scale := fmax s.scale.x 0.01
    softness := clamp s.softness.x 0 HIDDEN_SOFTNESS
    cool := clamp s.cool.x 0 1
    fail := clamp s.fail.x 0 1
    glow := glow
    grid := s.grid
    live := s.live
    reveal := fmax ((s.scale.x - HIDDEN_SCALE) / (1 - HIDDEN_SCALE)) 0
    level := clamp s.voices[0]!.level 0 1
    clock := if s.reduceMotion then 0 else s.time
    done := if s.stage == .done then 1 else 0 }

def scopeSettled (s : Scope) : Bool :=
  s.opacity.target == 0 && s.opacity.x < 0.002

def scopeNew (tuning : Tuning) : Scope :=
  let t := tuningClamped tuning
  let columns := t.columns.toUInt32.toNat
  let rows := t.rows.toUInt32.toNat
  let dots := columns * rows
  let samples := (columns - 1) * SAMPLES_PER_COLUMN + 1
  { tuning := t
    stage := .recording
    elapsed := 0
    speedAtDone := 0
    doneFrom := 0
    flowOffset := 0
    flowTurn := 0
    auto := autoDefault
    level := 0
    voices := #[⟨0, 0, 0, 0, 0, 0⟩, ⟨0, 0, 0, 0, 0, 0⟩]
    traces := #[
      traceNew #[(0.1 : F), 1.7, 3.3, 4.6],
      traceNew #[(2.4 : F), 0.6, 5.1, 1.9]]
    live := 0
    carrier := 0
    time := 0
    steps := 0
    pending := 0
    reduceMotion := false
    columns := columns
    rows := rows
    head := #[Array.replicate dots 0, Array.replicate dots 0]
    tail := #[Array.replicate dots 0, Array.replicate dots 0]
    dots := Array.replicate (dots * 2) 0
    ys := #[Array.replicate samples 0, Array.replicate samples 0]
    brightness := #[Array.replicate samples 0, Array.replicate samples 0]
    grid := 0
    width := springAt START_WIDTH
    opacity := springAt 0
    scale := springAt HIDDEN_SCALE
    softness := springAt HIDDEN_SOFTNESS
    cool := springAt 0
    fail := springAt 0 }

def workPeriod (s : Scope) : F := 2 * fmax s.tuning.shimmerPass 0.05
def flowSpacing (s : Scope) : F := FLOW_SPACING * s.tuning.processingWidth
def flowSpeed (s : Scope) : F := flowSpacing s / workPeriod s
def flowTurnHz (s : Scope) : F := flowSpeed s * s.tuning.helixCycles / fmax s.width.x 1
def pulseSpeed (s : Scope) : F := (s.tuning.processingWidth / 2 + 12) / (1.4 * workPeriod s)

def scopeWorking (s : Scope) (time : F) : Working :=
  if s.tuning.processing == .pulse then
    ⟨1, 0, 0, time, workPeriod s, pulseSpeed s⟩
  else
    ⟨0, s.flowOffset, flowSpacing s, 0, 0, 0⟩

def armDone (s : Scope) : Scope :=
  { s with
    speedAtDone := 1.5 * pulseSpeed s
    doneFrom := if s.stage == .processing then s.elapsed else 0 }

def processHead (s : Scope) (elapsed : F) : F :=
  let pass := fmax s.tuning.shimmerPass 0.05
  (2.2 + fabs (Float32.sin (PI * (elapsed / pass + 0.5))))
    * smoothstep 0 0.14 elapsed * s.tuning.shimmer

def processFront (s : Scope) (elapsed width : F) : F :=
  let pass := fmax s.tuning.shimmerPass 0.05
  let position := 0.5 - 0.5 * Float32.cos (PI * (elapsed / pass + 0.5))
  (-width) / 2 + PASS_INSET + (width - 2 * PASS_INSET) * position

def scopeScan (s : Scope) (width : F) : Scan :=
  let e := s.elapsed
  let still : Scan :=
    { helix := 1, decay := 1, tail := 1, grid := 1, kind := 0,
      reach := 1e4, head := 0, unfold := 1, iron := 0, front := 0,
      working := defaultWorking, swell := 0, halfWidth := 0,
      beam := 0, beamAt := 0, field := 0, glow := 0 }
  if s.stage == .failed || s.reduceMotion then still
  else if s.stage == .recording then
    { still with
      grid := fmin (e / 0.3) 1
      reach := (width / 2 + 12) * passPosition (e / ENTER)
      head := 2.8 * (1 - smoothstep 0.08 ENTER e)
      unfold := smoothstep 0 0.1 e }
  else if s.stage == .processing && s.tuning.processing != .sweep then
    let enter := smoothstep 0 0.35 e
    { still with
      kind := 2
      helix := 1 + (WORK_HELIX - 1) * enter
      working := scopeWorking s e
      head := 2.5 * smoothstep 0.05 0.3 e * s.tuning.shimmer
      swell := 0.9 * enter
      halfWidth := width / 2 }
  else if s.stage == .done then
    let target := width / 2 + 8
    let front := hermite 0 s.speedAtDone target (e / WIPE)
    let sweep := s.tuning.processing == .sweep
    { still with
      kind := 3
      helix := if sweep then 0 else WORK_HELIX
      decay := 1 - 0.6 * smoothstep 0 0.12 e
      tail := 1 - smoothstep 0 0.15 e
      grid := 1 - smoothstep 0.2 0.4 e
      front := front
      head := 2.8 * smoothstep 0 0.04 e * (1 - smoothstep 0.22 0.32 e)
      beam := if sweep && s.doneFrom > 0 then
          processHead s (s.doneFrom + e) * (1 - smoothstep 0 BEAM_FADE e)
        else 0
      beamAt := processFront s (s.doneFrom + e) width
      field := if sweep then 0 else 1
      working := scopeWorking s (s.doneFrom + e)
      glow := (if sweep then 0 else 2.5) * s.tuning.shimmer
        * (1 - smoothstep 0 0.18 e)
      swell := 0.9
      halfWidth := width / 2 }
  else
    let iron := 1 - smoothstep 0 0.28 e
    { still with
      kind := 1
      helix := iron
      iron := iron
      front := processFront s e width
      head := processHead s e }

-- One dot's phosphor contribution from trace k.
def dotPass (s : Scope) (_k i j s0 s1 : Nat) (scan : Scan)
    (headKeep tailKeep dx : F) (heads tails ys bright : Array F) :
    F × F × F × F :=
  Id.run do
    let n := j * s.columns + i
    let mut best : F := MAX_F32
    let mut nearest := i * SAMPLES_PER_COLUMN
    for si in [s0:s1] do
      let ay := ys[si]!
      let dy := ys[si + 1]! - ay
      let px := fOfNat i - fOfNat si * dx
      let py := fOfNat j - ay
      let t := clamp ((px * dx + py * dy) / (dx * dx + dy * dy)) 0 1
      let ex := px - t * dx
      let ey := py - t * dy
      let d2 := ex * ex + ey * ey
      if d2 < best then
        best := d2
        nearest := si
    let b := bright[nearest]!
    let onBeam := Float32.exp (-best / 0.25)
    let instant := fmin (onBeam + 0.5 * Float32.exp (-Float32.sqrt best / 0.8)) 1.2 * b
    let core := onBeam * b
    let hNew := fmax (heads[n]! * headKeep) core
    let tNew := fmax (tails[n]! * tailKeep) core
    let light := fmax (fmax instant hNew) (0.55 * scan.tail * tNew)
    return (hNew, tNew, light, instant)

def scopeBeam (s : Scope) (hb : F) : Scope :=
  Id.run do
    let mut sc := s
    let columns := sc.columns
    let rows := sc.rows
    let sub := SAMPLES_PER_COLUMN
    let samples := (columns - 1) * sub + 1
    let pitch := sc.tuning.spacing
    let width := fmax sc.width.x sc.tuning.height
    let scan := scopeScan sc width
    sc := { sc with grid := scan.grid }
    let mid := (fOfNat rows - 1) / 2
    let half := mid - 0.55
    let breath := if sc.reduceMotion then 0.5
      else 0.5 + 0.5 * Float32.sin (sc.time * TAU / BREATH_PERIOD)
    let rest := (0.55 + 0.35 * breath) * (0.4 + 0.6 * sc.live) * scan.helix
    let halfWidth := width / 2
    let mut ysAll := sc.ys
    let mut brightAll := sc.brightness
    for k in [0:2] do
      let tr := sc.traces[k]!
      let sign : F := if k == 0 then 1 else -1
      let mut ys := ysAll[k]!
      let mut bright := brightAll[k]!
      for si in [0:samples] do
        let x := (fOfNat si / fOfNat sub - (fOfNat columns - 1) / 2) * pitch
        if fabs x > halfWidth then
          ys := ys.set! si mid
          bright := bright.set! si 0
        else
          let (amplitude, lite, swell) := scanAt scan x
          let own := fabs x
          let xn := (x + halfWidth) / width
          let ends := fmin (smoothstep (-halfWidth + 3) (-halfWidth + 17) x)
            (smoothstep (-halfWidth + 3) (-halfWidth + 17) (-x))
          let reach := 1 - 0.8 * smoothstep 14 halfWidth own
          let delay := own / sc.tuning.historySpeed
          let a := tracePast tr delay 0
          let mut spread : F := 0
          for c in [0:4] do
            spread := spread
              + tracePast tr delay (1 + c)
                * Float32.sin (TAU * SPATIAL[c]! * xn - tr.phases[c]!)
          let helix := (rest + swell + half * 0.55 * a * reach)
            * Float32.sin (TAU * sc.tuning.helixCycles * xn - sc.carrier)
          let y := half * Float32.tanh ((helix + half * 0.7 * spread * reach) / half)
            * ends * amplitude
          ys := ys.set! si (mid - sign * y)
          let spatial := (0.3 + 0.7 * fmin (a * 1.8) 1) * (0.45 + 0.55 * ends)
          bright := bright.set! si (spatial * amplitude + 0.36 * fmax (lite - amplitude) 0)
      for si in [0:samples] do
        let prev := if si == 0 then ys[0]! else ys[si - 1]!
        let ni := if si + 1 > samples - 1 then samples - 1 else si + 1
        let slope := (ys[ni]! - prev) * fOfNat sub / 2
        let b := bright[si]! * (1 - 0.55 + 0.55 / Float32.sqrt (1 + 0.22 * slope * slope))
        bright := bright.set! si b
      ysAll := ysAll.set! k ys
      brightAll := brightAll.set! k bright
    sc := { sc with ys := ysAll, brightness := brightAll }
    let headKeep := Float32.exp (-hb / (PHOSPHOR_HEAD * scan.decay))
    let tailKeep := Float32.exp (-hb / (sc.tuning.phosphor * scan.decay))
    let dx : F := 1 / fOfNat sub
    let mut headsAll := sc.head
    let mut tailsAll := sc.tail
    let mut dots := sc.dots
    for i in [0:columns] do
      let s0 := (if i > 3 then i - 3 else 0) * sub
      let s1 := Nat.min ((i + 3) * sub) (samples - 1)
      for j in [0:rows] do
        let n := j * columns + i
        let mut now : F := 0
        let mut total : F := 0
        let mut lit0 : F := 0
        let mut lit1 : F := 0
        for k in [0:2] do
          let heads := headsAll[k]!
          let tails := tailsAll[k]!
          let ys := ysAll[k]!
          let bright := brightAll[k]!
          let (hNew, tNew, light, instant) :=
            dotPass sc k i j s0 s1 scan headKeep tailKeep dx heads tails ys bright
          headsAll := headsAll.set! k (heads.set! n hNew)
          tailsAll := tailsAll.set! k (tails.set! n tNew)
          if k == 0 then lit0 := light else lit1 := light
          now := now + instant
          total := total + light
        let power := 1 - (1 - fmin lit0 1) * (1 - fmin lit1 1)
        let fresh := fmin (now / fmax total 1e-4) 1
        dots := dots.set! (2 * n) (clamp power 0 1)
        dots := dots.set! (2 * n + 1) fresh
    sc := { sc with head := headsAll, tail := tailsAll, dots := dots }
    return sc

def scopeStep (s : Scope) (frame : Frame) : Scope :=
  Id.run do
    let mut sc := s
    let h := STEP
    let tuning := sc.tuning
    let recording := sc.stage == .recording && frame.visible
    let mut level : F := 0
    if recording then
      let (lvl, auto') := if tuning.autoLevel then
          autoStep sc.auto frame.loudness h tuning.autoRelease tuning.noiseFloor
        else (fixedLevel frame.loudness, sc.auto)
      sc := { sc with auto := auto', level := lvl }
      level := clamp (lvl * tuning.gain) 0 1
    else
      sc := { sc with level := 0 }
    let voices := sc.voices
    let v0 := voiceStep voices[0]! level h
    let v1 := voiceStep voices[1]! (level * 0.85) h
    let voices' := (voices.set! 0 v0).set! 1 v1
    sc := { sc with voices := voices' }
    let liveTarget : F := if recording then 1 else 0
    let live := sc.live + (liveTarget - sc.live) * (1 - Float32.exp (-h / 0.55))
    sc := { sc with live := live }
    let speed : F := if frame.reduceMotion then 0 else tuning.braidSpeed
    let mut traces := sc.traces
    for k in [0:2] do
      traces := traces.set! k (traceTick traces[k]! sc.voices[k]! live speed tuning h)
    sc := { sc with traces := traces }
    let energy := fmax sc.voices[0]!.energy sc.voices[1]!.energy
    let working := sc.stage == .processing || sc.stage == .done
    let flowing := working && tuning.processing == .flow
    let flowTarget : F := if flowing then 1 else 0
    let flowTurn := sc.flowTurn + (flowTarget - sc.flowTurn) * (1 - Float32.exp (-h / 0.25))
    sc := { sc with flowTurn := flowTurn }
    if working then
      sc := { sc with flowOffset := sc.flowOffset + flowSpeed sc * h }
    let rest := CARRIER_REST + 0.22 * energy
    let turn := rest + (flowTurnHz sc - rest) * sc.flowTurn
    sc := { sc with carrier := c_fmodf (sc.carrier + h * TAU * turn * speed) TAU }
    let width := match sc.stage with
      | .recording => tuning.width
      | .processing | .done => tuning.processingWidth
      | .failed => sc.width.target
    let coolTarget : F := if sc.stage == .processing || sc.stage == .done then 1 else 0
    let failTarget : F := if sc.stage == .failed then 1 else 0
    let shown : F := if frame.visible then 1 else 0
    let fade := Spec.mk tuning.transition 0
    let bouncy := Spec.mk tuning.transition tuning.bounce
    if frame.reduceMotion then
      sc := { sc with width := { (springAt width) with target := width }
                      scale := springAt 1
                      softness := springAt 0
                      opacity := springTo sc.opacity shown REDUCED_FADE h
                      cool := springTo sc.cool coolTarget REDUCED_FADE h
                      fail := springTo sc.fail failTarget REDUCED_FADE h }
    else
      sc := { sc with width := springTo sc.width width bouncy h
                      opacity := springTo sc.opacity shown fade h
                      scale := springTo sc.scale (if frame.visible then 1 else HIDDEN_SCALE) bouncy h
                      softness := springTo sc.softness (if frame.visible then 0 else HIDDEN_SOFTNESS) fade h
                      cool := springTo sc.cool coolTarget fade h
                      fail := springTo sc.fail failTarget fade h }
    sc := { sc with elapsed := sc.elapsed + h, time := sc.time + h, steps := sc.steps + 1 }
    if sc.steps % 2 == 0 then
      sc := scopeBeam sc (2 * h)
    return sc

def scopeAdvance (s : Scope) (dt : F) (frame : Frame) : Scope :=
  Id.run do
    let mut sc := s
    if frame.stage != sc.stage then
      if frame.stage == .done then sc := armDone sc
      if frame.stage == .processing then
        sc := { sc with flowOffset := -sc.width.x / 2 - 4 }
      sc := { sc with stage := frame.stage, elapsed := 0 }
    sc := { sc with reduceMotion := frame.reduceMotion }
    sc := { sc with pending := sc.pending + clamp dt 0 0.25 }
    while sc.pending >= STEP do
      sc := { sc with pending := sc.pending - STEP }
      sc := scopeStep sc frame
    return sc

def packU16 (v : F) : UInt16 := (Float32.round (clamp v 0 1 * 65535)).toUInt16
