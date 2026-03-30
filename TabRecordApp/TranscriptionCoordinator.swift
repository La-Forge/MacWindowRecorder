import Foundation
import UserNotifications

// MARK: - TranscriptionState

enum TranscriptionState: Equatable {
    case idle
    case preparingModel
    case transcribing(progress: Double)
    case diarizing
    case aligning
    case writing
    case completed(transcriptURLs: [URL])
    case failed(String)

    static func == (lhs: TranscriptionState, rhs: TranscriptionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.preparingModel, .preparingModel),
             (.aligning, .aligning),
             (.writing, .writing):
            return true
        case (.transcribing(let a), .transcribing(let b)): return a == b
        case (.diarizing, .diarizing):                     return true
        case (.completed(let a), .completed(let b)):       return a == b
        case (.failed(let a), .failed(let b)):             return a == b
        default:                                           return false
        }
    }

    var isActive: Bool {
        switch self {
        case .idle, .completed, .failed: return false
        default: return true
        }
    }
}

// MARK: - TranscriptionCoordinator

/// Orchestrates the full transcription pipeline:
/// model download → audio prep → ASR → diarization → alignment → file output.
///
/// All published state changes occur on the main actor; the heavy pipeline
/// work runs on a background `Task` at `.utility` priority.
@MainActor
final class TranscriptionCoordinator: ObservableObject {

    @Published private(set) var state: TranscriptionState = .idle

    private let modelManager  = ModelManager()
    private let preprocessor  = AudioPreprocessor()
    private let aligner       = SegmentAligner()
    private let writer        = TranscriptWriter()

    private var transcriber   = WhisperKitTranscriber()
    private var diarizer      = SpeakerKitDiarizer()

    private var pipelineTask: Task<Void, Never>?

    // MARK: - Public API

    /// Starts the transcription pipeline for a completed recording.
    ///
    /// Calling this while a transcription is already running cancels the
    /// previous one first.
    func transcribe(
        recordingFiles: RecordingFiles,
        preferences: TranscriptionPreferences
    ) {
        pipelineTask?.cancel()
        pipelineTask = Task(priority: .utility) { [weak self] in
            await self?.runPipeline(recordingFiles: recordingFiles, preferences: preferences)
        }
    }

    /// Cancels any in-progress transcription.
    func cancel() {
        pipelineTask?.cancel()
        pipelineTask = nil
        state = .idle
    }

    // MARK: - Pipeline

    private func runPipeline(
        recordingFiles: RecordingFiles,
        preferences: TranscriptionPreferences
    ) async {
        var preparedAudioURL: URL?
        defer {
            // Always clean up the temp WAV file.
            if let url = preparedAudioURL {
                try? FileManager.default.removeItem(at: url)
            }
        }

        do {
            // 1. Ensure models are downloaded.
            state = .preparingModel
            let whisperModelURL = try await modelManager.ensureWhisperModel(preferences.model)
            let speakerModelURL = try await modelManager.ensureSpeakerModel()

            guard !Task.isCancelled else { state = .idle; return }

            // 2. Load models (lazy — no-op if already loaded).
            try await transcriber.load(modelFolder: whisperModelURL)
            try await diarizer.load(modelFolder: speakerModelURL)

            guard !Task.isCancelled else { state = .idle; return }

            // 3. Extract and resample audio to 16 kHz mono WAV.
            let audioURL = try await preprocessor.prepareForTranscription(
                source: preferences.audioSource,
                recordingFiles: recordingFiles
            )
            preparedAudioURL = audioURL

            guard !Task.isCancelled else { state = .idle; return }

            // 4. Transcribe with WhisperKit.
            state = .transcribing(progress: 0.0)
            let languageHint: String? = preferences.language.isEmpty ? nil : preferences.language
            let whisperSegments = try await transcriber.transcribe(
                audioURL: audioURL,
                language: languageHint
            )

            guard !Task.isCancelled else { state = .idle; return }

            // 5. Speaker diarization.
            state = .diarizing
            let numSpeakers: Int? = preferences.numSpeakers > 0 ? preferences.numSpeakers : nil
            let diarizationSegments = try await diarizer.diarize(
                audioURL: audioURL,
                numSpeakers: numSpeakers
            )

            guard !Task.isCancelled else { state = .idle; return }

            // 6. Merge transcription with diarization.
            state = .aligning
            let attributed = aligner.align(
                whisperSegments: whisperSegments,
                diarizationSegments: diarizationSegments
            )

            guard !Task.isCancelled else { state = .idle; return }

            // 7. Write output files.
            state = .writing
            let detectedLanguage = whisperSegments.first?.language ?? "en"
            let urls = try writer.write(
                segments: attributed,
                date: recordingFiles.date,
                language: languageHint ?? detectedLanguage,
                formats: preferences.outputFormats
            )

            // 8. Done.
            state = .completed(transcriptURLs: urls)
            scheduleCompletionNotification(transcriptURLs: urls)

        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
            scheduleFailureNotification(message: error.localizedDescription)
        }
    }

    // MARK: - Notifications

    private func scheduleCompletionNotification(transcriptURLs: [URL]) {
        let content = UNMutableNotificationContent()
        content.title = "Transcript Ready"
        if let first = transcriptURLs.first {
            content.body = first.lastPathComponent
        }
        content.categoryIdentifier = NotificationCategory.transcriptionComplete
        // Store all URLs as comma-separated paths in userInfo for the action handler.
        content.userInfo = ["urls": transcriptURLs.map(\.path).joined(separator: "\n")]
        let request = UNNotificationRequest(
            identifier: "transcription-complete-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func scheduleFailureNotification(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcription Failed"
        content.body = message
        content.categoryIdentifier = NotificationCategory.transcriptionFailed
        let request = UNNotificationRequest(
            identifier: "transcription-failed-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - Notification category constants

enum NotificationCategory {
    static let transcriptionComplete = "TRANSCRIPTION_COMPLETE"
    static let transcriptionFailed   = "TRANSCRIPTION_FAILED"
}

enum NotificationAction {
    static let showInFinder = "SHOW_IN_FINDER"
    static let retry        = "RETRY"
}
