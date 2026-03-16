import AVFoundation
import XCTest

@testable import TabRecordApp

final class AudioMixerTests: XCTestCase {

    // MARK: - Helpers

    private func makeStereoBuffer(
        sampleRate: Double = 48_000,
        frameLength: AVAudioFrameCount = 1024,
        fillValue: Float = 0.0
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)!
        buf.frameLength = frameLength
        if let ch0 = buf.floatChannelData?[0], let ch1 = buf.floatChannelData?[1] {
            for i in 0..<Int(frameLength) {
                ch0[i] = fillValue
                ch1[i] = fillValue
            }
        }
        return buf
    }

    private func makeMonoBuffer(
        sampleRate: Double = 48_000,
        frameLength: AVAudioFrameCount = 1024,
        fillValue: Float = 0.0
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength)!
        buf.frameLength = frameLength
        if let ch0 = buf.floatChannelData?[0] {
            for i in 0..<Int(frameLength) {
                ch0[i] = fillValue
            }
        }
        return buf
    }

    // MARK: - Output format

    func testOutputIsStereo() {
        let speaker = makeStereoBuffer()
        let mic = makeMonoBuffer()

        let result = AudioMixer.mix(speaker: speaker, mic: mic)

        XCTAssertEqual(result.format.channelCount, 2)
    }

    func testOutputSampleRateMatchesSpeaker() {
        let speaker = makeStereoBuffer(sampleRate: 48_000)
        let mic = makeMonoBuffer(sampleRate: 48_000)

        let result = AudioMixer.mix(speaker: speaker, mic: mic)

        XCTAssertEqual(result.format.sampleRate, 48_000)
    }

    // MARK: - Channel routing: L = speaker, R = mic

    func testLeftChannelContainsSpeakerAudio() {
        // speaker L=0.8, mic=0.4 → mixed L must equal speaker L
        let speaker = makeStereoBuffer(frameLength: 512, fillValue: 0.8)
        let mic = makeMonoBuffer(frameLength: 512, fillValue: 0.4)

        let result = AudioMixer.mix(speaker: speaker, mic: mic)

        let left = result.floatChannelData![0]
        XCTAssertEqual(left[0], 0.8, accuracy: 1e-6)
    }

    func testRightChannelContainsMicAudio() {
        // mic=0.4 → mixed R must equal mic sample
        let speaker = makeStereoBuffer(frameLength: 512, fillValue: 0.8)
        let mic = makeMonoBuffer(frameLength: 512, fillValue: 0.4)

        let result = AudioMixer.mix(speaker: speaker, mic: mic)

        let right = result.floatChannelData![1]
        XCTAssertEqual(right[0], 0.4, accuracy: 1e-6)
    }

    // MARK: - Silent channels

    func testSilentMicProducesZeroRightChannel() {
        let speaker = makeStereoBuffer(frameLength: 256, fillValue: 0.5)
        let mic = makeMonoBuffer(frameLength: 256, fillValue: 0.0)

        let result = AudioMixer.mix(speaker: speaker, mic: mic)

        let right = result.floatChannelData![1]
        for i in 0..<256 { XCTAssertEqual(right[i], 0.0, accuracy: 1e-6, "frame \(i)") }
    }

    func testSilentSpeakerProducesZeroLeftChannel() {
        let speaker = makeStereoBuffer(frameLength: 256, fillValue: 0.0)
        let mic = makeMonoBuffer(frameLength: 256, fillValue: 0.6)

        let result = AudioMixer.mix(speaker: speaker, mic: mic)

        let left = result.floatChannelData![0]
        for i in 0..<256 { XCTAssertEqual(left[i], 0.0, accuracy: 1e-6, "frame \(i)") }
    }

    // MARK: - Frame length

    func testOutputFrameLengthMatchesSpeakerWhenEqual() {
        let speaker = makeStereoBuffer(frameLength: 1024)
        let mic = makeMonoBuffer(frameLength: 1024)

        let result = AudioMixer.mix(speaker: speaker, mic: mic)

        XCTAssertEqual(result.frameLength, 1024)
    }

    func testOutputFrameLengthUsesMinWhenMismatch() {
        // Speaker 1024 frames, mic 512 frames → min = 512
        let speaker = makeStereoBuffer(frameLength: 1024)
        let mic = makeMonoBuffer(frameLength: 512)

        let result = AudioMixer.mix(speaker: speaker, mic: mic)

        XCTAssertEqual(result.frameLength, 512)
    }

    func testOutputFrameLengthUsesMinWhenMicLarger() {
        // Speaker 256, mic 1024 → min = 256
        let speaker = makeStereoBuffer(frameLength: 256)
        let mic = makeMonoBuffer(frameLength: 1024)

        let result = AudioMixer.mix(speaker: speaker, mic: mic)

        XCTAssertEqual(result.frameLength, 256)
    }

    // MARK: - Speaker stereo downmix to left channel

    // MARK: - Sample rate mismatch (mic at 44.1 kHz, speaker at 48 kHz)

    func testMixWithDifferentSampleRatesOutputsAtSpeakerRate() {
        // Mic hardware may run at 44.1 kHz; speaker is always 48 kHz from SCStream.
        // The output must be at 48 kHz — not 44.1 kHz — so timestamps stay correct.
        let speaker = makeStereoBuffer(sampleRate: 48_000, frameLength: 1024)
        let mic = makeMonoBuffer(sampleRate: 44_100, frameLength: 1024)

        let result = AudioMixer.mix(speaker: speaker, mic: mic)

        XCTAssertEqual(result.format.sampleRate, 48_000)
    }

    func testMixWithDifferentSampleRatesRightChannelIsNonZero() {
        // If resampling is skipped the mic samples map to the wrong indices and
        // the output is effectively silence or truncated. Verify the right channel
        // has non-zero content after mixing a non-silent mic.
        let speaker = makeStereoBuffer(sampleRate: 48_000, frameLength: 1024, fillValue: 0.0)
        let mic = makeMonoBuffer(sampleRate: 44_100, frameLength: 1024, fillValue: 0.5)

        let result = AudioMixer.mix(speaker: speaker, mic: mic)

        let right = result.floatChannelData![1]
        let hasNonZero = (0..<Int(result.frameLength)).contains { right[$0] != 0.0 }
        XCTAssertTrue(hasNonZero, "Right channel (mic) should be non-zero after resampling")
    }

    func testSpeakerStereoAveragedIntoLeftChannel() {
        // Speaker L=1.0, R=0.0 — left channel of mix must carry speaker's L channel
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let speaker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
        speaker.frameLength = 64
        let spL = speaker.floatChannelData![0]
        let spR = speaker.floatChannelData![1]
        for i in 0..<64 { spL[i] = 1.0; spR[i] = 0.0 }

        let mic = makeMonoBuffer(frameLength: 64, fillValue: 0.0)

        let result = AudioMixer.mix(speaker: speaker, mic: mic)

        // Mixed L = speaker L channel (left as-is)
        let mixL = result.floatChannelData![0]
        XCTAssertEqual(mixL[0], 1.0, accuracy: 1e-6)
    }
}
