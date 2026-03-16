import AVFoundation

/// A simple FIFO of float32 mono samples, used to decouple the AVAudioEngine
/// mic tap (large, infrequent buffers) from the SCStream audio callback (small,
/// frequent buffers).
///
/// Thread safety: the caller is responsible for locking around all calls.
final class MicRingBuffer {

    private var samples: [Float] = []
    private var sourceSampleRate: Double = 48_000

    var isEmpty: Bool { samples.isEmpty }

    /// Append a mic buffer into the FIFO, converting to a normalised float32
    /// mono representation. Handles any channel count by using channel 0 only.
    func push(_ buffer: AVAudioPCMBuffer) {
        sourceSampleRate = buffer.format.sampleRate
        guard let ch = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: count))
    }

    /// Drain up to `frameCount` frames resampled to `targetSampleRate`.
    ///
    /// If the ring has fewer source frames than needed after accounting for the
    /// sample-rate ratio, all available frames are consumed and the output is
    /// zero-padded to `frameCount`. Returns nil only if the ring is empty.
    func drain(frameCount: AVAudioFrameCount, targetSampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty else { return nil }

        let ratio = sourceSampleRate / targetSampleRate   // e.g. 24000/48000 = 0.5
        // Number of source frames that correspond to frameCount output frames
        let sourceFramesNeeded = Int((Double(frameCount) * ratio).rounded(.up))
        let sourceFramesAvailable = min(sourceFramesNeeded, samples.count)

        // Pull source frames out of the ring
        let sourceSlice = Array(samples.prefix(sourceFramesAvailable))
        samples.removeFirst(sourceFramesAvailable)

        // Build a source AVAudioPCMBuffer from the slice
        let srcFormat = AVAudioFormat(standardFormatWithSampleRate: sourceSampleRate, channels: 1)!
        guard let srcPCM = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                            frameCapacity: AVAudioFrameCount(sourceSlice.count))
        else { return nil }
        srcPCM.frameLength = AVAudioFrameCount(sourceSlice.count)
        sourceSlice.withUnsafeBufferPointer { ptr in
            srcPCM.floatChannelData![0].update(from: ptr.baseAddress!, count: sourceSlice.count)
        }

        // If no resampling needed, return directly (zero-padded if short)
        if sourceSampleRate == targetSampleRate {
            return zeroPad(srcPCM, to: frameCount, sampleRate: targetSampleRate)
        }

        // Resample to targetSampleRate
        let dstFormat = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1)!
        guard let dstPCM = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: frameCount),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat)
        else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: dstPCM, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            consumed = true
            return srcPCM
        }
        guard error == nil else { return nil }
        return zeroPad(dstPCM, to: frameCount, sampleRate: targetSampleRate)
    }

    func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    // MARK: - Private

    private func zeroPad(_ buf: AVAudioPCMBuffer, to frameCount: AVAudioFrameCount,
                         sampleRate: Double) -> AVAudioPCMBuffer {
        guard buf.frameLength < frameCount else {
            buf.frameLength = frameCount
            return buf
        }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount)!
        out.frameLength = frameCount
        // floatChannelData is zero-initialised; copy what we have
        memcpy(out.floatChannelData![0], buf.floatChannelData![0],
               Int(buf.frameLength) * MemoryLayout<Float>.size)
        return out
    }
}
