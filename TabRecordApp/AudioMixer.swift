import AVFoundation

/// Mixes a stereo speaker buffer and a mono mic buffer into a single stereo
/// output where the left channel carries speaker audio and the right channel
/// carries mic audio.
///
/// This produces a "default playback" track that any stereo player can play
/// back with both sources audible.
enum AudioMixer {

    /// Mix `speaker` (stereo) and `mic` (mono) into a stereo PCM buffer.
    ///
    /// - The **left channel** of the output is copied from the left channel of
    ///   `speaker`.
    /// - The **right channel** of the output is copied from the (mono) `mic`.
    /// - When the two buffers have different frame lengths, only
    ///   `min(speaker.frameLength, mic.frameLength)` frames are written; the
    ///   tail of the longer buffer is silently dropped.
    ///
    /// - Parameters:
    ///   - speaker: Stereo, non-interleaved float32 PCM from SCStream.
    ///   - mic: Mono, non-interleaved float32 PCM from AVAudioEngine.
    /// - Returns: A stereo, non-interleaved float32 `AVAudioPCMBuffer` at the
    ///   same sample rate as `speaker`.
    static func mix(speaker: AVAudioPCMBuffer, mic: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let sampleRate = speaker.format.sampleRate

        // Resample mic to speaker's sample rate if they differ (e.g. mic at
        // 44.1 kHz hardware rate vs SCStream at 48 kHz). Without this the mic
        // samples are pasted at the wrong indices, producing a robotic effect.
        let micResampled: AVAudioPCMBuffer
        if mic.format.sampleRate != sampleRate {
            micResampled = resample(mic, to: sampleRate) ?? mic
        } else {
            micResampled = mic
        }

        let frameCount = min(speaker.frameLength, micResampled.frameLength)
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: frameCount)!
        output.frameLength = frameCount

        let outL = output.floatChannelData![0]
        let outR = output.floatChannelData![1]
        let spL  = speaker.floatChannelData![0]
        let micC = micResampled.floatChannelData![0]

        for i in 0..<Int(frameCount) {
            outL[i] = spL[i]
            outR[i] = micC[i]
        }

        return output
    }

    // MARK: - Private

    /// Resample `buffer` to `targetRate` using AVAudioConverter.
    /// Returns nil if conversion setup fails (falls back to original rate at call site).
    private static func resample(_ buffer: AVAudioPCMBuffer, to targetRate: Double) -> AVAudioPCMBuffer? {
        guard let dstFormat = AVAudioFormat(
            standardFormatWithSampleRate: targetRate,
            channels: buffer.format.channelCount
        ),
        let converter = AVAudioConverter(from: buffer.format, to: dstFormat)
        else { return nil }

        // Compute output frame count proportionally.
        let ratio = targetRate / buffer.format.sampleRate
        let dstFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let dst = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstFrameCapacity)
        else { return nil }

        var consumed = false
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            consumed = true
            return buffer
        }
        converter.convert(to: dst, error: &error, withInputFrom: inputBlock)
        guard error == nil, dst.frameLength > 0 else { return nil }
        return dst
    }
}
