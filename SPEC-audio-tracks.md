# Spec: Multi-track audio recording (speaker + mic + mixed)

## Context

TabRecord records a window to an MP4 file using ScreenCaptureKit for video and
app audio, and AVAudioEngine for microphone. The goal is to capture:

1. Speaker audio — whatever the recorded app plays (e.g. a video call, Music.app)
2. Microphone audio — the user's voice, even through AirPods/headset
3. A default playback track — both sources mixed, so any player plays both

---

## What the original code does (last commit: 09e02a4)

```
SCStream  ──► .audio samples  ──► audioSourceInput (track 1, stereo AAC)
AVAudioEngine ──► mic tap     ──► audioMicInput    (track 2, mono AAC)
```

**Two tracks are written.** This was confirmed by inspecting a recording made
before today's changes — 2 audio tracks present in the MP4.

### Bug 1: microphone is not recorded when AirPods are connected

`processMicBuffer` drops every buffer unless `isSessionStarted()` returns true.
The session is started by the **first video frame** from SCStream. On a fast
machine this race rarely matters, but the real issue is different:

`AVAudioEngine.inputNode.inputFormat(forBus: 0)` returns the **current default
input device format at setup time**. When AirPods are connected, macOS may
route the mic through a Bluetooth HFP (Hands-Free Profile) audio unit that
operates at 8 kHz or 16 kHz, while the tap is installed with a 48 kHz format.
The format mismatch causes `AVAudioEngine` to silently deliver empty or
zero-filled buffers, or to throw at `engine.start()` depending on the OS
version.

The correct fix is to install the tap using `inputNode.outputFormat(forBus: 0)`
(the *output* side of the input node, which is always non-interleaved float32
at the hardware rate) rather than `inputFormat(forBus: 0)`.

### Bug 2: speaker audio from other apps is not captured

`SCStream` with a **window filter** only captures audio from that specific
window's process. Music.app playing in the background is a different process
and is not included. To capture all system audio, the filter must be a
**display filter** (captures everything on screen) or the configuration must
use `capturesAudio = true` with an `excludingApplications` list set to empty.

In practice, for a "record a window + all audio" use case the recommended
approach is:
- Use a **display** `SCContentFilter` (full screen capture)
- Add `excludedApplications = []` so nothing is excluded from audio
- Optionally set `shouldBeOpaque = true` on the window content filter to keep
  video focused on the chosen window while audio remains display-scoped

### Bug 3: no mixed playback track

There is no third track. Most players (QuickTime, VLC, browser `<video>`) only
play track 1. A user who wants to review the recording with both voice and
screen audio must select tracks manually in a professional editor.

---

## What we tried today and why it failed

### Attempt 1: SCStream `.microphone` output type (macOS 15+)

```swift
config.captureMicrophone = true
stream.addStreamOutput(self, type: .microphone, ...)
```

This API exists but delivered **zero samples** in testing. The likely cause is
that `captureMicrophone` requires an additional TCC entitlement
(`com.apple.security.device.audio-input`) that is already present in the
entitlements file, but macOS 15 adds a second consent prompt specifically for
SCStream microphone access that is separate from the general microphone TCC
permission. Without the user accepting that prompt (which never appeared), the
output type is registered but the stream delivers nothing.

### Attempt 2: mixing CMSampleBuffer → AVAudioPCMBuffer at runtime

The `asPCMBuffer()` helper used `CMSampleBufferCopyPCMDataIntoAudioBufferList`
to decode SCStream `.audio` samples into an `AVAudioPCMBuffer` for mixing.

In testing this always returned `nil`. The likely cause is that SCStream
delivers its LPCM audio as **interleaved** samples in some configurations (the
`AudioBufferList` has 1 buffer with `mNumberChannels = 2`), while
`AVAudioPCMBuffer` with a standard format expects **non-interleaved** samples
(2 buffers, each with `mNumberChannels = 1`). The copy API rejects the layout
mismatch and returns an error code that was not surfaced.

The fix is to detect interleaved vs non-interleaved in `asPCMBuffer()` and
construct the appropriate `AVAudioFormat` before allocating the
`AVAudioPCMBuffer`.

---

## Recommended implementation

### Step 1: Fix `processMicBuffer` — use output format for the tap

```swift
// WRONG — may mismatch hardware sample rate under Bluetooth HFP
let inputFormat = inputNode.inputFormat(forBus: 0)

// CORRECT — always non-interleaved float32 at the hardware rate
let tapFormat = inputNode.outputFormat(forBus: 0)
inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { ... }
```

This is the single-line fix for Bug 1. The tap format must match the node's
output bus format, not its input bus format.

### Step 2: Fix `asPCMBuffer()` — handle interleaved LPCM

```swift
func asPCMBuffer() -> AVAudioPCMBuffer? {
    guard let formatDesc = CMSampleBufferGetFormatDescription(self),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
    else { return nil }

    // SCStream can deliver interleaved LPCM (1 buffer, N channels).
    // AVAudioPCMBuffer requires non-interleaved (N buffers, 1 channel each).
    // Use AVAudioFormat(streamDescription:) which handles both layouts, then
    // use AVAudioConverter to normalise to non-interleaved if needed.
    guard let srcFormat = AVAudioFormat(streamDescription: asbd) else { return nil }

    let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
    guard frameCount > 0 else { return nil }

    // If already non-interleaved, copy directly.
    if !srcFormat.isInterleaved {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount)
        else { return nil }
        pcm.frameLength = frameCount
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frameCount), into: pcm.mutableAudioBufferList
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
        self, at: 0, frameCount: Int32(frameCount), into: srcPCM.mutableAudioBufferList
    ) == noErr else { return nil }

    var error: NSError?
    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
        outStatus.pointee = .haveData
        return srcPCM
    }
    converter.convert(to: dstPCM, error: &error, withInputFrom: inputBlock)
    guard error == nil else { return nil }
    return dstPCM
}
```

### Step 3: Add a mixed stereo track (L=speaker, R=mic)

Once `asPCMBuffer()` works reliably, `AudioMixer.mix(speaker:mic:)` can
produce a combined buffer. Write it as a third `AVAssetWriterInput` track.

The **track ordering in AVAssetWriter matters**: the first audio track added
is treated as the default by QuickTime and most players. Add the mixed track
first.

```swift
writer.add(videoInput)
writer.add(audioMixedInput)   // track 1 — default playback (L=speaker, R=mic)
writer.add(audioSourceInput)  // track 2 — clean speaker
writer.add(audioMicInput)     // track 3 — clean mic
```

The mixed track uses the speaker's presentation timestamp so it stays in sync
with the video.

### Step 4: Handle the mic/speaker buffer-size mismatch

SCStream `.audio` and `AVAudioEngine` deliver buffers at different rates and
sizes. The mixer should use `min(speaker.frameLength, mic.frameLength)` rather
than requiring an exact match. A small amount of audio at the end of each
speaker chunk is acceptable to drop.

Alternatively, maintain a lock-free ring buffer for mic samples and drain the
exact number of frames needed per speaker chunk — but this is over-engineering
for the current use case.

---

## Test plan

### Tests already written (in this branch, can be cherry-picked)

| File | Tests | What they verify |
|------|-------|-----------------|
| `AudioMixerTests.swift` | 10 | Channel layout (L=speaker, R=mic), stereo output format, speaker downmix, silent channels, frame length, mismatched lengths use min |
| `RecordingEngineAudioTests.swift` | 4 | SCStreamOutputType routing — each case is handled, `.microphone` is not silently dropped |

### Tests to add before implementing

| Test | Verifies |
|------|----------|
| `testAsPCMBufferHandlesInterleavedFormat` | `asPCMBuffer()` returns non-nil for an interleaved LPCM `CMSampleBuffer` |
| `testAsPCMBufferNonInterleavedPassthrough` | `asPCMBuffer()` returns non-nil for a non-interleaved LPCM buffer (SCStream default) |
| `testAsPCMBufferPreservesChannelCount` | Output channel count matches source |
| `testAsPCMBufferPreservesSampleData` | Sample values are not corrupted by the interleaved→non-interleaved conversion |
| `testMicTapUsesOutputFormat` | AVAudioEngine tap format equals `inputNode.outputFormat(forBus: 0)` |
| `testThreeAudioTracksInOutputFile` | Integration: recorded MP4 has exactly 3 audio streams (requires AVAssetReader post-processing) |

---

## Summary of recommended changes (in order)

1. **`setupMicrophone()`** — change `inputFormat(forBus: 0)` → `outputFormat(forBus: 0)` for the tap. **One line. Fixes AirPods mic.**

2. **`asPCMBuffer()`** — handle interleaved LPCM by detecting `srcFormat.isInterleaved` and converting via `AVAudioConverter`. **Fixes the mixed track.**

3. **`setupAssetWriter()`** — add `audioMixedInput` as the first audio track. Wire it up in `handleAudioSourceSample` using `AudioMixer`.

4. **Bug 2 (system audio)** is a separate issue and may be by design if the goal is to record only the chosen window's audio. Clarify with product intent before fixing.
