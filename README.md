# TabRecord — Native App (Phase 2)

macOS menu bar app that records any **window or display** with separate audio
tracks (source audio + microphone) using ScreenCaptureKit and AVFoundation.

## Requirements

| Requirement | Version |
|---|---|
| macOS | **13.0 (Ventura)** or later |
| Xcode | 15.0+ |
| XcodeGen | 2.x (`brew install xcodegen`) |
| Apple Developer account | Required for distribution / notarization only |

> **Why macOS 13?** `SCStreamOutputType.audio` (separate audio output from
> SCStream) was introduced in macOS 13. On macOS 12 only video is available.

## Quick start

```bash
# 1. Install XcodeGen if you don't have it
brew install xcodegen

# 2. Generate the Xcode project
cd TabRecord/native-app
make gen

# 3. Open in Xcode, build, and run
open TabRecordApp.xcodeproj
```

Or build + launch in one command:

```bash
make run
```

## First launch — permissions

The app requests two TCC permissions on first launch:

1. **Screen Recording** — granted via System Settings → Privacy & Security → Screen Recording
2. **Microphone** — a system alert appears automatically

If you deny either and want to re-grant it, go to System Settings → Privacy & Security and toggle the entry for TabRecord.

## Architecture

```
main.swift
  └── AppDelegate           ← sets LSUIElement mode, checks screen capture TCC
        └── MenuBarController   ← NSStatusItem, menu, duration timer
              ├── SourcePickerWindowController  ← SwiftUI picker (displays / windows)
              └── RecordingEngine               ← core capture & write pipeline
                    ├── SCStream              ← video + source audio (ScreenCaptureKit)
                    ├── AVAudioEngine         ← microphone tap
                    └── AVAssetWriter         ← MP4 output, 3 tracks
```

## Output format

Files are saved in `~/Movies/TabRecord/` with the name pattern:

```
tabrecord-YYYY-MM-DD-HHmmss.mp4
```

Verify tracks with ffprobe:

```bash
ffprobe -v quiet -show_streams -select_streams a tabrecord-2026-03-13-120000.mp4
```

Expected output: **two audio streams** — `index=1` (source, stereo) and `index=2` (mic, mono).

## Distribution

```bash
# Release build
make build

# Notarize (fill in env vars first)
APPLE_ID=you@example.com TEAM_ID=XXXXXXXX APP_PASSWORD=xxxx make notarize
```

See `Makefile` for full notarization details.

## File map

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
