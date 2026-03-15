import AVFoundation
import CoreMedia
import XCTest

@testable import TabRecordApp

final class AVAudioPCMBufferTests: XCTestCase {

    // MARK: - Helpers

    private func makeBuffer(
        sampleRate: Double = 48_000,
        channels: AVAudioChannelCount = 1,
        frameLength: AVAudioFrameCount = 1024
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)!
        buffer.frameLength = frameLength
        return buffer
    }

    // MARK: - Nil / non-nil contract

    func testValidBufferReturnsNonNil() {
        let buffer = makeBuffer()
        let pts = CMTime.zero

        let result = buffer.cmSampleBuffer(presentationTime: pts)

        XCTAssertNotNil(result)
    }

    func testEmptyBufferReturnsNil() {
        // frameLength == 0 → no samples → CMSampleBuffer cannot be created.
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 0

        let result = buffer.cmSampleBuffer(presentationTime: .zero)

        XCTAssertNil(result)
    }

    // MARK: - Frame count

    func testSampleCountMatchesFrameLength() {
        let frameLength: AVAudioFrameCount = 512
        let buffer = makeBuffer(frameLength: frameLength)

        let result = buffer.cmSampleBuffer(presentationTime: .zero)!

        XCTAssertEqual(CMSampleBufferGetNumSamples(result), Int(frameLength))
    }

    func testDifferentFrameLengthsProduceCorrectSampleCount() {
        for length: AVAudioFrameCount in [128, 256, 1024, 4096] {
            let buffer = makeBuffer(frameLength: length)
            let result = buffer.cmSampleBuffer(presentationTime: .zero)!
            XCTAssertEqual(
                CMSampleBufferGetNumSamples(result), Int(length),
                "frameLength=\(length)"
            )
        }
    }

    // MARK: - Presentation time

    func testPresentationTimeIsPreserved() {
        let buffer = makeBuffer()
        let pts = CMTime(value: 48_000, timescale: 48_000)  // 1 s

        let result = buffer.cmSampleBuffer(presentationTime: pts)!

        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(result), pts)
    }

    func testZeroPresentationTimeIsPreserved() {
        let buffer = makeBuffer()

        let result = buffer.cmSampleBuffer(presentationTime: .zero)!

        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(result), .zero)
    }

    func testArbitraryPresentationTimeIsPreserved() {
        let buffer = makeBuffer()
        let pts = CMTime(value: 123_456_789, timescale: 1_000_000_000)

        let result = buffer.cmSampleBuffer(presentationTime: pts)!

        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(result), pts)
    }

    // MARK: - Format

    func testStereoBufferProducesTwoChannels() {
        let buffer = makeBuffer(channels: 2)

        let result = buffer.cmSampleBuffer(presentationTime: .zero)!
        let desc = CMSampleBufferGetFormatDescription(result)!
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)!.pointee

        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
    }

    func testMonoBufferProducesOneChannel() {
        let buffer = makeBuffer(channels: 1)

        let result = buffer.cmSampleBuffer(presentationTime: .zero)!
        let desc = CMSampleBufferGetFormatDescription(result)!
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)!.pointee

        XCTAssertEqual(asbd.mChannelsPerFrame, 1)
    }

    func testSampleRateIsPreserved() {
        let sampleRate = 44_100.0
        let buffer = makeBuffer(sampleRate: sampleRate)

        let result = buffer.cmSampleBuffer(presentationTime: .zero)!
        let desc = CMSampleBufferGetFormatDescription(result)!
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)!.pointee

        XCTAssertEqual(asbd.mSampleRate, sampleRate)
    }

    // MARK: - Data readiness

    func testResultIsReadyForConsumption() {
        let buffer = makeBuffer()

        let result = buffer.cmSampleBuffer(presentationTime: .zero)!

        XCTAssertTrue(CMSampleBufferDataIsReady(result))
    }
}
