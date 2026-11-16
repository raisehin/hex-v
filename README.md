# HEX-V

Local voice dictation for Windows.

Hold Ctrl+Space. Speak. Let go.
Text lands where your cursor is.

---

## MISSION

hex-v is a Windows rebuild of OpenCode hex 3.4.0's
Dot scope HUD and dictation flow.

It is not the full Hex app. It keeps the look and feel of the
speaking indicator, then runs dictation locally through a shim.

---

## WHAT IT DOES

- Shows a small Dot scope HUD while you speak.
- The dots move with your voice.
- The HUD turns blue while text is being made.
- Shows a done wipe when text is ready.
- Shows a failure look if a take fails.
- Records the microphone at 16 kHz mono.
- Transcribes short pieces while you are still speaking.
- Transcribes the rest after you stop.
- Pastes the final text into the app you are using.
- Restores your clipboard after pasting.
- Keeps the model warm for fast starts.
- Can release the model after idle time if asked.
- Saves the last recording.
- Writes timing logs for model load and transcription.

Nothing is sent to a cloud service by hex-v itself.
Transcription runs through a local shim and local models.

---

## FLIGHT RULES

- Ctrl+Space — start dictation
- Ctrl+Space — stop dictation
- Esc — cancel while recording or transcribing
- Ctrl+Alt+Q — quit

The dictation key is fixed.
It cannot be changed in this build.

---

## HOW A TAKE WORKS

1. Press Ctrl+Space.
2. The HUD opens.
3. The Dot scope follows your voice.
4. Silence and speech are detected with a small VAD model.
5. Long enough speech pieces are transcribed during the take.
6. Press Ctrl+Space again to stop.
7. The remaining audio is transcribed as a tail.
8. The text is pasted at the cursor.
9. Your old clipboard text is restored.

Segment timing:

- check audio every 100 ms;
- close a piece after 300 ms of silence;
- minimum speech piece is 0.5 s;
- force a cut after 2 s of non-stop speech.

This keeps the wait after stop short.

---

## SPEECH MODEL

hex-v uses one speech model only:

```text
Phonon 2.5 English, Q8 quantization
```

That is the only accepted model.
Other model ids stop the app with a config error.

A small Silero VAD model helps find speech and silence.

Models must be installed before first use:

```powershell
.\v\bin\hexv.exe models check
.\v\bin\hexv.exe models install
```

There is no automatic first-run download.

---

## ASR ENGINE

hex-v does not include its own speech engine.

It uses the external transcription shim.
The shim must be present at runtime.
It is not needed to build the program.

---

## PASTING

The text can be pasted in four ways:

- Ctrl+V
- Ctrl+Shift+V
- Shift+Insert
- typed as text

The default is Ctrl+V.

Clipboard restore is text only.
Images, HTML, and file lists are not restored.

---

## BUILD

Windows x64 only.

Requirements:

- V 0.5.2
- gcc on PATH

```powershell
.\build-github.ps1
.\v\bin\hexv.exe
```

The build script can fetch the pinned V compiler.
It also checks that the app icon is embedded in the exe.

---

## OTHER COMMANDS

```powershell
.\v\bin\hexv.exe transcribe <file.wav> [model] [language]
.\v\bin\hexv.exe record <seconds> <file.wav>
.\v\bin\hexv.exe paste-file <file.wav>
.\v\bin\hexv.exe replay
.\v\bin\hexv.exe render
```

---

## WHAT IT IS NOT

- not macOS
- not Linux
- not the full OpenCode Hex app
- not a Labs sidebar

---

## LIMITS

- Windows only
- one speech model
- one fixed dictation key
- local shim required
- no PNG golden-frame check yet
