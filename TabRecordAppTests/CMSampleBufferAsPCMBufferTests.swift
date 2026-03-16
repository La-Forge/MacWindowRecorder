import AVFoundation
import CoreAudio
import CoreMedia
import XCTest

@testable import TabRecordApp

/// Tests for `CMSampleBuffer.asPCMBuffer()` — converts SCStream LPCM buffers
/// (which may be interleaved) into non-interleaved `AVAudioPCMBuffer` for mixing.
final class CMSampleBufferAsPCMBufferTests: XCTestCase {

    // MARK: - Helpers

    /// Build a CMSampleBuffer backed by synthetic float32 PCM data.
    ///
    /// - Parameters:
    ///   - channelCount: Number of channels.
    ///   - frameCount: Number of audio frames.
    ///   - interleaved: If true, produce an interleaved layout (1 buffer,
    ///     mNumberChannels == channelCount). SCStream sometimes delivers this.
    ///   - fillValue: Sample value written to every frame/channel.
    private func makeCMSampleBuffer(
        channelCount: UInt32,
        sampleRate: Float64 = 48_000,
        frameCount: Int = 1024,
        interleaved: Bool,
        fillValue: Float = 0.5
    ) -> CMSampleBuffer {
        // Build ASBD
        let bytesPerSample: UInt32 = 4  // float32
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = sampleRate
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mBitsPerChannel = 32
        asbd.mChannelsPerFrame = channelCount

        if interleaved {
            asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            asbd.mBytesPerFrame = bytesPerSample * channelCount
            asbd.mBytesPerPacket = asbd.mBytesPerFrame
            asbd.mFramesPerPacket = 1
        } else {
            asbd.mFormatFlags =
                kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved
            asbd.mBytesPerFrame = bytesPerSample
            asbd.mBytesPerPacket = bytesPerSample
            asbd.mFramesPerPacket = 1
        }

        // Allocate raw PCM data
        let totalBytes = Int(asbd.mBytesPerFrame) * frameCount * (interleaved ? 1 : Int(channelCount))
        let data = UnsafeMutableRawPointer.allocate(
            byteCount: totalBytes, alignment: MemoryLayout<Float>.alignment)
        defer { data.deallocate() }
        let floatPtr = data.bindMemory(to: Float.self, capacity: totalBytes / 4)
        for i in 0..<(totalBytes / 4) { floatPtr[i] = fillValue }

        // Build AudioBufferList
        let ablSize = MemoryLayout<AudioBufferList>.size +
            (interleaved ? 0 : Int(channelCount - 1)) * MemoryLayout<AudioBuffer>.size
        let ablPtr = UnsafeMutableRawPointer.allocate(
            byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablPtr.deallocate() }
        let abl = ablPtr.bindMemory(to: AudioBufferList.self, capacity: 1)

        if interleaved {
            abl.pointee.mNumberBuffers = 1
            abl.pointee.mBuffers.mNumberChannels = channelCount
            abl.pointee.mBuffers.mDataByteSize = UInt32(Int(asbd.mBytesPerFrame) * frameCount)
            abl.pointee.mBuffers.mData = data
        } else {
            abl.pointee.mNumberBuffers = channelCount
            let perChannelBytes = UInt32(bytesPerSample * UInt32(frameCount))
            // Write each AudioBuffer into the flexible array
            withUnsafeMutablePointer(to: &abl.pointee.mBuffers) { base in
                for ch in 0..<Int(channelCount) {
                    (base + ch).pointee.mNumberChannels = 1
                    (base + ch).pointee.mDataByteSize = perChannelBytes
                    (base + ch).pointee.mData =
                        data + ch * Int(perChannelBytes)
                }
            }
        }

        // Create format description
        var fmtDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &fmtDesc
        )

        // Create CMSampleBuffer
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmtDesc,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sb
        )
        CMSampleBufferSetDataBufferFromAudioBufferList(
            sb!,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: abl
        )
        return sb!
    }

    // MARK: - Non-interleaved (SCStream default)

    func testNonInterleavedBufferReturnsNonNil() {
        let sb = makeCMSampleBuffer(channelCount: 2, frameCount: 1024, interleaved: false)

        XCTAssertNotNil(sb.asPCMBuffer())
    }

    func testNonInterleavedOutputIsNonInterleaved() {
        let sb = makeCMSampleBuffer(channelCount: 2, frameCount: 1024, interleaved: false)

        let result = sb.asPCMBuffer()!

        XCTAssertFalse(result.format.isInterleaved)
    }

    func testNonInterleavedPreservesChannelCount() {
        let sb = makeCMSampleBuffer(channelCount: 2, frameCount: 512, interleaved: false)

        XCTAssertEqual(sb.asPCMBuffer()!.format.channelCount, 2)
    }

    func testNonInterleavedPreservesFrameCount() {
        let sb = makeCMSampleBuffer(channelCount: 2, frameCount: 512, interleaved: false)

        XCTAssertEqual(sb.asPCMBuffer()!.frameLength, 512)
    }

    func testNonInterleavedPreservesSampleData() {
        let sb = makeCMSampleBuffer(
            channelCount: 2, frameCount: 64, interleaved: false, fillValue: 0.75)

        let pcm = sb.asPCMBuffer()!
        let ch0 = pcm.floatChannelData![0]
        XCTAssertEqual(ch0[0], 0.75, accuracy: 1e-6)
    }

    // MARK: - Interleaved (some SCStream configurations)

    func testInterleavedBufferReturnsNonNil() {
        let sb = makeCMSampleBuffer(channelCount: 2, frameCount: 1024, interleaved: true)

        XCTAssertNotNil(sb.asPCMBuffer())
    }

    func testInterleavedOutputIsNonInterleaved() {
        let sb = makeCMSampleBuffer(channelCount: 2, frameCount: 1024, interleaved: true)

        let result = sb.asPCMBuffer()!

        XCTAssertFalse(result.format.isInterleaved)
    }

    func testInterleavedPreservesChannelCount() {
        let sb = makeCMSampleBuffer(channelCount: 2, frameCount: 512, interleaved: true)

        XCTAssertEqual(sb.asPCMBuffer()!.format.channelCount, 2)
    }

    func testInterleavedPreservesFrameCount() {
        let sb = makeCMSampleBuffer(channelCount: 2, frameCount: 512, interleaved: true)

        XCTAssertEqual(sb.asPCMBuffer()!.frameLength, 512)
    }

    func testInterleavedPreservesSampleData() {
        // fillValue=0.25 written to all samples; after deinterleaving each channel
        // should still read 0.25.
        let sb = makeCMSampleBuffer(
            channelCount: 2, frameCount: 64, interleaved: true, fillValue: 0.25)

        let pcm = sb.asPCMBuffer()!
        let ch0 = pcm.floatChannelData![0]
        XCTAssertEqual(ch0[0], 0.25, accuracy: 1e-6)
    }
}
