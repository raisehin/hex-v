-- Kernel-checked concrete properties that do not depend on the libm FFI.
-- Run with `lake build tests && ./.lake/build/bin/tests`.
import Replay

example : HISTORY = 512 := rfl
example : MAX_DOTS = 1024 := rfl
example : DOT_BYTES = 4096 := by decide
example : FRAMES = 330 := rfl
example : FRAMES * DOT_BYTES = 1351680 := by decide
example : FRAME_DT = 4 * STEP := by native_decide

-- Pose columns and dot count of the default tuning.
example : (scopeNew tuningDefault).columns = 43 := by native_decide
example : (scopeNew tuningDefault).rows = 9 := by native_decide
example : (scopeNew tuningDefault).dots.size = 43 * 9 * 2 := by native_decide

-- u16 [power, fresh] packing endpoints and range.
example : packU16 0 = 0 := by native_decide
example : packU16 1 = 65535 := by native_decide
example : (packU16 0.5).toNat <= 65535 := by native_decide

def main : IO Unit := IO.println "all kernel-checked examples passed"
