import Foundation

// MARK: - SegmentAligner

/// Merges word-level Whisper output with speaker diarization segments to
/// produce a speaker-attributed transcript.
///
/// **Algorithm:** For each word, the midpoint `(start + end) / 2` is compared
/// against every diarization segment. The diarization segment with maximum
/// overlap around the midpoint is chosen. If no segment covers the midpoint,
/// the nearest segment boundary is used.
///
/// Consecutive words assigned to the same speaker are grouped into a single
/// `AttributedSegment`.
struct SegmentAligner {

    static let unknownSpeaker = "SPEAKER_UNKNOWN"

    // MARK: - Output types

    struct AttributedWord {
        let word: String
        let start: TimeInterval
        let end: TimeInterval
        let speaker: String
        let probability: Float
    }

    struct AttributedSegment {
        let start: TimeInterval
        let end: TimeInterval
        let speaker: String
        let text: String
        let words: [AttributedWord]
    }

    // MARK: - Public API

    /// Aligns transcription segments with diarization segments.
    ///
    /// - Parameters:
    ///   - whisperSegments: Word-timestamped output from `WhisperKitTranscriber`.
    ///   - diarizationSegments: Speaker-labeled time ranges from `SpeakerKitDiarizer`.
    /// - Returns: Speaker-attributed segments, sorted by start time.
    func align(
        whisperSegments: [WhisperKitTranscriber.WhisperSegment],
        diarizationSegments: [SpeakerKitDiarizer.DiarizationSegment]
    ) -> [AttributedSegment] {
        // Flatten all words from all Whisper segments.
        let allWords: [WhisperKitTranscriber.WordTimestamp] = whisperSegments.flatMap { $0.words }
        guard !allWords.isEmpty else { return [] }

        // Assign a speaker to every word.
        let attributed: [AttributedWord] = allWords.map { word in
            let speaker = assignSpeaker(to: word, from: diarizationSegments)
            return AttributedWord(
                word: word.word,
                start: word.start,
                end: word.end,
                speaker: speaker,
                probability: word.probability
            )
        }

        // Group consecutive words with the same speaker into segments.
        return groupIntoSegments(attributed)
    }

    // MARK: - Private

    private func assignSpeaker(
        to word: WhisperKitTranscriber.WordTimestamp,
        from segments: [SpeakerKitDiarizer.DiarizationSegment]
    ) -> String {
        guard !segments.isEmpty else { return Self.unknownSpeaker }

        let midpoint = (word.start + word.end) / 2.0

        // Find the segment whose range contains the midpoint.
        if let covering = segments.first(where: { $0.start <= midpoint && midpoint < $0.end }) {
            return covering.speakerLabel
        }

        // No exact cover — find the nearest segment by closest boundary distance.
        let nearest = segments.min { a, b in
            let distA = min(abs(a.start - midpoint), abs(a.end - midpoint))
            let distB = min(abs(b.start - midpoint), abs(b.end - midpoint))
            return distA < distB
        }
        return nearest?.speakerLabel ?? Self.unknownSpeaker
    }

    private func groupIntoSegments(_ words: [AttributedWord]) -> [AttributedSegment] {
        guard !words.isEmpty else { return [] }

        var segments: [AttributedSegment] = []
        var currentSpeaker = words[0].speaker
        var currentWords: [AttributedWord] = [words[0]]

        for word in words.dropFirst() {
            if word.speaker == currentSpeaker {
                currentWords.append(word)
            } else {
                segments.append(makeSegment(speaker: currentSpeaker, words: currentWords))
                currentSpeaker = word.speaker
                currentWords = [word]
            }
        }
        // Flush final group.
        segments.append(makeSegment(speaker: currentSpeaker, words: currentWords))
        return segments
    }

    private func makeSegment(speaker: String, words: [AttributedWord]) -> AttributedSegment {
        let text = words.map { $0.word }.joined().trimmingCharacters(in: .whitespaces)
        return AttributedSegment(
            start: words.first!.start,
            end: words.last!.end,
            speaker: speaker,
            text: text,
            words: words
        )
    }
}
