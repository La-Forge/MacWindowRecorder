# Tasks: Audio Transcription with Speaker Diarization

## Implementation Order

Tasks are ordered by dependency. Each task maps to one focused PR or commit.

---

## Phase 1: Foundation

### Task 1 — Add SPM Dependencies
**Files:** `project.yml`
**Effort:** XS (30 min)

Add WhisperKit and SpeakerKit Swift Package Manager dependencies to the XcodeGen project spec.

- [ ] Add `WhisperKit` package (github.com/argmaxinc/WhisperKit, from: 0.9.0) to `project.yml`
- [ ] Add `SpeakerKit` package (github.com/argmaxinc/SpeakerKit, from: 0.1.0) to `project.yml`
- [ ] Link both frameworks to the `TabRecordApp` target
- [ ] Run `make gen` and verify the project builds with no errors
- [ ] Confirm no dependency conflicts with existing Apple framework usage

---

### Task 2 — TranscriptionPreferences Model
**Files:** `TabRecordApp/TranscriptionPreferences.swift` (new)
**Effort:** S (1 hour)

Create the `@AppStorage`-backed preferences model before any UI is built.

- [ ] Create `TranscriptionPreferences.swift` with all `@AppStorage` properties from design doc
- [ ] Define `WhisperModelVariant` enum (largev3Turbo, largev3, medium, small)
- [ ] Define `AudioSource` enum (speakerTrack, micTrack, mixedTrack)
- [ ] Add `TranscriptFormat` enum (txt, json, srt)
- [ ] Write unit tests in `TabRecordAppTests/TranscriptionPreferencesTests.swift`
  - [ ] Test default values
  - [ ] Test persistence round-trip (set value, re-init, verify value)

---

### Task 3 — ModelManager
**Files:** `TabRecordApp/ModelManager.swift` (new), `TabRecordAppTests/ModelManagerTests.swift` (new)
**Effort:** M (3 hours)

Implement the actor that manages CoreML model download, caching, and storage.

- [ ] Create `ModelManager` actor
- [ ] Implement `modelsDirectory` pointing to `~/Library/Application Support/TabRecord/Models/`
- [ ] Implement `ensureWhisperModel(_ variant:)` using `WhisperKit.download(variant:to:)` API
- [ ] Implement `ensureSpeakerModel()` using `SpeakerKit.download(to:)` API
- [ ] Implement `downloadProgress(for:)` returning `AsyncStream<Double>` (0.0–1.0)
- [ ] Implement `installedModels` computed property (scan directory)
- [ ] Implement `deleteModel(_ :)` (remove directory, free disk space)
- [ ] Implement disk space pre-check before download (warn if < required space + 500 MB buffer)
- [ ] Write unit tests:
  - [ ] `testCacheHit()` — second call to `ensureWhisperModel` doesn't re-download
  - [ ] `testMissingModel()` — triggers download (mock network)
  - [ ] `testDiskSpaceCheck()` — insufficient space throws correct error
  - [ ] `testInstalledModels()` — lists installed models correctly

---

## Phase 2: Core Pipeline

### Task 4 — AudioPreprocessor
**Files:** `TabRecordApp/AudioPreprocessor.swift` (new), `TabRecordAppTests/AudioPreprocessorTests.swift` (new)
**Effort:** M (3 hours)

Extract and resample audio from multi-track MP4 to 16kHz mono WAV for Whisper.

- [ ] Create `AudioPreprocessor` struct
- [ ] Implement `prepareForTranscription(source:recordingFiles:)` using `AVAssetReader`
- [ ] Map `AudioSource` enum values to the correct MP4 track indices (0=mixed, 1=speaker, 2=mic)
- [ ] Use `AVAssetReaderTrackOutput` with `kAudioFormatLinearPCM` settings
- [ ] Use `AVAudioConverter` to resample to 16kHz mono Float32 PCM
- [ ] Write output WAV to `FileManager.default.temporaryDirectory`
- [ ] Clean up temp files after transcription completes
- [ ] Write unit tests:
  - [ ] `testSpeakerTrackExtraction()` — extracts Track 2 (index 1) from a synthetic MP4
  - [ ] `testResamplingTo16kHz()` — 48kHz stereo input → 16kHz mono output, verify sample count
  - [ ] `testTempFileCleanup()` — temp file removed after coordinator signals completion

---

### Task 5 — WhisperKitTranscriber
**Files:** `TabRecordApp/WhisperKitTranscriber.swift` (new)
**Effort:** M (3 hours)

Wrap WhisperKit to produce word-timestamped segments.

- [ ] Create `WhisperKitTranscriber` actor
- [ ] Implement `load(modelPath:)` — init WhisperKit with `cpuAndNeuralEngine` compute units
- [ ] Implement `transcribe(audioURL:language:wordTimestamps:)`
- [ ] Map WhisperKit output to internal `WhisperSegment` / `WordTimestamp` structs
- [ ] Handle language auto-detection (pass `nil` language to WhisperKit, capture detected language from result)
- [ ] Surface transcription progress via `AsyncStream<Double>` using WhisperKit's progress callback
- [ ] Write integration test (requires model on disk — skip in CI if model absent):
  - [ ] `testShortEnglishAudio()` — known 10s clip, verify WER < 10%
  - [ ] `testLanguageDetection()` — French audio, verify detected language = "fr"

---

### Task 6 — SpeakerKitDiarizer
**Files:** `TabRecordApp/SpeakerKitDiarizer.swift` (new)
**Effort:** M (2 hours)

Wrap SpeakerKit to produce speaker-labeled time segments.

- [ ] Create `SpeakerKitDiarizer` actor
- [ ] Implement `load(modelPath:)` — init SpeakerKit
- [ ] Implement `diarize(audioURL:numSpeakers:)` — pass `nil` for auto-detect
- [ ] Map SpeakerKit output to internal `DiarizationSegment` structs with `SPEAKER_XX` labels
- [ ] Write integration test (requires model on disk — skip in CI if model absent):
  - [ ] `testTwoSpeakers()` — synthetic two-speaker audio, verify exactly 2 distinct labels

---

### Task 7 — SegmentAligner
**Files:** `TabRecordApp/SegmentAligner.swift` (new), `TabRecordAppTests/SegmentAlignerTests.swift` (new)
**Effort:** M (3 hours)

Merge word-level Whisper output with diarization segments.

- [ ] Create `SegmentAligner` struct
- [ ] Implement midpoint-based word-to-speaker assignment algorithm
- [ ] Group consecutive same-speaker words into `AttributedSegment` blocks
- [ ] Handle edge cases:
  - [ ] Empty diarization (return segments with `speaker: "SPEAKER_UNKNOWN"`)
  - [ ] Empty transcription (return empty array)
  - [ ] Single speaker throughout
  - [ ] Word timestamp after last diarization segment (assign to nearest)
- [ ] Write unit tests:
  - [ ] `testBasicTwoSpeaker()` — interleaved segments, verify correct speaker assignment
  - [ ] `testBoundaryWord()` — word at exact speaker boundary → assigned by midpoint
  - [ ] `testEmptyDiarization()` — produces SPEAKER_UNKNOWN output
  - [ ] `testSingleSpeaker()` — all words merged into one segment
  - [ ] `testGapBetweenSegments()` — silence gap handled without crash

---

### Task 8 — TranscriptWriter
**Files:** `TabRecordApp/TranscriptWriter.swift` (new), `TabRecordAppTests/TranscriptWriterTests.swift` (new)
**Effort:** M (3 hours)

Write aligned segments to TXT, JSON, and SRT files.

- [ ] Create `TranscriptWriter` struct
- [ ] Implement `write(segments:baseURL:language:formats:)`
- [ ] Implement `.txt` format:
  - [ ] `[HH:MM:SS → HH:MM:SS] SPEAKER_XX:` header per speaker block
  - [ ] Paragraph text with trailing newline
- [ ] Implement `.json` format:
  - [ ] Top-level: `language`, `duration`, `speakers` array, `segments` array
  - [ ] Each segment: `start`, `end`, `speaker`, `text`, `words` array
  - [ ] `JSONEncoder` with `.prettyPrinted` + `.sortedKeys`
- [ ] Implement `.srt` format:
  - [ ] Standard SRT index, timecode (`HH:MM:SS,mmm --> HH:MM:SS,mmm`), text
  - [ ] Max 2 lines / 42 chars per subtitle block (split long segments)
  - [ ] Prepend `[SPEAKER_XX]` to first line of each speaker block
- [ ] Follow `OutputFileNamer` convention for file URLs
- [ ] Write unit tests:
  - [ ] `testTxtFormat()` — known segments → verify exact string output
  - [ ] `testJsonFormat()` — known segments → verify JSON structure and values
  - [ ] `testSrtFormat()` — known segments → verify timecodes and line wrapping
  - [ ] `testFileNaming()` — verify filenames follow `tabrecord-YYYY-MM-DD-HHmmss-transcript.*` pattern

---

## Phase 3: Orchestration & UI

### Task 9 — TranscriptionCoordinator
**Files:** `TabRecordApp/TranscriptionCoordinator.swift` (new)
**Effort:** L (4 hours)

Wire all pipeline components together with progress reporting and error handling.

- [ ] Create `@MainActor` `TranscriptionCoordinator: ObservableObject`
- [ ] Define `TranscriptionState` enum with all states from design doc
- [ ] Implement `transcribe(recordingURL:preferences:)` as `async` function
- [ ] Launch pipeline on `Task(priority: .utility)` to avoid blocking main thread
- [ ] Implement progress publishing: transcription (0–70%), diarization (70–90%), writing (90–100%)
- [ ] Implement graceful degradation: if SpeakerKit fails, emit transcript without speaker labels
- [ ] Implement fallback: if WhisperKit fails, attempt `SFSpeechRecognizer` (no timestamps/diarization)
- [ ] Schedule `UNUserNotificationCenter` notification on completion (with "Show in Finder" action)
- [ ] Schedule notification on failure (with "Retry" action)
- [ ] Implement `transcribeManually(recordingFiles:)` for menu-triggered transcription
- [ ] Clean up temp files (`AudioPreprocessor` outputs) on coordinator deinit
- [ ] Write integration test:
  - [ ] `testFullPipelineWithMocks()` — mock all 4 actors, verify state transitions in order

---

### Task 10 — MenuBarController Integration
**Files:** `TabRecordApp/MenuBarController.swift` (existing — modify)
**Effort:** M (2 hours)

Integrate `TranscriptionCoordinator` into the existing menu bar controller.

- [ ] Add `TranscriptionCoordinator` as a property of `MenuBarController`
- [ ] Call `coordinator.transcribe(recordingURL:preferences:)` in `stopRecording()` if preferences enabled
- [ ] Add status icon animation (e.g., spinning or pulsing) while `coordinator.state == .transcribing`
- [ ] Add "Transcribing…" disabled menu item while transcription runs
- [ ] Add "Transcribe Last Recording" menu item (enabled when last recording exists, macOS 14+)
- [ ] Add "Preferences…" menu item (if not already present) that opens `PreferencesView`
- [ ] Guard all transcription UI with `if #available(macOS 14.0, *)`

---

### Task 11 — PreferencesView
**Files:** `TabRecordApp/PreferencesView.swift` (new)
**Effort:** M (3 hours)

Build the SwiftUI Transcription preferences tab.

- [ ] Create `PreferencesView` as a tabbed `Form` (Recording tab + Transcription tab)
- [ ] Transcription tab contains:
  - [ ] `Toggle` for auto-transcribe
  - [ ] `Picker` for model variant (with storage size annotations)
  - [ ] `Picker` for language (Auto-detect + common languages)
  - [ ] `Stepper` / `Picker` for speaker count (0=auto, 1–8)
  - [ ] `Picker` for audio source
  - [ ] Checkboxes for output formats (txt, json, srt)
  - [ ] Model storage section: used space, download/delete buttons
- [ ] Connect all controls to `TranscriptionPreferences` via `@ObservedObject`
- [ ] Show model download progress inline when downloading
- [ ] Open via `NSApp.sendAction(#selector(NSApplication.showPreferencesWindow:)...)`
  or custom `NSWindow` if needed
- [ ] Add `PreferencesViewTests.swift` for snapshot tests (if XCTest snapshot testing is available)

---

### Task 12 — Notification Handling
**Files:** `TabRecordApp/AppDelegate.swift` (existing — modify)
**Effort:** S (1.5 hours)

Handle notification actions (Show in Finder, Retry).

- [ ] Request `UNUserNotificationCenter` authorization at launch (alongside existing permissions)
- [ ] Register notification categories: `TRANSCRIPTION_COMPLETE` (Show in Finder), `TRANSCRIPTION_FAILED` (Retry)
- [ ] Implement `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:)` in `AppDelegate`
- [ ] "Show in Finder": call `NSWorkspace.shared.selectFile(_:inFileViewerRootedAtPath:)` on transcript URL
- [ ] "Retry": call `TranscriptionCoordinator.transcribeManually(recordingFiles:)` on last recording

---

## Phase 4: Polish & Release

### Task 13 — README and Documentation Update
**Files:** `README.md`, `SPEC-transcription.md` (new)
**Effort:** S (1 hour)

- [ ] Add "Transcription" section to README with feature overview
- [ ] Document: auto-transcription, output files, format examples
- [ ] Note macOS 14.0 requirement for transcription (13.0 still supported for recording)
- [ ] Note first-launch model download (~1.5 GB for default model)
- [ ] Note privacy: fully on-device, no data leaves Mac
- [ ] Create `SPEC-transcription.md` with technical details for contributors

---

### Task 14 — CI/CD Updates
**Files:** `.github/workflows/release.yml`
**Effort:** S (30 min)

- [ ] Ensure SPM package resolution is cached in CI (speeds up build times)
- [ ] Exclude model files from the release DMG (models download at runtime)
- [ ] Add a note to release notes template about transcription feature and model download

---

### Task 15 — Version Bump
**Files:** `TabRecordApp/Info.plist`, `project.yml`
**Effort:** XS (15 min)

- [ ] Bump version from `1.0.4` to `1.1.0` (minor version — new feature)
- [ ] Run `scripts/bump.sh 1.1.0`
- [ ] Verify `make build` succeeds

---

## Summary

| Phase | Tasks | Estimated Effort |
|---|---|---|
| Phase 1: Foundation | 1–3 | ~4.5 hours |
| Phase 2: Core Pipeline | 4–8 | ~14 hours |
| Phase 3: Orchestration & UI | 9–12 | ~10.5 hours |
| Phase 4: Polish & Release | 13–15 | ~1.75 hours |
| **Total** | **15 tasks** | **~31 hours** |

## Dependencies Graph

```
Task 1 (SPM)
    └── Task 5 (WhisperKitTranscriber)
    └── Task 6 (SpeakerKitDiarizer)

Task 2 (Preferences)
    └── Task 11 (PreferencesView)
    └── Task 9 (Coordinator)

Task 3 (ModelManager)
    └── Task 9 (Coordinator)
    └── Task 11 (PreferencesView)

Task 4 (AudioPreprocessor)
    └── Task 9 (Coordinator)

Task 5 + Task 6
    └── Task 9 (Coordinator)

Task 7 (SegmentAligner)
    └── Task 9 (Coordinator)

Task 8 (TranscriptWriter)
    └── Task 9 (Coordinator)

Task 9 (Coordinator) → Task 10 (MenuBar) → Task 12 (Notifications)

Task 10 + Task 11 + Task 12 → Task 13 (Docs) → Task 14 (CI) → Task 15 (Version)
```
