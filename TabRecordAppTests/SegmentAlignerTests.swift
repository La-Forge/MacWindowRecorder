import XCTest
@testable import TabRecordApp

final class SegmentAlignerTests: XCTestCase {

    private let aligner = SegmentAligner()

    // MARK: - Helpers

    private func makeWord(
        _ text: String,
        start: Double,
        end: Double,
        prob: Float = 0.95
    ) -> WhisperKitTranscriber.WordTimestamp {
        WhisperKitTranscriber.WordTimestamp(word: text, start: start, end: end, probability: prob)
    }

    private func makeSegment(
        start: Double,
        end: Double,
        words: [WhisperKitTranscriber.WordTimestamp]
    ) -> WhisperKitTranscriber.WhisperSegment {
        WhisperKitTranscriber.WhisperSegment(
            start: start, end: end,
            text: words.map(\.word).joined(),
            words: words,
            language: "en",
            avgLogprob: -0.2
        )
    }

    private func makeDiarSeg(
        _ label: String,
        start: Double,
        end: Double
    ) -> SpeakerKitDiarizer.DiarizationSegment {
        SpeakerKitDiarizer.DiarizationSegment(start: start, end: end, speakerLabel: label)
    }

    // MARK: - Empty inputs

    func testEmptyWhisperSegmentsReturnsEmpty() {
        let result = aligner.align(whisperSegments: [], diarizationSegments: [
            makeDiarSeg("SPEAKER_00", start: 0, end: 10)
        ])
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyDiarizationReturnsUnknownSpeaker() {
        let words = [makeWord("Hello", start: 0, end: 1)]
        let result = aligner.align(
            whisperSegments: [makeSegment(start: 0, end: 1, words: words)],
            diarizationSegments: []
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speaker, SegmentAligner.unknownSpeaker)
        XCTAssertEqual(result[0].text, "Hello")
    }

    func testBothEmptyReturnsEmpty() {
        let result = aligner.align(whisperSegments: [], diarizationSegments: [])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Single speaker

    func testSingleSpeakerMergedIntoOneSegment() {
        let words = [
            makeWord("Hello", start: 0.0, end: 0.5),
            makeWord(" world", start: 0.6, end: 1.1),
        ]
        let diar = [makeDiarSeg("SPEAKER_00", start: 0, end: 5)]
        let result = aligner.align(
            whisperSegments: [makeSegment(start: 0, end: 1.1, words: words)],
            diarizationSegments: diar
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speaker, "SPEAKER_00")
        XCTAssertEqual(result[0].words.count, 2)
    }

    // MARK: - Two speakers interleaved

    func testBasicTwoSpeakerAssignment() {
        let words = [
            makeWord("Hello", start: 0.0, end: 0.5),   // midpoint 0.25 → SPEAKER_00
            makeWord(" there", start: 0.6, end: 1.1),   // midpoint 0.85 → SPEAKER_00
            makeWord(" Hi", start: 5.0, end: 5.4),      // midpoint 5.2  → SPEAKER_01
            makeWord(" back", start: 5.5, end: 6.0),    // midpoint 5.75 → SPEAKER_01
        ]
        let diar = [
            makeDiarSeg("SPEAKER_00", start: 0, end: 3),
            makeDiarSeg("SPEAKER_01", start: 4, end: 8),
        ]
        let result = aligner.align(
            whisperSegments: [makeSegment(start: 0, end: 6, words: words)],
            diarizationSegments: diar
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].speaker, "SPEAKER_00")
        XCTAssertEqual(result[1].speaker, "SPEAKER_01")
    }

    // MARK: - Boundary word

    func testWordAtExactBoundaryUsedMidpoint() {
        // Word spans the exact boundary between two speaker segments (2–3s).
        // midpoint = 2.5, which falls in SPEAKER_01 [2, 4].
        let word = makeWord("boundary", start: 2.0, end: 3.0)
        let diar = [
            makeDiarSeg("SPEAKER_00", start: 0, end: 2),
            makeDiarSeg("SPEAKER_01", start: 2, end: 4),
        ]
        let result = aligner.align(
            whisperSegments: [makeSegment(start: 2, end: 3, words: [word])],
            diarizationSegments: diar
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speaker, "SPEAKER_01")
    }

    // MARK: - Word outside diarization coverage

    func testWordAfterLastSegmentGetsNearestSpeaker() {
        // Diarization ends at t=5 but word is at t=8.
        let word = makeWord("late", start: 8.0, end: 8.5)
        let diar = [
            makeDiarSeg("SPEAKER_00", start: 0, end: 5),
        ]
        let result = aligner.align(
            whisperSegments: [makeSegment(start: 8, end: 8.5, words: [word])],
            diarizationSegments: diar
        )
        XCTAssertEqual(result.count, 1)
        // Should be assigned to the only available speaker (nearest boundary).
        XCTAssertEqual(result[0].speaker, "SPEAKER_00")
    }

    // MARK: - Segment grouping

    func testAlternatingSpeakersProduceAlternatingSegments() {
        let words = [
            makeWord("A", start: 0, end: 1),  // SPEAKER_00
            makeWord("B", start: 2, end: 3),  // SPEAKER_01
            makeWord("C", start: 4, end: 5),  // SPEAKER_00
        ]
        let diar = [
            makeDiarSeg("SPEAKER_00", start: 0, end: 1.5),
            makeDiarSeg("SPEAKER_01", start: 1.5, end: 3.5),
            makeDiarSeg("SPEAKER_00", start: 3.5, end: 6),
        ]
        let result = aligner.align(
            whisperSegments: [makeSegment(start: 0, end: 5, words: words)],
            diarizationSegments: diar
        )
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].speaker, "SPEAKER_00")
        XCTAssertEqual(result[1].speaker, "SPEAKER_01")
        XCTAssertEqual(result[2].speaker, "SPEAKER_00")
    }

    func testSegmentTimestampsMatchFirstAndLastWord() {
        let words = [
            makeWord("Hello", start: 1.0, end: 1.5),
            makeWord(" world", start: 1.6, end: 2.0),
        ]
        let diar = [makeDiarSeg("SPEAKER_00", start: 0, end: 10)]
        let result = aligner.align(
            whisperSegments: [makeSegment(start: 1, end: 2, words: words)],
            diarizationSegments: diar
        )
        XCTAssertEqual(result[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(result[0].end, 2.0, accuracy: 0.001)
    }

    // MARK: - Text content

    func testSegmentTextIsConcatenatedWords() {
        let words = [
            makeWord("Hello", start: 0, end: 0.5),
            makeWord(" world", start: 0.6, end: 1.1),
        ]
        let result = aligner.align(
            whisperSegments: [makeSegment(start: 0, end: 1.1, words: words)],
            diarizationSegments: [makeDiarSeg("SPEAKER_00", start: 0, end: 5)]
        )
        XCTAssertEqual(result[0].text, "Hello world")
    }
}
