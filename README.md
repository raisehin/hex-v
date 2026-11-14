# hex-v — the Dot scope speaking indicator, outside the Rust app

Small program that reproduces hex 3.4.0's speaking indicator (Dot scope) on
Windows, written in V. It builds from this repository alone; `oracle/` and
`v/out/` are provenance/reference data, not compile inputs.

```
oracle/     Rust: hex 3.4.0's own simulation sources, compiled standalone,
            emits the reference u16 dot buffer. Not part of the product.
v/          the program (V): simulation, CPU raster, layered window.
```

## Build

Requirements: Windows x64, V 0.5.2 `f9ebca4`, and `gcc` on `PATH`. No model,
native shim, oracle checkout or generated frame data is needed to compile.

```powershell
.\build-github.ps1
.\v\bin\hexv.exe probe
```

`build-github.ps1` resolves the repository from `$PSScriptRoot` and finds V from
`-V`, `$env:V`, then `v` on `PATH`. If none is present it fetches the pinned
V 0.5.2 source (`f9ebca4`), builds V's own bootstrap snapshot with gcc, and
uses that to compile the pinned compiler before building the app. It runs:

```powershell
v -prod -cc gcc -cflags "-ffp-contract=off" -o v/bin/hexv.exe v
```

`SOURCE_DATE_EPOCH=0` is set for the linker so two clean builds produce the same
`hexv.exe` SHA-256. The optional `build.ps1` is the maintainer's local-only
script and is ignored by git.

The ASR shim is **runtime-only**. Compiling `hexv.exe` never needs
`transcribe_shim.dll`; at run time it is resolved from `HEX_SHIM`, the
executable directory, a `bin\` below it, or the DLL search path.

## Reference app provenance

`C:\Users\rhais\Documents\hex-3.4.0` is not a git repository. Its only
provenance is `rune-motion` in `Cargo.toml:125`:

```
rune-motion = { git = "https://github.com/anomalyco/rune.git", rev = "ba5e7c8069a24c36f95ca90a3058083cd468fcd1" }
```

(the sources here refer to that rev as `ba5e7c8`).

Build flags for the V program (gcc must not contract mul+add, because Rust does
not, and the dot byte gate depends on it):

```
-cc gcc -cflags -ffp-contract=off
```

## The oracle

`oracle/src` contains **verbatim copies** of

| file | from |
|---|---|
| `rune_hud/dot_scope.rs` | `src/rune_hud/dot_scope.rs` |
| `rune_hud/dot_scope/scope.rs` | `src/rune_hud/dot_scope/scope.rs` |
| `rune_hud/spring.rs` | `src/rune_hud/spring.rs` |
| `rune_hud/hud_placement.rs` | `src/rune_hud/hud_placement.rs` |
| `dictation/indicator.rs` | `src/dictation/indicator.rs` |

The only additions are shims for four app-only items the copied files touch:
`app_paths::support_dir`, `durable::write`, `app_settings::IndicatorPosition`,
`macos_rune::wake_pump`, plus a 20-line `color-eyre` stub (`Result<T>`) because
0.6.5 is not in the local cargo cache and there is no network here.

`src/main.rs` replicates `src/rune_hud/tests.rs:50-77` exactly: a 330-frame
schedule at 1/60 s, `demo_loudness(t)` as the meter for the first 3 s, then
`Submitted { job_id: 1 }` at 3.0, `Processing { job_id: 1 }` at 3.6,
`JobCompleted { job_id: 1 }` at 4.4, `step(now, 1.0/60.0, false)` per frame.

Build and run (offline, 16 s, no network):

```
cd oracle && cargo build --offline --release
./target/release/hex-v-oracle.exe out
```

### Why not `cargo test --bin hex rune_hud_frames`

That is the real command and it cannot run on this machine:

- there is no network (`github.com` and `static.crates.io` are unreachable);
- `Cargo.toml` patches `transcribe-cpp` to `anomalyco/transcribe.cpp@bcb639f`,
  which is **not** in `~/.cargo/git` (only `7045d1c` is, and that revision is a
  single `transcribe-cpp-sys` package, so it cannot satisfy `transcribe-cpp`).

So the hex binary cannot be built here at all. The simulation can: those five
files depend only on each other, `serde` and `std`. Copying them compiles the
same arithmetic, so `dots.bin` is the same bytes the real test would write.

What is still missing as a consequence: the **PNG golden frames** (gate (b)),
which need wgpu and therefore the whole app. Unblock: one machine with network,
`cargo test --bin hex rune_hud_frames`, then copy the `NNNN.png` files here.

## `oracle/out/dots.bin`

330 frames × 4096 bytes = 1,351,680 bytes,
sha256 `a8d6f7c484fc376dbb18c113782e74ec…`

Per frame, `rune_hud.rs:824 packed_dots` layout: up to `MAX_DOTS` (1024) dots,
row by row, each one little-endian `u16 power, u16 fresh`, zero-padded to
4096 bytes. `power` and `fresh` are
`(v.clamp(0.0, 1.0) * 65535.0).round() as u16` (`indicator.rs:452`).

Default tuning gives `columns = 43`, `rows = 9` — the same field the Odin HUD
draws.

Sanity samples: frame 90 has all 387 dots lit with `fresh = 65535` (mid
recording, braid travelling); frame 0 has 117 fading in; frame 329 has 26
fading out.

## `oracle/out/meta.tsv`

One row per frame: `frame, t, columns, rows` then the `Pose` fields
(`width, height, opacity, scale, softness, cool, glow, grid, live, done,
reveal, fail`). These are the plate terms the rasteriser needs.

## Real dictation host

`hexv` uses an existing `transcribe_shim.dll` at runtime through V's `dl`
module. The DLL is not part of the compile and is not tracked here. It is
resolved from `HEX_SHIM`, the executable directory, a `bin\` below it, or the
DLL search path. It does not copy the model or reimplement ASR.

- default mic via Win32 `waveIn`, downmixed/resampled to mono 16 kHz f32;
- Dot scope loudness comes from the real RMS;
- **Ctrl+Space** starts/stops a dictation, **Esc** cancels (or quits when idle);
- on stop the shim runs off-thread, the existing processing/done stages paint,
  then the transcript is pasted with clipboard save/restore;
- the last recording is saved to `%APPDATA%\hex\hexv-last.wav`;
- model load and inference timings are in `%APPDATA%\hex\logs\hexv.log`;
- the model is released after 180 s idle (`HEX_MODEL_IDLE_SECS` overrides).

Uses `%APPDATA%\hex\odin-config` (`model`, `language`, `threads`) and
`%APPDATA%\hex\models\phonon-2.5-en-Q8_0.gguf` plus the Silero VAD model.

## Commands

```powershell
.\build-github.ps1

.\v\bin\hexv.exe            # real dictation HUD (Ctrl+Space / Esc)
.\v\bin\hexv.exe transcribe <file.wav> [model] [language]
.\v\bin\hexv.exe record <seconds> <file.wav>
.\v\bin\hexv.exe paste-file <file.wav>
.\v\bin\hexv.exe replay v/out
.\v\bin\hexv.exe render v/out
.\v\bin\hexv.exe probe      # real WM_TIMER spacing for SetTimer(42)
.\v\bin\hexv.exe paint-probe
```
