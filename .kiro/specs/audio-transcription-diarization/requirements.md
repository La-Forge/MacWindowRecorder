# Requirements: Audio Transcription with Speaker Diarization

## Overview

Add on-device audio transcription with speaker diarization to MacWindowRecorder (TabRecord). After a recording session ends, the app automatically transcribes the captured audio and identifies who said what, outputting a speaker-labeled transcript alongside the existing MP4/M4A files.

---

## User Stories

### 1. Automatic Post-Recording Transcription

**As a** MacWindowRecorder user,
**I want** the app to automatically transcribe my recording when it stops,
**So that** I get a searchable, speaker-labeled text transcript without manual effort.

**Acceptance Criteria:**
- AC 1.1: When recording stops, transcription begins automatically in the background
- AC 1.2: The menu bar icon shows a progress indicator while transcription is running
- AC 1.3: A notification is shown when transcription completes
- AC 1.4: Transcription does not block the UI or prevent starting a new recording
- AC 1.5: If transcription fails, the error is surfaced gracefully (notification + log) and the recording files are preserved

---

### 2. Speaker Diarization (Who Said What)

**As a** user recording meetings, interviews, or multi-party conversations,
**I want** the transcript to label which speaker said each segment,
**So that** I can quickly identify and reference individual contributions.

**Acceptance Criteria:**
- AC 2.1: Each transcript segment is labeled with a speaker identifier (e.g., `SPEAKER_00`, `SPEAKER_01`)
- AC 2.2: Speaker labels are consistent across the full transcript (same person = same label)
- AC 2.3: The system handles 2–8 speakers without configuration
- AC 2.4: A speaker count hint can optionally be provided before recording (defaults to auto-detect)
- AC 2.5: Diarization runs fully on-device — no audio is sent to external servers

---

### 3. Transcript Output Files

**As a** user,
**I want** the transcript saved in standard, interoperable formats,
**So that** I can use it in other tools (editors, note apps, subtitle players).

**Acceptance Criteria:**
- AC 3.1: A plain-text `.txt` file is saved alongside the recording with speaker-labeled paragraphs
- AC 3.2: A JSON file is saved with word-level timestamps, speaker labels, and confidence scores
- AC 3.3: An SRT subtitle file is saved for use with video players
- AC 3.4: All output files follow the existing naming convention: `tabrecord-YYYY-MM-DD-HHmmss-transcript.{ext}`
- AC 3.5: Files are saved to the same directory as the recording (`~/Movies/TabRecord/`)

---

### 4. Audio Source Selection for Transcription

**As a** user,
**I want** to choose which audio track gets transcribed,
**So that** I get the cleanest possible transcript (e.g., speaker audio without mic, or the mixed track).

**Acceptance Criteria:**
- AC 4.1: By default, the **speaker audio track** (Track 2 — clean source audio) is used for transcription
- AC 4.2: A preference allows switching to the **mic track** (Track 3) or the **mixed track** (Track 1)
- AC 4.3: The microphone track is always included in diarization even if not the primary ASR source (to improve diarization boundary detection)

---

### 5. Language Support

**As a** user who records in languages other than English,
**I want** automatic language detection,
**So that** the transcript is accurate without manual configuration.

**Acceptance Criteria:**
- AC 5.1: Language is auto-detected from the first 30 seconds of audio
- AC 5.2: Users can override the language in preferences (ISO 639-1 code, e.g., `en`, `fr`, `ja`)
- AC 5.3: Multilingual recordings are handled gracefully (detected language applied to full session)

---

### 6. On-Device Privacy

**As a** privacy-conscious user,
**I want** all transcription to happen locally on my Mac,
**So that** my audio and conversation content never leaves my device.

**Acceptance Criteria:**
- AC 6.1: All ASR and diarization models run entirely on-device using Apple Silicon acceleration
- AC 6.2: No network requests are made during transcription
- AC 6.3: Model files are stored locally after first download (cached in `~/Library/Application Support/TabRecord/Models/`)
- AC 6.4: A one-time model download happens on first use, with progress shown in the UI
- AC 6.5: The app functions fully offline after models are downloaded

---

### 7. Performance on M3 Max

**As a** user with an M3 Max MacBook,
**I want** transcription to complete faster than real-time,
**So that** I don't wait long after recording ends.

**Acceptance Criteria:**
- AC 7.1: A 1-hour recording transcribes in under 5 minutes on an M3 Max (real-time factor < 0.08x)
- AC 7.2: Transcription uses Apple Neural Engine (ANE) and GPU via CoreML/MLX
- AC 7.3: CPU usage during transcription stays below 40% (background processing)
- AC 7.4: The app remains responsive during transcription (no UI freezes)

---

### 8. Preferences and Configuration

**As a** power user,
**I want** to configure transcription behavior,
**So that** I can tune for my specific use case.

**Acceptance Criteria:**
- AC 8.1: A Preferences panel exposes transcription settings
- AC 8.2: Settings include: enable/disable auto-transcription, model size, language override, speaker count hint, output formats
- AC 8.3: Transcription can be manually triggered on any existing recording via the menu bar
- AC 8.4: Settings are persisted via `UserDefaults`

---

## Non-Functional Requirements

| Requirement | Target |
|---|---|
| Privacy | Fully on-device, zero network calls during transcription |
| Accuracy (WER) | ≤ 5% on clean English speech (large-v3-turbo model) |
| Diarization (DER) | ≤ 15% on 2–4 speaker conversations |
| Speed (M3 Max) | Real-time factor < 0.08x for large-v3-turbo |
| Memory | Peak < 4 GB RAM during transcription |
| macOS minimum | macOS 14.0 (Sonoma) — required for latest CoreML optimizations |
| Dependency policy | New dependencies via Swift Package Manager only (no Python runtime shipped) |
| License compatibility | All model licenses must be Apache 2.0 or CC-BY compatible |

---

## Out of Scope

- Real-time (live) transcription during recording (future feature)
- Speaker identification / named speaker recognition
- Translation (transcribe in source language only)
- Cloud transcription fallback
- Windows/Linux support
