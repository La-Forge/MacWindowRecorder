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
        let frameCount = min(speaker.frameLength, mic.frameLength)
        let sampleRate = speaker.format.sampleRate

        let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: frameCount)!
        output.frameLength = frameCount

        let outL = output.floatChannelData![0]
        let outR = output.floatChannelData![1]
        let spL  = speaker.floatChannelData![0]
        let micC = mic.floatChannelData![0]

        for i in 0..<Int(frameCount) {
            outL[i] = spL[i]
            outR[i] = micC[i]
        }

        return output
    }
}
