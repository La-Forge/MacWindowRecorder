import Foundation
import XCTest

@testable import TabRecordApp

final class OutputFileNamerTests: XCTestCase {

    // MARK: - Helpers

    private func date(
        year: Int, month: Int, day: Int,
        hour: Int, minute: Int, second: Int
    ) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        comps.timeZone = TimeZone.current
        return Calendar.current.date(from: comps)!
    }

    // MARK: - File name format

    func testFileNameMatchesPattern() {
        let d = date(year: 2026, month: 3, day: 13, hour: 14, minute: 30, second: 5)

        let url = OutputFileNamer.makeURL(date: d)

        XCTAssertEqual(url.lastPathComponent, "tabrecord-2026-03-13-143005.mp4")
    }

    func testFileNameZeroPadsMonthAndDay() {
        let d = date(year: 2026, month: 1, day: 4, hour: 9, minute: 7, second: 3)

        let url = OutputFileNamer.makeURL(date: d)

        XCTAssertEqual(url.lastPathComponent, "tabrecord-2026-01-04-090703.mp4")
    }

    func testFileNameHasMp4Extension() {
        let url = OutputFileNamer.makeURL()

        XCTAssertEqual(url.pathExtension, "mp4")
    }

    func testFileNameStartsWithTabrecordPrefix() {
        let url = OutputFileNamer.makeURL()

        XCTAssertTrue(url.lastPathComponent.hasPrefix("tabrecord-"))
    }

    // MARK: - Directory

    func testDirectoryEndsWithMoviesTabRecord() {
        let dir = OutputFileNamer.recordingsDirectory()

        XCTAssertTrue(
            dir.path.hasSuffix("Movies/TabRecord"),
            "Expected path ending in Movies/TabRecord, got: \(dir.path)"
        )
    }

    func testMakeURLIsInsideRecordingsDirectory() {
        let dir = OutputFileNamer.recordingsDirectory()
        let url = OutputFileNamer.makeURL()

        XCTAssertTrue(
            url.path.hasPrefix(dir.path),
            "URL \(url.path) should be inside \(dir.path)"
        )
    }

    // MARK: - Uniqueness

    func testDifferentSecondsProduceDifferentURLs() {
        let d1 = date(year: 2026, month: 3, day: 13, hour: 10, minute: 0, second: 0)
        let d2 = date(year: 2026, month: 3, day: 13, hour: 10, minute: 0, second: 1)

        XCTAssertNotEqual(
            OutputFileNamer.makeURL(date: d1),
            OutputFileNamer.makeURL(date: d2)
        )
    }

    func testSameDateProducesSameURL() {
        let d = date(year: 2026, month: 3, day: 13, hour: 10, minute: 0, second: 0)

        XCTAssertEqual(
            OutputFileNamer.makeURL(date: d),
            OutputFileNamer.makeURL(date: d)
        )
    }

    // MARK: - Mic audio URL

    func testMicURLHasM4aExtension() {
        let url = OutputFileNamer.makeMicURL()

        XCTAssertEqual(url.pathExtension, "m4a")
    }

    func testMicURLContainsMicSuffix() {
        let d = date(year: 2026, month: 3, day: 13, hour: 14, minute: 30, second: 5)

        let url = OutputFileNamer.makeMicURL(date: d)

        XCTAssertEqual(url.lastPathComponent, "tabrecord-2026-03-13-143005-mic.m4a")
    }

    func testMicURLIsInsideRecordingsDirectory() {
        let dir = OutputFileNamer.recordingsDirectory()
        let url = OutputFileNamer.makeMicURL()

        XCTAssertTrue(
            url.path.hasPrefix(dir.path),
            "URL \(url.path) should be inside \(dir.path)"
        )
    }

    func testMicURLSharesTimestampWithVideoURL() {
        let d = date(year: 2026, month: 3, day: 13, hour: 14, minute: 30, second: 5)

        let videoURL = OutputFileNamer.makeURL(date: d)
        let micURL = OutputFileNamer.makeMicURL(date: d)

        // Both share the same timestamp prefix
        XCTAssertTrue(micURL.lastPathComponent.contains("2026-03-13-143005"))
        XCTAssertTrue(videoURL.lastPathComponent.contains("2026-03-13-143005"))
    }

    // MARK: - Speaker audio URL

    func testSpeakerURLHasM4aExtension() {
        let url = OutputFileNamer.makeSpeakerURL()

        XCTAssertEqual(url.pathExtension, "m4a")
    }

    func testSpeakerURLContainsSpeakerSuffix() {
        let d = date(year: 2026, month: 3, day: 13, hour: 14, minute: 30, second: 5)

        let url = OutputFileNamer.makeSpeakerURL(date: d)

        XCTAssertEqual(url.lastPathComponent, "tabrecord-2026-03-13-143005-speaker.m4a")
    }

    func testSpeakerURLIsInsideRecordingsDirectory() {
        let dir = OutputFileNamer.recordingsDirectory()
        let url = OutputFileNamer.makeSpeakerURL()

        XCTAssertTrue(
            url.path.hasPrefix(dir.path),
            "URL \(url.path) should be inside \(dir.path)"
        )
    }

    func testSpeakerURLSharesTimestampWithVideoURL() {
        let d = date(year: 2026, month: 3, day: 13, hour: 14, minute: 30, second: 5)

        let videoURL = OutputFileNamer.makeURL(date: d)
        let speakerURL = OutputFileNamer.makeSpeakerURL(date: d)

        XCTAssertTrue(speakerURL.lastPathComponent.contains("2026-03-13-143005"))
        XCTAssertTrue(videoURL.lastPathComponent.contains("2026-03-13-143005"))
    }
}
