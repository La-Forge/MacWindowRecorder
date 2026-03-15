import AVFoundation
import CoreMedia
import XCTest

@testable import TabRecordApp

final class CMTimeConverterTests: XCTestCase {

    // MARK: - Host time (primary path)

    func testHostTimeIsConvertedToNanosecondTimescale() {
        let audioTime = AVAudioTime(hostTime: 1_000_000_000)

        let result = CMTimeConverter.cmTime(from: audioTime, sampleRate: 48000)

        XCTAssertEqual(result.timescale, 1_000_000_000)
    }

    func testHostTimeMatchesMachConversion() {
        // The function must apply the same mach_timebase_info conversion as the
        // system clock so that mic timestamps align with SCStream video frames.
        let hostTime: UInt64 = 500_000_000
        let audioTime = AVAudioTime(hostTime: hostTime)

        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let expectedNanos = hostTime * UInt64(info.numer) / UInt64(info.denom)
        let expected = CMTime(value: CMTimeValue(expectedNanos), timescale: 1_000_000_000)

        let result = CMTimeConverter.cmTime(from: audioTime, sampleRate: 48000)

        XCTAssertEqual(result, expected)
    }

    func testZeroHostTimeProducesZeroCMTime() {
        let audioTime = AVAudioTime(hostTime: 0)

        let result = CMTimeConverter.cmTime(from: audioTime, sampleRate: 48000)

        XCTAssertEqual(result.seconds, 0)
    }

    // MARK: - Sample time (fallback path)

    func testSampleTimeUsedWhenHostTimeUnavailable() {
        // AVAudioTime(sampleTime:atRate:) sets isSampleTimeValid = true,
        // isHostTimeValid = false.
        let audioTime = AVAudioTime(sampleTime: 48_000, atRate: 48_000)  // exactly 1 s

        let result = CMTimeConverter.cmTime(from: audioTime, sampleRate: 48_000)

        XCTAssertEqual(result.seconds, 1.0, accuracy: 1e-9)
    }

    func testSampleTimeUsesCorrectTimescale() {
        let sampleRate = 44_100.0
        let audioTime = AVAudioTime(sampleTime: 44_100, atRate: sampleRate)

        let result = CMTimeConverter.cmTime(from: audioTime, sampleRate: sampleRate)

        XCTAssertEqual(result.timescale, CMTimeScale(sampleRate))
        XCTAssertEqual(result.value, 44_100)
    }

    // MARK: - Host time preferred over sample time

    func testHostTimePreferredWhenBothValid() {
        // AVAudioTime(hostTime:sampleTime:atRate:) sets both flags to true.
        let hostTime: UInt64 = 999_000_000
        let audioTime = AVAudioTime(hostTime: hostTime, sampleTime: 48_000, atRate: 48_000)
        XCTAssertTrue(audioTime.isHostTimeValid)
        XCTAssertTrue(audioTime.isSampleTimeValid)

        let result = CMTimeConverter.cmTime(from: audioTime, sampleRate: 48_000)

        // Must use nanosecond timescale (host time path), not 48 000 (sample time path).
        XCTAssertEqual(result.timescale, 1_000_000_000)
    }

    // MARK: - cmTimeFromHostTime (unit helper)

    func testCmTimeFromHostTimeIsMonotonic() {
        let t1 = CMTimeConverter.cmTimeFromHostTime(1_000_000)
        let t2 = CMTimeConverter.cmTimeFromHostTime(2_000_000)

        XCTAssertLessThan(t1, t2)
    }
}
