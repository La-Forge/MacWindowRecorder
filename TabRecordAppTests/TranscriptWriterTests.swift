import XCTest
@testable import TabRecordApp

final class TranscriptWriterTests: XCTestCase {

    private let writer = TranscriptWriter()

    // MARK: - Helpers

    private func makeWord(
        _ text: String,
        start: Double,
        end: Double,
        speaker: String = "SPEAKER_00"
    ) -> SegmentAligner.AttributedWord {
        SegmentAligner.AttributedWord(
            word: text, start: start, end: end, speaker: speaker, probability: 0.95
        )
    }

    private func makeSegment(
        speaker: String,
        text: String,
        start: Double,
        end: Double,
        words: [SegmentAligner.AttributedWord] = []
    ) -> SegmentAligner.AttributedSegment {
        SegmentAligner.AttributedSegment(
            start: start, end: end, speaker: speaker, text: text, words: words
        )
    }

    // MARK: - TXT format

    func testTxtFormatContainsSpeakerLabel() {
        let seg = makeSegment(speaker: "SPEAKER_00", text: "Hello world", start: 0, end: 2)
        let txt = writer.formatTxt(segments: [seg])
        XCTAssertTrue(txt.contains("SPEAKER_00"))
        XCTAssertTrue(txt.contains("Hello world"))
    }

    func testTxtFormatTimestampHeader() {
        let seg = makeSegment(speaker: "SPEAKER_01", text: "Test", start: 65, end: 70)
        let txt = writer.formatTxt(segments: [seg])
        // 65 seconds = 00:01:05
        XCTAssertTrue(txt.contains("00:01:05"), "Expected timestamp 00:01:05, got: \(txt)")
    }

    func testTxtFormatEmptySegments() {
        XCTAssertEqual(writer.formatTxt(segments: []), "")
    }

    func testTxtFormatMultipleSpeakers() {
        let segs = [
            makeSegment(speaker: "SPEAKER_00", text: "Hello", start: 0, end: 1),
            makeSegment(speaker: "SPEAKER_01", text: "Hi there", start: 2, end: 4),
        ]
        let txt = writer.formatTxt(segments: segs)
        XCTAssertTrue(txt.contains("SPEAKER_00"))
        XCTAssertTrue(txt.contains("SPEAKER_01"))
        XCTAssertTrue(txt.contains("Hello"))
        XCTAssertTrue(txt.contains("Hi there"))
    }

    func testTxtFormatSeparatesBlocksWithBlankLine() {
        let segs = [
            makeSegment(speaker: "SPEAKER_00", text: "A", start: 0, end: 1),
            makeSegment(speaker: "SPEAKER_01", text: "B", start: 2, end: 3),
        ]
        let txt = writer.formatTxt(segments: segs)
        // There should be a blank line between blocks.
        XCTAssertTrue(txt.contains("\n\n"))
    }

    // MARK: - JSON format

    func testJsonFormatContainsRequiredTopLevelKeys() throws {
        let seg = makeSegment(speaker: "SPEAKER_00", text: "Hello", start: 0, end: 1, words: [
            makeWord("Hello", start: 0, end: 1)
        ])
        let data = try writer.formatJSON(segments: [seg], language: "en")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["language"])
        XCTAssertNotNil(json["duration"])
        XCTAssertNotNil(json["speakers"])
        XCTAssertNotNil(json["segments"])
    }

    func testJsonFormatLanguageField() throws {
        let data = try writer.formatJSON(segments: [], language: "fr")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["language"] as? String, "fr")
    }

    func testJsonFormatSpeakersListIsSorted() throws {
        let segs = [
            makeSegment(speaker: "SPEAKER_01", text: "B", start: 0, end: 1),
            makeSegment(speaker: "SPEAKER_00", text: "A", start: 2, end: 3),
        ]
        let data = try writer.formatJSON(segments: segs, language: "en")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let speakers = try XCTUnwrap(json["speakers"] as? [String])
        XCTAssertEqual(speakers, ["SPEAKER_00", "SPEAKER_01"])
    }

    func testJsonFormatSegmentStructure() throws {
        let seg = makeSegment(speaker: "SPEAKER_00", text: "Hello", start: 1.5, end: 2.5, words: [
            makeWord("Hello", start: 1.5, end: 2.5)
        ])
        let data = try writer.formatJSON(segments: [seg], language: "en")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let segments = try XCTUnwrap(json["segments"] as? [[String: Any]])
        let first = try XCTUnwrap(segments.first)
        XCTAssertEqual(first["speaker"] as? String, "SPEAKER_00")
        XCTAssertEqual(first["text"] as? String, "Hello")
        XCTAssertEqual(first["start"] as? Double ?? 0, 1.5, accuracy: 0.001)
    }

    func testJsonFormatDurationMatchesLastSegmentEnd() throws {
        let segs = [
            makeSegment(speaker: "SPEAKER_00", text: "A", start: 0, end: 10),
            makeSegment(speaker: "SPEAKER_01", text: "B", start: 11, end: 30.5),
        ]
        let data = try writer.formatJSON(segments: segs, language: "en")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["duration"] as? Double ?? 0, 30.5, accuracy: 0.001)
    }

    // MARK: - SRT format

    func testSrtFormatContainsSrtIndex() {
        let seg = makeSegment(speaker: "SPEAKER_00", text: "Hello", start: 0, end: 1, words: [
            makeWord("Hello", start: 0, end: 1)
        ])
        let srt = writer.formatSRT(segments: [seg])
        XCTAssertTrue(srt.hasPrefix("1\n"))
    }

    func testSrtFormatTimecodeArrow() {
        let seg = makeSegment(speaker: "SPEAKER_00", text: "Hello", start: 0, end: 1, words: [
            makeWord("Hello", start: 0, end: 1)
        ])
        let srt = writer.formatSRT(segments: [seg])
        XCTAssertTrue(srt.contains("-->"))
    }

    func testSrtFormatTimecodeHasMilliseconds() {
        let seg = makeSegment(speaker: "SPEAKER_00", text: "Hello", start: 1.5, end: 2.75, words: [
            makeWord("Hello", start: 1.5, end: 2.75)
        ])
        let srt = writer.formatSRT(segments: [seg])
        // SRT uses comma for milliseconds: 00:00:01,500
        XCTAssertTrue(srt.contains(",500") || srt.contains(",750"), "Got: \(srt)")
    }

    func testSrtFormatIncludesSpeakerLabel() {
        let seg = makeSegment(speaker: "SPEAKER_02", text: "Hi", start: 0, end: 1, words: [
            makeWord("Hi", start: 0, end: 1)
        ])
        let srt = writer.formatSRT(segments: [seg])
        XCTAssertTrue(srt.contains("SPEAKER_02"))
    }

    func testSrtFormatEmptySegments() {
        XCTAssertEqual(writer.formatSRT(segments: []), "")
    }

    // MARK: - Timestamp formatting

    func testFormatTimestampZero() {
        XCTAssertEqual(writer.formatTimestamp(0), "00:00:00")
    }

    func testFormatTimestamp3661() {
        // 3661 seconds = 1 hour, 1 minute, 1 second
        XCTAssertEqual(writer.formatTimestamp(3661), "01:01:01")
    }

    func testSrtTimecodeMilliseconds() {
        XCTAssertEqual(writer.srtTimecode(1.5), "00:00:01,500")
        XCTAssertEqual(writer.srtTimecode(3600.0), "01:00:00,000")
    }

    // MARK: - File naming

    func testTranscriptURLMatchesConvention() {
        let components = DateComponents(
            calendar: .current,
            year: 2026, month: 3, day: 30,
            hour: 14, minute: 30, second: 5
        )
        let date = Calendar.current.date(from: components)!
        let url = OutputFileNamer.makeTranscriptURL(date: date, ext: "txt")
        XCTAssertEqual(url.lastPathComponent, "tabrecord-2026-03-30-143005-transcript.txt")
    }

    func testTranscriptURLJsonExtension() {
        let url = OutputFileNamer.makeTranscriptURL(ext: "json")
        XCTAssertEqual(url.pathExtension, "json")
        XCTAssertTrue(url.lastPathComponent.contains("-transcript."))
    }
}
