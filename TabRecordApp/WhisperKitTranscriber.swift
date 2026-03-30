import Foundation
import WhisperKit

// MARK: - Output types

extension WhisperKitTranscriber {

    struct WordTimestamp {
        let word: String
        let start: TimeInterval
        let end: TimeInterval
        let probability: Float
    }

    struct WhisperSegment {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        let words: [WordTimestamp]
        /// ISO 639-1 language code detected or provided (e.g. "en", "fr").
        let language: String
        /// Average log-probability across tokens — rough confidence proxy.
        let avgLogprob: Float
    }
}

// MARK: - WhisperKitTranscriber

/// Thin actor wrapper around the WhisperKit SPM package.
///
/// Uses `cpuAndNeuralEngine` compute units to maximise throughput on Apple Silicon:
/// the encoder runs on the ANE while the autoregressive decoder runs on the CPU,
/// which is the optimal split for M-series chips.
actor WhisperKitTranscriber {

    private var whisperKit: WhisperKit?

    // MARK: - Lifecycle

    /// Loads the model from a local directory produced by `ModelManager`.
    func load(modelFolder: URL) async throws {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            computeUnits: .cpuAndNeuralEngine,
            verbose: false,
            logLevel: .error
        )
        whisperKit = try await WhisperKit(config)
    }

    // MARK: - Transcription

    /// Transcribes the WAV file at `audioURL` and returns word-timestamped segments.
    ///
    /// - Parameters:
    ///   - audioURL: Path to a 16 kHz mono Float32 WAV file.
    ///   - language: ISO 639-1 code (e.g. `"en"`). Pass `nil` for auto-detection.
    func transcribe(
        audioURL: URL,
        language: String?
    ) async throws -> [WhisperSegment] {
        guard let kit = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        let options = DecodingOptions(
            language: language?.isEmpty == false ? language : nil,
            withoutTimestamps: false,
            wordTimestamps: true
        )

        let results: [TranscriptionResult] = try await kit.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options
        )

        return results.flatMap { result in
            result.segments.map { segment in
                let wordTimestamps: [WordTimestamp] = (segment.words ?? []).map { w in
                    WordTimestamp(
                        word: w.word,
                        start: TimeInterval(w.start),
                        end: TimeInterval(w.end),
                        probability: w.probability
                    )
                }
                return WhisperSegment(
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end),
                    text: segment.text.trimmingCharacters(in: .whitespaces),
                    words: wordTimestamps,
                    language: result.language ?? "en",
                    avgLogprob: segment.avgLogprob ?? -1.0
                )
            }
        }
    }
}

// MARK: - TranscriptionError

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case diarizationModelNotLoaded
    case audioPreparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model is not loaded. Call load(modelFolder:) first."
        case .diarizationModelNotLoaded:
            return "SpeakerKit model is not loaded. Call load(modelFolder:) first."
        case .audioPreparationFailed(let msg):
            return "Audio preparation failed: \(msg)"
        }
    }
}
