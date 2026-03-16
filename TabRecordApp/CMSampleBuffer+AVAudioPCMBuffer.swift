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

        // SCStream backs its CMSampleBuffers with a CMBlockBuffer, not an
        // AudioBufferList. CMSampleBufferCopyPCMDataIntoAudioBufferList fails
        // with kCMSampleBufferError_InvalidMediaFormat on these buffers.
        // CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer works instead:
        // it returns a pointer into the block buffer's memory (no copy).
        var blockBuffer: CMBlockBuffer?
        // Size the ABL for the actual number of audio buffers.
        let numBuffers = srcFormat.isInterleaved ? 1 : Int(srcFormat.channelCount)
        let ablSize = MemoryLayout<AudioBufferList>.size
            + max(0, numBuffers - 1) * MemoryLayout<AudioBuffer>.size
        let ablPtr = UnsafeMutableRawPointer.allocate(
            byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablPtr.deallocate() }
        let abl = ablPtr.bindMemory(to: AudioBufferList.self, capacity: 1)

        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl,
            bufferListSize: ablSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        ) == noErr else { return nil }

        // Wrap in AVAudioPCMBuffer. If already non-interleaved we can wrap
        // directly; interleaved needs a conversion pass.
        if !srcFormat.isInterleaved {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount)
            else { return nil }
            pcm.frameLength = frameCount
            // Copy each channel's data from the ABL into the PCM buffer.
            // UnsafeMutableAudioBufferListPointer gives safe indexed access to
            // the flexible AudioBuffer array.
            let ablBuffers = UnsafeMutableAudioBufferListPointer(abl)
            for ch in 0..<min(numBuffers, ablBuffers.count) {
                guard let srcData = ablBuffers[ch].mData else { continue }
                memcpy(pcm.floatChannelData![ch], srcData, Int(ablBuffers[ch].mDataByteSize))
            }
            return pcm
        }

        // Interleaved → non-interleaved via AVAudioConverter.
        guard let dstFormat = AVAudioFormat(
            standardFormatWithSampleRate: srcFormat.sampleRate,
            channels: srcFormat.channelCount
        ) else { return nil }

        guard let srcPCM = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount),
              let dstPCM = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: frameCount),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat)
        else { return nil }

        srcPCM.frameLength = frameCount
        // Copy interleaved data into srcPCM's single AudioBuffer.
        let ablBuffers = UnsafeMutableAudioBufferListPointer(abl)
        if ablBuffers.count > 0, let srcData = ablBuffers[0].mData {
            let dstABL = UnsafeMutableAudioBufferListPointer(srcPCM.mutableAudioBufferList)
            if dstABL.count > 0, let dstData = dstABL[0].mData {
                memcpy(dstData, srcData, Int(ablBuffers[0].mDataByteSize))
            }
        }

        var error: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            consumed = true
            return srcPCM
        }
        converter.convert(to: dstPCM, error: &error, withInputFrom: inputBlock)
        guard error == nil, dstPCM.frameLength > 0 else { return nil }
        return dstPCM
    }
}
