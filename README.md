# Hex V

A Windows reimplementation of **Hex**'s speaking indicator and dictation HUD,
written in [V](https://vlang.io/). Hex is opencode's Rust dictation app; Hex V
is based on Hex 3.4.0's Dot-scope HUD and ports the HUD, capture and dictation
host to V rather than wrapping the Rust app.

The Dot scope is the focus: the real `Scope`/`Indicator` simulation, a CPU port
of Hex's `rune_hud.wgsl` fragment path, and a layered Win32 presenter. The same
process also hosts live dictation: Win32 capture, VAD-segmented transcription,
clipboard paste and restore, and the usual `Ctrl+Space` / `Esc` controls.

## What is here

- **Dot-scope simulation** — springs, voice, traces, working/processing/done
  phases, AutoLevel, and the 330-frame reference schedule.
- **CPU rasteriser** — the plate, dots, shadow, rim and glow from Hex's WGSL
  fragment path, written in V.
- **Layered Windows presenter** — a 320x128 top-down DIB presented with
  `UpdateLayeredWindow`.
- **Real dictation host** — default microphone via `waveIn`, mono 16 kHz f32,
  VAD segment boundaries, transcription off the paint thread, clipboard
  save/restore.
- **V-owned control surface** — hotkeys, window loop, paste modes and a small
  CLI for transcribing files, recording, replaying the HUD and probing timing.

## Provenance

Hex V is based on **Hex 3.4.0** (opencode's Rust app). The HUD's source of truth
is Hex's `rune-motion` revision:

```text
rune-motion rev ba5e7c8069a24c36f95ca90a3058083cd468fcd1
```

The `oracle/` tree contains standalone copies of the five Rust simulation files
used to generate the reference dot buffer. The 330-frame dot gate is:

```text
330 frames x 4096 bytes
SHA-256 a8d6f7c484fc376dbb18c113782e74ec69cc3047cc35a293e1ec16631521918c
```

The V simulation and raster produce the same dot buffer and reference PNGs for
that schedule.

## Capture and host

- `v/capture.v` opens the default capture endpoint through `waveIn` with 50
  prepared 20 ms buffers, downmixes to mono f32, and resamples the finished
  recording to 16 kHz.
- `v/host.v` owns the dictation state machine, VAD segmentation, transcription
  workers and clipboard paste.
- `v/window.v` owns the layered window and paint/main loop.
- `v/asr.v` loads the existing `transcribe_shim.dll`; speech recognition is not
  reimplemented in V.
- `v/paste.v` sends the configured paste chord and restores the previous text
  clipboard unless the user copied something newer.

The ASR shim is the C++/ggml `transcribe.cpp` path. It is an external runtime
dependency, not V code: the Windows app, HUD, rasteriser, capture and paste
paths are V.

## Build

Windows x64 only. The documented build uses V with gcc, and disables floating
point contraction because the reference Rust build does not contract mul+add:

```powershell
v -prod -cc gcc -cflags "-ffp-contract=off" -o v/bin/hexv.exe v
```

Run:

```powershell
.\v\bin\hexv.exe
```

The dictation host loads the model configured in `%APPDATA%\hex\odin-config`
and the models under `%APPDATA%\hex\models`, including:

- `phonon-2.5-en-Q8_0.gguf`
- `silero-vad-v6.2-F32.gguf`

It also expects `transcribe_shim.dll` at the path compiled into `v/asr.v`.

## Controls

- `Ctrl+Space` — start or stop a dictation
- `Esc` — cancel a recording or an in-flight transcription
- `Ctrl+Alt+Q` — quit

CLI:

```text
hexv transcribe <file.wav> [model] [language]
hexv record <seconds> <file.wav>
hexv paste-file <file.wav>
hexv replay <dir>
hexv render <dir>
hexv probe
hexv paint-probe
```

## Layout

```text
oracle/     Rust simulation sources used to produce the reference frames
v/          the V application
  dotscope.v     Dot-scope simulation
  indicator.v    HUD state / indicator phases
  render/        CPU rasteriser
  window.v       layered Win32 presenter and paint loop
  capture.v      waveIn capture
  host.v         dictation state machine and VAD segmentation
  asr.v          transcribe.cpp shim loader
  paste.v        clipboard and paste
  wavio.v        WAV read/write
```

## Status

- Dot simulation and CPU raster: byte-identical to the reference schedule.
- HUD presenter: working on Windows.
- Dictation host: working with the existing transcribe.cpp shim.
- Full Hex application parity: not attempted. The Rust app's window/pane
  system, local API and updater are not part of Hex V.

Hex V is an independent Windows/V implementation of the Hex HUD and dictation
flow. It is not a fork of the Rust application.
