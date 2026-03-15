import AVFoundation
import CoreAudio
import CoreMedia
import CoreVideo
import ScreenCaptureKit

// MARK: - Recording source

/// Describes what content SCStream should capture.
enum RecordingSource {
    case display(SCDisplay, SCContentFilter)
    case window(SCWindow, SCContentFilter)
    /// Raw filter produced by SCContentSharingPicker (macOS 14+).
    case filter(SCContentFilter)
}

// MARK: - Errors

enum RecordingError: LocalizedError {
    case writerSetupFailed(String)
    case streamSetupFailed(String)
    case micSetupFailed(String)
    case writerNotReady

    var errorDescription: String? {
        switch self {
        case .writerSetupFailed(let msg): return "Asset writer setup failed: \(msg)"
        case .streamSetupFailed(let msg): return "Screen capture setup failed: \(msg)"
        case .micSetupFailed(let msg):    return "Microphone setup failed: \(msg)"
        case .writerNotReady:             return "Asset writer is not in a writable state"
        }
    }
}

// MARK: - RecordingEngine

/// Coordinates ScreenCaptureKit (video + source audio) and AVAudioEngine (mic)
/// into a single MP4 file with three tracks via AVAssetWriter.
///
/// Thread-safety notes:
/// - `startRecording` / `stopRecording` must be called from `@MainActor`.
/// - SCStream sample callbacks arrive on the queues we supply.
/// - AVAudioEngine tap callbacks arrive on an internal audio thread.
/// - `sessionStarted` is protected by `sessionLock` because the first video
///   frame and the first audio/mic frame can race to start the writer session.
final class RecordingEngine: NSObject {

    // MARK: AVAssetWriter state (accessed from multiple queues)

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioSourceInput: AVAssetWriterInput?  // track 1 — app/screen audio
    private var audioMicInput: AVAssetWriterInput?     // track 2 — microphone

    private var sessionStarted = false
    private let sessionLock = NSLock()

    // MARK: Capture state

    private var stream: SCStream?
    private var audioEngine: AVAudioEngine?

    // MARK: Dedicated dispatch queues for SCStream callbacks

    private let videoQueue = DispatchQueue(
        label: "com.tabrecord.engine.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(
        label: "com.tabrecord.engine.audio", qos: .userInitiated)

    // MARK: - Public API

    /// Configure and start all capture pipelines, then begin writing to `outputURL`.
    func startRecording(source: RecordingSource, outputURL: URL) async throws {
        // Clean slate
        sessionStarted = false

        // 1. Build the AVAssetWriter (synchronous, fast)
        try setupAssetWriter(outputURL: outputURL)

        // 2. Build and start SCStream (async — may show permission prompt)
        try await setupStream(source: source)

        // 3. Tap the microphone (synchronous setup, async-safe)
        try setupMicrophone()

        // 4. Kick off writing and capture
        guard assetWriter?.startWriting() == true else {
            throw RecordingError.writerNotReady
        }
        try await stream?.startCapture()
    }

    /// Stop all capture pipelines and finalise the output file.
    func stopRecording() async {
        // Stop mic first — no more tap callbacks after removeTap
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        // Stop screen capture
        try? await stream?.stopCapture()
        stream = nil

        // Finish the MP4 file
        await finaliseWriter()
    }

    // MARK: - AVAssetWriter setup

    private func setupAssetWriter(outputURL: URL) throws {
        try? FileManager.default.removeItem(at: outputURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        } catch {
            throw RecordingError.writerSetupFailed(error.localizedDescription)
        }

        // --- Video input: H.264 via pixel buffer adaptor -------------------------
        // Width/height are placeholders — the adaptor accepts any CVPixelBuffer
        // size at append time. AVAssetWriter infers the actual track dimensions
        // from the first buffer appended through the adaptor.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ]
        )

        // --- Audio source input: AAC stereo, track 1 ----------------------------
        let audioSourceSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        let audioSourceInput = AVAssetWriterInput(
            mediaType: .audio, outputSettings: audioSourceSettings)
        audioSourceInput.expectsMediaDataInRealTime = true

        // --- Audio mic input: AAC mono, track 2 ---------------------------------
        let audioMicSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        let audioMicInput = AVAssetWriterInput(
            mediaType: .audio, outputSettings: audioMicSettings)
        audioMicInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput),
              writer.canAdd(audioSourceInput),
              writer.canAdd(audioMicInput)
        else {
            throw RecordingError.writerSetupFailed(
                "Cannot add one or more inputs to AVAssetWriter")
        }

        writer.add(videoInput)
        writer.add(audioSourceInput)
        writer.add(audioMicInput)

        self.assetWriter = writer
        self.videoInput = videoInput
        self.videoAdaptor = videoAdaptor
        self.audioSourceInput = audioSourceInput
        self.audioMicInput = audioMicInput
    }

    // MARK: - SCStream setup

    private func setupStream(source: RecordingSource) async throws {
        let filter: SCContentFilter
        switch source {
        case .display(_, let f): filter = f
        case .window(_, let f):  filter = f
        case .filter(let f):     filter = f
        }

        let config = SCStreamConfiguration()
        config.width = 1920
        config.height = 1080
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)  // 30 fps cap
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.scalesToFit = true

        // Audio from the captured content (macOS 13+)
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

        self.stream = newStream
    }

    // MARK: - Microphone setup

    private func setupMicrophone() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Use the hardware format to avoid resampling artefacts.
        // AVAssetWriter will handle conversion to the output AAC format.
        let inputFormat = inputNode.inputFormat(forBus: 0)

        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat
        ) { [weak self] buffer, time in
            self?.processMicBuffer(buffer, time: time)
        }

        do {
            try engine.start()
        } catch {
            throw RecordingError.micSetupFailed(error.localizedDescription)
        }

        self.audioEngine = engine
    }

    // MARK: - Sample buffer processing

    /// Called from AVAudioEngine's internal audio thread — keep it fast.
    private func processMicBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let micInput = audioMicInput,
              micInput.isReadyForMoreMediaData,
              isSessionStarted()
        else { return }

        let pts = CMTimeConverter.cmTime(from: time, sampleRate: buffer.format.sampleRate)
        guard let sampleBuffer = buffer.cmSampleBuffer(presentationTime: pts) else { return }
        micInput.append(sampleBuffer)
    }

    // MARK: - Session management

    /// Thread-safe check for whether `startSession(atSourceTime:)` has been called.
    private func isSessionStarted() -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessionStarted
    }

    /// Thread-safe start of the writer session; call at most once (video first).
    private func startSessionIfNeeded(at pts: CMTime) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        guard !sessionStarted else { return }
        assetWriter?.startSession(atSourceTime: pts)
        sessionStarted = true
    }

    // MARK: - Writer finalisation

    private func finaliseWriter() async {
        videoInput?.markAsFinished()
        audioSourceInput?.markAsFinished()
        audioMicInput?.markAsFinished()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            assetWriter?.finishWriting { cont.resume() }
        }

        assetWriter = nil
        videoInput = nil
        videoAdaptor = nil
        audioSourceInput = nil
        audioMicInput = nil
    }

}

// MARK: - SCStreamDelegate

extension RecordingEngine: SCStreamDelegate {
    /// Called when SCStream stops unexpectedly (e.g. the captured window closes).
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Post a notification so MenuBarController can update its UI.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .recordingDidStopUnexpectedly,
                object: error
            )
        }
    }
}

// MARK: - SCStreamOutput

extension RecordingEngine: SCStreamOutput {
    /// Called on `videoQueue` for `.screen` and on `audioQueue` for `.audio`.
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .screen:
            handleVideoSample(sampleBuffer)
        case .audio:
            handleAudioSourceSample(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // The very first video frame triggers startSession.
        startSessionIfNeeded(at: pts)

        guard let adaptor = videoAdaptor,
              adaptor.assetWriterInput.isReadyForMoreMediaData,
              isSessionStarted()
        else { return }

        adaptor.append(pixelBuffer, withPresentationTime: pts)
    }

    private func handleAudioSourceSample(_ sampleBuffer: CMSampleBuffer) {
        guard let input = audioSourceInput,
              input.isReadyForMoreMediaData,
              isSessionStarted()
        else { return }

        input.append(sampleBuffer)
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let recordingDidStopUnexpectedly = Notification.Name(
        "com.tabrecord.recordingDidStopUnexpectedly"
    )
}
