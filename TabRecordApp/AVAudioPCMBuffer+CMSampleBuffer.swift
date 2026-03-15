import AVFoundation
import CoreMedia

extension AVAudioPCMBuffer {

    /// Wraps the receiver's PCM data in a `CMSampleBuffer` ready to be
    /// appended to an `AVAssetWriterInput`.
    ///
    /// Returns `nil` if the format description or sample buffer cannot be
    /// created — both are programmer errors and should not occur at runtime
    /// with a well-formed `AVAudioPCMBuffer`.
    ///
    /// - Parameter presentationTime: The timestamp to stamp on the buffer,
    ///   typically derived from `CMTimeConverter.cmTime(from:sampleRate:)`.
    func cmSampleBuffer(presentationTime: CMTime) -> CMSampleBuffer? {
        // 1. Build a CoreAudio format description from the buffer's ASBD.
        var asbd = format.streamDescription.pointee
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }

        // 2. Create an empty CMSampleBuffer with timing metadata.
        let numFrames = CMItemCount(frameLength)
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: numFrames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        // 3. Attach the raw PCM data from the AVAudioPCMBuffer.
        //    `audioBufferList` returns an UnsafePointer<AudioBufferList> that
        //    points directly into the buffer's storage — no copy needed.
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: audioBufferList
        ) == noErr else { return nil }

        return sampleBuffer
    }
}
