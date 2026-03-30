# Design: Audio Transcription with Speaker Diarization

## Research Summary

### Evaluated Options on M3 Max

| Approach | ASR | Diarization | GPU Utilization | WER | DER | Notes |
|---|---|---|---|---|---|---|
| **WhisperKit + SpeakerKit** | Whisper CoreML | pyannote v4 CoreML | ANE (best) | ~2.2% | Best open-source | Native Swift, SPM, recommended |
| mlx-whisper + pyannote | Whisper MLX | pyannote community-1 | Full MLX GPU | ~2-3% | ~11-15% | Requires Python runtime |
| WhisperX | faster-whisper | pyannote | CPU only (Mac) | ~2-3% | ~11-15% | Slow on Apple Silicon |
| Scribe (CLI) | Parakeet MLX | CoreML senko | CoreML/MLX | ~6% | N/A | No HF token, fast |
| mlx-audio + Sortformer | Parakeet MLX | Sortformer MLX | Full MLX GPU | ~6% | SOTA 2025 | Python, no HF token |
| Apple SpeechAnalyzer | Native (Tahoe) | None | ANE | ~8% | None | macOS 26+ only, no diarization |
| NeMo MSDD | NVIDIA-first | MSDD | CPU only on Mac | — | — | Not viable on Mac |

### Decision: WhisperKit + SpeakerKit (Swift)

**Rationale:**

1. **Native Swift SPM packages** — zero Python runtime, consistent with project's no-external-dependencies philosophy
2. **Best hardware utilization** — runs directly on Apple Neural Engine (ANE) via CoreML; benchmarks show 4.6ms/forward pass on M3 Max vs. 8.4ms for naive inference (45% reduction)
3. **Best speed** — WhisperKit achieves RTF of ~0.05x on M3 Max with large-v3-turbo; 1 hour of audio transcribes in ~3 minutes
4. **SpeakerKit** (announced March 2025) provides pyannote v4 diarization models converted to CoreML, requiring no HuggingFace token after download
5. **Accuracy** — 2.2% WER (large-v3-turbo), competitive DER on SpeakerKit benchmarks
6. **Privacy** — fully on-device, models cached in Application Support after first download
7. **License** — WhisperKit: MIT, SpeakerKit: MIT, Whisper models: MIT

**Trade-offs accepted:**
- Requires macOS 14.0+ (up from 13.0) for latest CoreML optimizations → documented as new minimum for transcription feature (recording still works on 13.0)
- Model download on first use (~1.5 GB for large-v3-turbo + SpeakerKit models)
- SpeakerKit is newer (March 2025) — less community validation than pyannote Python pipeline

---

## Architecture

### High-Level Component Flow

```
RecordingEngine (existing)
    │
    │ stopRecording() → produces M4A files
    ▼
TranscriptionCoordinator          ← new
    │
    ├── ModelManager              ← new (download / cache CoreML models)
    │       └── ~/Library/Application Support/TabRecord/Models/
    │
    ├── AudioPreprocessor         ← new (extract PCM from M4A, resample to 16kHz)
    │
    ├── WhisperKitTranscriber     ← new (wraps WhisperKit SPM)
    │       └── WhisperKit (SPM)  ← dependency
    │
    ├── SpeakerKitDiarizer        ← new (wraps SpeakerKit SPM)
    │       └── SpeakerKit (SPM)  ← dependency
    │
    ├── SegmentAligner            ← new (merge ASR segments with diarization RTTM)
    │
    └── TranscriptWriter          ← new (write .txt, .json, .srt files)

MenuBarController (existing)
    │
    └── TranscriptionCoordinator  (calls start, observes progress/completion)

PreferencesView                   ← new (SwiftUI preferences panel)
    └── TranscriptionPreferences  ← new (UserDefaults-backed settings model)
```

---

## Component Design

### 1. `TranscriptionCoordinator`

Central orchestrator. Triggered by `MenuBarController` after recording stops (if auto-transcription is enabled).

```swift
@MainActor
final class TranscriptionCoordinator: ObservableObject {
    @Published var state: TranscriptionState = .idle

    enum TranscriptionState {
        case idle
        case preparingModel
        case transcribing(progress: Double)
        case diarizing(progress: Double)
        case aligning
        case writing
        case completed(TranscriptionResult)
        case failed(Error)
    }

    func transcribe(recordingURL: URL, preferences: TranscriptionPreferences) async
    func transcribe(existingRecording: RecordingFiles) async  // manual trigger
}
```

**Responsibilities:**
- Manages the pipeline: preprocess → transcribe → diarize → align → write
- Reports progress to `MenuBarController` for status icon updates
- Sends `UNUserNotificationCenter` notifications on completion/failure
- Runs pipeline on a detached `Task` (background priority) to keep UI responsive

---

### 2. `ModelManager`

Handles first-time model download and local caching.

```swift
actor ModelManager {
    static let modelsDirectory: URL  // ~/Library/Application Support/TabRecord/Models/

    func ensureWhisperModel(_ variant: WhisperModelVariant) async throws -> URL
    func ensureSpeakerModel() async throws -> URL
    func downloadProgress(for model: ModelIdentifier) -> AsyncStream<Double>
    func deleteModel(_ model: ModelIdentifier) throws
    var installedModels: [ModelIdentifier]
}

enum WhisperModelVariant: String, CaseIterable {
    case largev3Turbo = "openai_whisper-large-v3-turbo"   // default, ~1.5 GB
    case largev3     = "openai_whisper-large-v3"           // ~3.1 GB, max accuracy
    case medium      = "openai_whisper-medium"              // ~700 MB, faster
    case small       = "openai_whisper-small"               // ~250 MB, fastest
}
```

**Model sources:**
- WhisperKit models: `argmaxinc/whisperkit-coreml` on HuggingFace (downloaded via WhisperKit's built-in `WhisperKit.download()` API — no manual HTTP needed)
- SpeakerKit models: `argmaxinc/speakerkit-coreml` via SpeakerKit's `SpeakerKit.download()` API

**Storage:** `~/Library/Application Support/TabRecord/Models/<variant>/`

---

### 3. `AudioPreprocessor`

Extracts the correct audio track from the MP4/M4A and prepares it for the ASR pipeline.

```swift
struct AudioPreprocessor {
    /// Extracts and resamples audio to 16kHz mono PCM (required by Whisper)
    func prepareForTranscription(
        source: AudioSource,
        recordingFiles: RecordingFiles
    ) async throws -> URL  // returns temp WAV file at 16kHz mono

    enum AudioSource {
        case speakerTrack    // default — track 2 (clean source audio)
        case micTrack        // track 3 (mic only)
        case mixedTrack      // track 1 (L=speaker, R=mic)
    }
}
```

**Implementation:** Uses `AVAssetReader` + `AVAssetReaderTrackOutput` to extract the correct track from the MP4, then `AVAudioConverter` to downsample to 16kHz mono PCM (Whisper's expected format). Output written to `FileManager.default.temporaryDirectory`.

---

### 4. `WhisperKitTranscriber`

Thin wrapper around `WhisperKit` SPM package.

```swift
actor WhisperKitTranscriber {
    private var whisperKit: WhisperKit?

    func load(modelPath: URL) async throws

    func transcribe(
        audioURL: URL,
        language: String?,                  // nil = auto-detect
        wordTimestamps: Bool = true
    ) async throws -> [WhisperSegment]

    struct WhisperSegment {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let words: [WordTimestamp]
        let language: String
        let avgLogprob: Float               // confidence proxy
    }

    struct WordTimestamp {
        let word: String
        let start: TimeInterval
        let end: TimeInterval
        let probability: Float
    }
}
```

**Key WhisperKit configuration:**
```swift
let config = WhisperKitConfig(
    model: modelPath,
    computeUnits: .cpuAndNeuralEngine,     // use ANE + CPU (not GPU for decoder)
    verbose: false,
    logLevel: .error
)
```

**Note on compute units:** WhisperKit's benchmark shows `cpuAndNeuralEngine` is fastest for encoder (ANE) + decoder (CPU) split on Apple Silicon. GPU is suboptimal for the autoregressive decoder.

---

### 5. `SpeakerKitDiarizer`

Thin wrapper around `SpeakerKit` SPM package.

```swift
actor SpeakerKitDiarizer {
    private var speakerKit: SpeakerKit?

    func load(modelPath: URL) async throws

    func diarize(
        audioURL: URL,
        numSpeakers: Int?                   // nil = auto-detect (1–8)
    ) async throws -> [DiarizationSegment]

    struct DiarizationSegment {
        let start: TimeInterval
        let end: TimeInterval
        let speakerLabel: String            // "SPEAKER_00", "SPEAKER_01", etc.
    }
}
```

**Implementation detail:** SpeakerKit runs pyannote v4's `SpeakerSegmentation` and `SpeakerEmbedding` models converted to CoreML. On M3 Max, diarization of a 60-minute recording takes ~12 seconds (RTF ~0.003x).

---

### 6. `SegmentAligner`

Merges word-level Whisper output with diarization segments to produce speaker-attributed text.

```swift
struct SegmentAligner {
    func align(
        whisperSegments: [WhisperKitTranscriber.WhisperSegment],
        diarizationSegments: [SpeakerKitDiarizer.DiarizationSegment]
    ) -> [AttributedSegment]

    struct AttributedSegment {
        let start: TimeInterval
        let end: TimeInterval
        let speaker: String
        let text: String
        let words: [AttributedWord]
    }

    struct AttributedWord {
        let word: String
        let start: TimeInterval
        let end: TimeInterval
        let speaker: String
        let probability: Float
    }
}
```

**Algorithm:**
1. For each Whisper word timestamp `[t_start, t_end]`, find the diarization segment with maximum overlap
2. Assign that segment's speaker label to the word
3. Group consecutive words with the same speaker into `AttributedSegment` blocks
4. Handle boundary cases: words spanning two speaker segments are assigned to the segment covering their midpoint

---

### 7. `TranscriptWriter`

Writes the three output formats to disk.

```swift
struct TranscriptWriter {
    func write(
        segments: [SegmentAligner.AttributedSegment],
        baseURL: URL,           // e.g. ~/Movies/TabRecord/tabrecord-2025-03-30-143022
        language: String,
        formats: Set<TranscriptFormat>
    ) throws -> [URL]

    enum TranscriptFormat: String, CaseIterable {
        case txt   // plain text with speaker labels
        case json  // structured with word timestamps
        case srt   // SubRip for video player subtitles
    }
}
```

**Output file naming (follows existing `OutputFileNamer` convention):**
- `tabrecord-YYYY-MM-DD-HHmmss-transcript.txt`
- `tabrecord-YYYY-MM-DD-HHmmss-transcript.json`
- `tabrecord-YYYY-MM-DD-HHmmss-transcript.srt`

**TXT format example:**
```
[00:00:03 → 00:00:12] SPEAKER_00:
Hello everyone, welcome to the meeting. Today we're going to discuss the quarterly results.

[00:00:13 → 00:00:28] SPEAKER_01:
Thanks for having me. I've prepared a summary of the key metrics we should cover.
```

**JSON schema:**
```json
{
  "language": "en",
  "duration": 3612.4,
  "speakers": ["SPEAKER_00", "SPEAKER_01"],
  "segments": [
    {
      "start": 3.2,
      "end": 12.1,
      "speaker": "SPEAKER_00",
      "text": "Hello everyone, welcome to the meeting.",
      "words": [
        { "word": "Hello", "start": 3.2, "end": 3.6, "probability": 0.98 }
      ]
    }
  ]
}
```

**SRT format:** Standard SRT with speaker label prepended to each subtitle block.

---

### 8. `TranscriptionPreferences`

```swift
final class TranscriptionPreferences: ObservableObject {
    @AppStorage("transcription.enabled")         var enabled: Bool = true
    @AppStorage("transcription.model")           var model: WhisperModelVariant = .largev3Turbo
    @AppStorage("transcription.language")        var language: String = ""     // "" = auto
    @AppStorage("transcription.numSpeakers")     var numSpeakers: Int = 0       // 0 = auto
    @AppStorage("transcription.audioSource")     var audioSource: AudioSource = .speakerTrack
    @AppStorage("transcription.formats.txt")     var writeTxt: Bool = true
    @AppStorage("transcription.formats.json")    var writeJson: Bool = true
    @AppStorage("transcription.formats.srt")     var writeSrt: Bool = true
}
```

---

### 9. `PreferencesView` (new SwiftUI view)

Adds a "Transcription" tab to the preferences panel, accessible from the menu bar "Preferences…" item.

```
┌─────────────────────────────────────────┐
│  TabRecord Preferences                  │
│  [Recording] [Transcription]            │
│─────────────────────────────────────────│
│  ✅ Auto-transcribe after recording      │
│                                         │
│  Model:    [Large v3 Turbo ▾]  (1.5 GB) │
│  Language: [Auto-detect ▾]              │
│  Speakers: [Auto-detect ▾]              │
│  Source:   [Speaker Audio ▾]            │
│                                         │
│  Output formats:                        │
│    ✅ Plain text (.txt)                  │
│    ✅ JSON with timestamps (.json)       │
│    ✅ Subtitles (.srt)                   │
│                                         │
│  Models:   1.5 GB used                  │
│            [Download Large v3…]         │
│            [Delete Unused Models…]      │
└─────────────────────────────────────────┘
```

---

## Data Flow

```
stopRecording()
    │
    ├── [existing] save MP4 + M4A files to ~/Movies/TabRecord/
    │
    └── [new] TranscriptionCoordinator.transcribe(recordingURL:)
            │
            ├── ModelManager.ensureWhisperModel(.largev3Turbo)
            │       └── if missing → download from HuggingFace (WhisperKit API)
            │               └── show progress in menu bar
            │
            ├── ModelManager.ensureSpeakerModel()
            │       └── if missing → download from HuggingFace (SpeakerKit API)
            │
            ├── AudioPreprocessor.prepareForTranscription(source: .speakerTrack)
            │       └── AVAssetReader → extract Track 2 → AVAudioConverter → 16kHz mono WAV
            │
            ├── WhisperKitTranscriber.transcribe(audioURL:language:wordTimestamps:true)
            │       └── WhisperKit CoreML pipeline
            │               ├── MelSpectrogram (CoreML)
            │               ├── AudioEncoder (CoreML → ANE)
            │               └── TextDecoder (CoreML → CPU)
            │
            ├── SpeakerKitDiarizer.diarize(audioURL:numSpeakers:)
            │       └── SpeakerKit CoreML pipeline
            │               ├── SpeakerSegmentation (CoreML → ANE)
            │               └── SpeakerEmbedding + clustering (CoreML → ANE)
            │
            ├── SegmentAligner.align(whisperSegments:diarizationSegments:)
            │
            ├── TranscriptWriter.write(segments:baseURL:formats:[.txt,.json,.srt])
            │
            └── UNUserNotificationCenter: "Transcript ready — tabrecord-2025-03-30-143022"
```

---

## Dependencies

### Swift Package Manager additions to `project.yml`

```yaml
packages:
  WhisperKit:
    url: https://github.com/argmaxinc/WhisperKit
    from: 0.9.0
  SpeakerKit:
    url: https://github.com/argmaxinc/SpeakerKit
    from: 0.1.0
```

**License review:**
- WhisperKit: MIT License ✅
- SpeakerKit: MIT License ✅
- Underlying Whisper models (OpenAI): MIT License ✅
- SpeakerKit models (pyannote v4 CoreML): MIT License ✅ (Argmax-converted)

---

## macOS Version Handling

| Feature | Minimum macOS |
|---|---|
| Recording (existing) | 13.0 (ScreenCaptureKit) |
| Transcription (new) | 14.0 (CoreML optimizations required by WhisperKit 0.9+) |

On macOS 13.0, the transcription menu items are hidden and a tooltip explains the 14.0 requirement. Recording continues to work normally.

```swift
// MenuBarController.swift
if #available(macOS 14.0, *) {
    menu.addItem(transcribeMenuItem)
} else {
    // Transcription not available on macOS 13
}
```

---

## Error Handling

| Error | Behavior |
|---|---|
| Model download fails (no network) | Show notification with retry button; transcription skipped for this recording |
| Insufficient disk space for models | Alert before download with space required vs. available |
| Audio extraction fails | Log error, show notification, preserve recording files |
| WhisperKit transcription error | Log error, attempt fallback to Apple SFSpeechRecognizer (no diarization) |
| SpeakerKit diarization error | Log error, output transcript without speaker labels (degrade gracefully) |
| Output directory not writable | Show notification, offer to choose alternate save location |

---

## Performance Targets (M3 Max)

| Step | Expected Duration (60 min audio) |
|---|---|
| Audio extraction (16kHz WAV) | ~5 seconds |
| WhisperKit transcription | ~3 minutes (RTF ~0.05x) |
| SpeakerKit diarization | ~12 seconds (RTF ~0.003x) |
| Alignment + file writing | < 1 second |
| **Total** | **~3.5 minutes** |

Peak memory: ~2.5 GB (WhisperKit large-v3-turbo encoder + decoder)

---

## Testing Plan

### Unit Tests

| Test | File |
|---|---|
| `SegmentAlignerTests` | Alignment of overlapping segments, boundary cases, empty inputs |
| `TranscriptWriterTests` | TXT/JSON/SRT format correctness, file naming convention |
| `AudioPreprocessorTests` | 16kHz mono conversion, track extraction from multi-track MP4 |
| `ModelManagerTests` | Cache hit/miss logic, path resolution, disk space check |

### Integration Tests

| Test | Description |
|---|---|
| Full pipeline test | Short WAV with known transcript → verify WER < 10% |
| Diarization test | Two-speaker audio → verify two distinct labels assigned |
| macOS 13 compatibility | Verify transcription UI hidden, recording still works |
| Large file test | 2-hour recording → verify completes without memory pressure |

### Manual Verification

- Record a 5-minute meeting with 2 speakers, verify TXT output has correct speaker changes
- Verify SRT subtitles sync correctly with video in QuickTime Player
- Verify notification fires on completion and tapping it reveals transcript in Finder
