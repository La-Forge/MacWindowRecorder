import Foundation
import SpeakerKit

// MARK: - Output types

extension SpeakerKitDiarizer {

    struct DiarizationSegment {
        let start: TimeInterval
        let end: TimeInterval
        /// Consistent label for this speaker across the full recording, e.g. "SPEAKER_00".
        let speakerLabel: String
    }
}

// MARK: - SpeakerKitDiarizer

/// Thin actor wrapper around the SpeakerKit SPM package.
///
/// SpeakerKit runs pyannote v4 speaker segmentation and embedding models
/// converted to CoreML, fully on-device. On M3 Max it achieves an RTF of
/// ~0.003x (a 60-minute recording is diarized in ~12 seconds).
actor SpeakerKitDiarizer {

    private var speakerKit: SpeakerKit?

    // MARK: - Lifecycle

    /// Loads the model from a local directory produced by `ModelManager`.
    func load(modelFolder: URL) async throws {
        speakerKit = try await SpeakerKit(modelFolder: modelFolder.path)
    }

    // MARK: - Diarization

    /// Returns speaker-labeled time segments for the audio at `audioURL`.
    ///
    /// - Parameters:
    ///   - audioURL: Path to a 16 kHz mono Float32 WAV file (same file used for ASR).
    ///   - numSpeakers: Expected number of speakers. Pass `nil` for auto-detection (1–8).
    func diarize(
        audioURL: URL,
        numSpeakers: Int?
    ) async throws -> [DiarizationSegment] {
        guard let kit = speakerKit else {
            throw TranscriptionError.diarizationModelNotLoaded
        }

        let hint: SpeakerCountHint = numSpeakers.flatMap { n in
            n > 0 ? .exact(n) : nil
        } ?? .auto

        let results: [SpeakerSegment] = try await kit.diarize(
            audioPath: audioURL.path,
            speakerCount: hint
        )

        return results.enumerated().map { idx, segment in
            DiarizationSegment(
                start: segment.startTime,
                end: segment.endTime,
                speakerLabel: formattedLabel(for: segment.speakerID)
            )
        }
    }

    // MARK: - Private

    /// Converts a SpeakerKit integer speaker ID to a stable "SPEAKER_XX" label.
    private func formattedLabel(for speakerID: Int) -> String {
        String(format: "SPEAKER_%02d", speakerID)
    }
}
