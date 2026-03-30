# TabRecord

macOS menu bar app that records any **window or display** with separate audio
tracks (source audio + microphone) using ScreenCaptureKit and AVFoundation.

## Installation

**[Download TabRecord.dmg](https://github.com/La-Forge/MacWindowRecorder/releases/latest/download/TabRecord.dmg)**

1. Open the DMG
2. Drag **TabRecord** into the **Applications** folder
3. Launch it from Applications or Spotlight

> **Tip — use earphones while recording.** TabRecord captures microphone and speaker audio on separate tracks. If you use speakers instead of earphones, your mic will pick up the speaker audio and create echo or bleed between the two audio channels.

## Requirements

| Feature | Minimum macOS |
|---|---|
| Recording (screen + audio) | **13.0 (Ventura)** |
| Transcription + diarization | **14.0 (Sonoma)** |

> **Why macOS 13 for recording?** `SCStreamOutputType.audio` was introduced in macOS 13.
> **Why macOS 14 for transcription?** WhisperKit CoreML optimisations (ANE encoder) require the macOS 14 CoreML runtime.

## First launch — permissions

The app requests two permissions on first launch:

1. **Screen Recording** — granted via System Settings → Privacy & Security → Screen Recording
2. **Microphone** — a system alert appears automatically

To re-grant a denied permission: System Settings → Privacy & Security → toggle TabRecord.

---

## Building from source

### Prerequisites

| Tool | Version |
|---|---|
| Xcode | 15.0+ |
| XcodeGen | 2.x (`brew install xcodegen`) |
| Apple Developer account | Required for notarization only |

### Quick start

```bash
# 1. Install XcodeGen
brew install xcodegen

# 2. Generate the Xcode project
cd TabRecord/native-app
make gen

# 3. Open in Xcode, build, and run
open TabRecordApp.xcodeproj
```

Or build and launch in one command:

```bash
make run
```

### Distribution

```bash
# Release build
make build

# Notarize (fill in env vars first)
APPLE_ID=you@example.com TEAM_ID=XXXXXXXX APP_PASSWORD=xxxx make notarize
```

See `Makefile` for full notarization details.

---

## Transcription & Speaker Diarization

> Requires **macOS 14.0+**. Models are downloaded once (~1.5 GB) and cached locally.

After each recording, TabRecord automatically transcribes the audio and identifies speakers — **entirely on-device** using Apple Neural Engine acceleration. No audio ever leaves your Mac.

### Output files (saved alongside the recording)

```
tabrecord-YYYY-MM-DD-HHmmss-transcript.txt   ← speaker-labelled plain text
tabrecord-YYYY-MM-DD-HHmmss-transcript.json  ← word-level timestamps + speakers
tabrecord-YYYY-MM-DD-HHmmss-transcript.srt   ← subtitles for QuickTime / VLC
```

### Example TXT output

```
[00:00:03 → 00:00:12] SPEAKER_00:
Hello everyone, welcome to the meeting. Today we're going over the quarterly results.

[00:00:13 → 00:00:28] SPEAKER_01:
Thanks for having me. I've prepared a short summary of the key metrics.
```

### Privacy

All transcription and diarization runs locally via [WhisperKit](https://github.com/argmaxinc/WhisperKit) (Whisper large-v3-turbo, CoreML/ANE) and [SpeakerKit](https://github.com/argmaxinc/SpeakerKit) (pyannote v4, CoreML/ANE). No data is sent to any server.

### Performance on M3 Max

| Step | Duration (60 min audio) |
|---|---|
| Transcription (large-v3-turbo, ANE) | ~3 min |
| Speaker diarization (SpeakerKit, ANE) | ~12 sec |
| **Total** | **~3.5 min** |

### Configuration

Open **Preferences…** from the menu bar icon to configure:
- Model size (Small / Medium / Large v3 Turbo / Large v3)
- Language override (default: auto-detect)
- Speaker count hint (default: auto)
- Audio source for transcription (speaker track / mic / mixed)
- Output formats (TXT, JSON, SRT)
- Enable / disable auto-transcription

---

## Output format

Files are saved in `~/Movies/TabRecord/`:

```
tabrecord-YYYY-MM-DD-HHmmss.mp4
```

The file contains **three audio tracks**:

| Track | Content |
|---|---|
| `index=1` | Mixed (source + mic), stereo |
| `index=2` | Source audio only, stereo |
| `index=3` | Microphone only, mono |

Verify with ffprobe:

```bash
ffprobe -v quiet -show_streams -select_streams a tabrecord-2026-03-13-120000.mp4
```

---

## Architecture

```
main.swift
  └── AppDelegate              ← LSUIElement mode, TCC checks, notification setup
        └── MenuBarController  ← NSStatusItem, menu, duration timer
              ├── SourcePickerWindowController   ← SwiftUI picker (displays / windows)
              ├── RecordingEngine                ← SCStream + AVAudioEngine + AVAssetWriter
              │     ├── SCStream               ← video + source audio (ScreenCaptureKit)
              │     ├── AVAudioEngine          ← microphone tap
              │     └── AVAssetWriter          ← MP4 output, 3 audio tracks
              └── TranscriptionCoordinator       ← post-recording transcription pipeline
                    ├── ModelManager           ← CoreML model download & cache
                    ├── AudioPreprocessor      ← extract track → 16 kHz mono WAV
                    ├── WhisperKitTranscriber  ← ASR via WhisperKit (ANE/CoreML)
                    ├── SpeakerKitDiarizer     ← diarization via SpeakerKit (ANE/CoreML)
                    ├── SegmentAligner         ← merge word timestamps + speaker labels
                    └── TranscriptWriter       ← write TXT / JSON / SRT files
```

### File map

| File | Purpose |
|---|---|
| `project.yml` | XcodeGen project spec |
| `Makefile` | Build, run, notarize shortcuts |
| `TabRecordApp/main.swift` | App entry point |
| `TabRecordApp/AppDelegate.swift` | App lifecycle + screen capture TCC check |
| `TabRecordApp/MenuBarController.swift` | Status item, menu, timer, lifecycle glue |
| `TabRecordApp/RecordingEngine.swift` | SCStream + AVAudioEngine + AVAssetWriter |
| `TabRecordApp/SourcePickerView.swift` | SwiftUI picker for displays/windows |
| `TabRecordApp/Info.plist` | App metadata, LSUIElement, usage strings |
| `TabRecordApp/TabRecord.entitlements` | Hardened Runtime: audio-input |

---

## Contributing

Bug reports and pull requests are welcome.

**Guidelines:**

- Follow the existing Swift style (no third-party dependencies, AppKit + SwiftUI only)
- Keep changes focused — one concern per PR
- New behaviour must ship with tests or a reproducible verification step
- Use [semantic commit messages](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `chore:`, etc.)
- Open an issue before starting large refactors so we can align on direction

[Open an issue](https://github.com/La-Forge/MacWindowRecorder/issues) for bugs, feature requests, or questions.
