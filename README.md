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

`SOURCE_DATE_EPOCH=0` is set for the linker so two clean builds of the same
source produce the same `hexv.exe` SHA-256. Checked on 2026-11-15 by building
two separate `git worktree add --detach` checkouts with `build-github.ps1`
(V 0.5.2 `f9ebca4`, gcc 15.2.0): both were byte-identical. It is a
same-source, same-toolchain claim, not a promise about every compiler. The
optional `build.ps1` is the maintainer's local-only script and is ignored by
git.

The ASR shim is **runtime-only**. Compiling `hexv.exe` never needs
`transcribe_shim.dll`, and `v/bin/` is git-ignored, so a clean checkout has to
supply it: put it beside the exe (`v/bin/transcribe_shim.dll`) or point
`HEX_SHIM` at it. Those are the two layouts that work; the resolution order in
[Real dictation host](#real-dictation-host) has no search path.

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
resolved from `HEX_SHIM` if set, otherwise from beside the executable,
otherwise from a `bin\` below it; failing all of those it uses the bare name
`transcribe_shim.dll`, which the OS resolves against the working directory.
There is no PATH-style search, so a build is only self-contained if the DLL
sits next to the exe. It does not copy the model or reimplement ASR.

- default mic via Win32 `waveIn`, downmixed/resampled to mono 16 kHz f32;
- Dot scope loudness comes from the real RMS;
- **Ctrl+Space** starts/stops a dictation; **Esc** cancels while recording or
  transcribing and does nothing when idle; **Ctrl+Alt+Q** quits;
- the shim runs *during* the take: a segment worker polls every 250 ms
  (`host.v:14`) and closes a segment on 500 ms of silence or a forced cut at
  6 s of unsegmented audio (`host.v:15`, `:22`), keeping each segment's text;
- on stop only the remainder is transcribed off-thread, then the joined
  transcript is pasted with clipboard save/restore;
- the last recording is saved to `%APPDATA%\hex\hexv-last.wav`;
- model load and inference timings are in `%APPDATA%\hex\logs\hexv.log`;
- the model is released after 180 s idle (`HEX_MODEL_IDLE_SECS` overrides).

`%APPDATA%\hex\odin-config`, read at startup:

| key | effect |
|---|---|
| `model` | `phonon25_en` or omitted. Anything else is a **config error**: the id, the supported id and the fact are printed and logged, and the process exits 1 without opening a HUD. |
| `language` | passed to the shim; `en` if empty. |
| `threads` | `0` means `n - n/4` — 6 on this 8-thread CPU; a positive value is used as given. |
| `paste_keys` | `ctrl_v` (default), `ctrl_shift_v`, `shift_insert` or `type`. |
| `engine` | ignored. hex-v has one engine, the shim, so `engine=auto` selects nothing. |

Models are read from `%APPDATA%\hex\models`: `phonon-2.5-en-Q8_0.gguf` — the
only one hex-v will load — plus `silero-vad-v6.2-F32.gguf`.

## Latency

One measured take: `%APPDATA%\hex\logs\hexv.log`, 2026-11-15 14:09, 9.66 s of
audio (154,529 samples, 16 kHz mono, 309,102 B). Every number is a log line
from that take; its timestamps are only 1 s apart, so nothing here is derived
by differencing them.

| stage | measured | log line |
|---|---|---|
| model load, overlaps the take | 1118 ms | `model load 1118 ms threads=6 path=…phonon-2.5-en-Q8_0.gguf` |
| segments 1-3, during recording | 1312 / 629 / 589 ms for 70,624 / 36,992 / 29,824 samples | `inference 1312 ms threads=6 samples=70624 chars=75`, then `inference 629 ms … samples=36992 chars=4` and `inference 589 ms … samples=29824 chars=26` |
| tail after release | **535 ms** for 23,489 samples (1.47 s) | `tail: model-wait=0 ms inference=535 ms samples=23489 trim=0 ms prefix=3` |
| paste | 139 chars | `pasted 139 chars via ctrl_v` |

Release to text is therefore **about 0.55-0.60 s**: 535 ms of tail inference,
then the clipboard write and `SendInput` chord (tens of ms, not logged). Two
things that are easy to get wrong:

- the `pasted` line is written *after* `paste_restore_delay_ms` (`paste.v:27`)
  has slept 500 ms following the chord, so it is not the text-arrival time;
  differencing it against `recording stopped` invents a delay nobody waits for;
- `paste_wait_for_modifiers` (`paste.v:28`) can add up to 500 ms *before* the
  chord, but only when Ctrl is still held once the tail finishes.

Same build and WAV through the CLI: `inference 2085-2476 ms` for
`samples=154529`, i.e. 216-256 ms per second of audio (per-second figures here
use the samples actually inferred, so a row's `trim` is subtracted). That
coefficient is not a constant: this take's 1.47 s tail runs at 364 ms/s, and a
30 s take at 220 ms/s (`inference 6603 ms … samples=480000`), because fixed
encoder cost dominates a short slice.

Shipped from the speed-up work, all in `v/host.v`: a segment already in flight
at release commits instead of being dropped and re-transcribed by the tail; the
clipboard/paste leg runs on a worker, so the paint loop keeps polling keys;
`seg_poll_ms` 100, `seg_silence_ms` 300 and a 3 s forced-cut ceiling;
exact leading zeros are skipped before inference; and an
empty transcript over real audio is logged and surfaced as a failure rather
than a silent success.

Blocked, with the measurement that blocks it: **canary-180m-flash** loads in
197 ms and runs at 70-111 ms per second of audio (`inference 679 ms …
samples=154529 chars=0`, `inference 811 ms … samples=142880 chars=116`) against
phonon's 216-256, but on this take it returns a valid *empty* transcript
(`chars=0`, exit 0). Making it usable needs prompt and special-token
conditioning in the shim, which is not in this repository. **Thread count** 6
versus 8 has never been measured for hex-v, so no figure is claimed for it.

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
