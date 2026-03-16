import AVFoundation
import CoreMedia

extension CMSampleBuffer {

    /// Convert a LPCM `CMSampleBuffer` (as delivered by SCStream `.audio`)
    /// into a non-interleaved `AVAudioPCMBuffer` suitable for `AudioMixer`.
    ///
    /// SCStream can deliver audio in either interleaved layout (one
    /// `AudioBuffer` whose `mNumberChannels` equals the channel count) or
    /// non-interleaved layout (one `AudioBuffer` per channel). Both cases are
    /// handled: non-interleaved buffers are copied directly; interleaved
    /// buffers are converted via `AVAudioConverter`.
    ///
    /// Returns `nil` if the format description is missing, the frame count is
    /// zero, or conversion fails.
    func asPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }

        guard let srcFormat = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frameCount > 0 else { return nil }

        if !srcFormat.isInterleaved {
            // Non-interleaved: copy directly into an AVAudioPCMBuffer.
            guard let pcm = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount)
            else { return nil }
            pcm.frameLength = frameCount
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                self, at: 0, frameCount: Int32(frameCount),
                into: pcm.mutableAudioBufferList
            ) == noErr else { return nil }
            return pcm
        }

        // Interleaved: convert to non-interleaved via AVAudioConverter.
        guard let dstFormat = AVAudioFormat(
            standardFormatWithSampleRate: srcFormat.sampleRate,
            channels: srcFormat.channelCount
        ) else { return nil }

        guard let srcPCM = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount),
              let dstPCM = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: frameCount),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat)
        else { return nil }

        srcPCM.frameLength = frameCount
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frameCount),
            into: srcPCM.mutableAudioBufferList
        ) == noErr else { return nil }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return srcPCM
        }
        converter.convert(to: dstPCM, error: &error, withInputFrom: inputBlock)
        guard error == nil else { return nil }
        dstPCM.frameLength = frameCount
        return dstPCM
    }
}
