import AVFoundation
import Foundation

// MARK: - Errors

enum AudioPreprocessorError: LocalizedError {
    case noAudioTrack(AudioSource)
    case exportFailed(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack(let source):
            return "No audio track found for source: \(source.displayName)"
        case .exportFailed(let msg):
            return "Audio export failed: \(msg)"
        case .conversionFailed(let msg):
            return "Audio conversion failed: \(msg)"
        }
    }
}

// MARK: - AudioPreprocessor

/// Extracts the chosen audio track from a recording and resamples it to
/// 16 kHz mono PCM — the format expected by Whisper.
struct AudioPreprocessor {

    // MARK: - Public API

    /// Extracts the selected audio source from `recordingFiles` and writes a
    /// 16 kHz mono WAV to the system temporary directory.
    ///
    /// - Returns: URL of the temporary WAV file. The caller is responsible for
    ///   deleting this file when transcription finishes.
    func prepareForTranscription(
        source: AudioSource,
        recordingFiles: RecordingFiles
    ) async throws -> URL {
        let sourceURL = audioFileURL(for: source, recordingFiles: recordingFiles)
        let asset = AVURLAsset(url: sourceURL)

        // Load track metadata
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw AudioPreprocessorError.noAudioTrack(source)
        }

        // For the main MP4 we need to pick the right track by index.
        // Track layout in the MP4: index 0 = mixed, index 1 = speaker, index 2 = mic.
        // For M4A files (mic.m4a / speaker.m4a) there's only one track.
        let selectedTrack: AVAssetTrack
        if sourceURL.pathExtension.lowercased() == "mp4" {
            let allAudioTracks = try await asset.loadTracks(withMediaType: .audio)
            let desiredIndex = trackIndex(for: source)
            selectedTrack = allAudioTracks.indices.contains(desiredIndex)
                ? allAudioTracks[desiredIndex]
                : track
        } else {
            selectedTrack = track
        }

        // Export to a temp linear PCM file first, then convert to 16 kHz mono.
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(
            "tabrecord-preprocess-\(UUID().uuidString).wav"
        )
        try await exportPCM(track: selectedTrack, asset: asset, to: tempURL)
        let outputURL = tempDir.appendingPathComponent(
            "tabrecord-16k-\(UUID().uuidString).wav"
        )
        try resampleTo16kMonoPCM(inputURL: tempURL, outputURL: outputURL)
        try? FileManager.default.removeItem(at: tempURL)
        return outputURL
    }

    // MARK: - Private

    private func audioFileURL(for source: AudioSource, recordingFiles: RecordingFiles) -> URL {
        switch source {
        case .speakerTrack: return recordingFiles.speakerURL
        case .micTrack:     return recordingFiles.micURL
        case .mixedTrack:   return recordingFiles.videoURL
        }
    }

    /// Track index within the main MP4. Mixed = 0, Speaker = 1, Mic = 2.
    private func trackIndex(for source: AudioSource) -> Int {
        switch source {
        case .mixedTrack:   return 0
        case .speakerTrack: return 1
        case .micTrack:     return 2
        }
    }

    /// Export a single AVAssetTrack to a linear PCM WAV at its native rate.
    private func exportPCM(track: AVAssetTrack, asset: AVURLAsset, to outputURL: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioPreprocessorError.exportFailed("Could not create AVAssetExportSession")
        }

        // Compose a single-track asset from the selected track
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioPreprocessorError.exportFailed("Could not add composition track")
        }
        let duration = try await asset.load(.duration)
        try compTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: track,
            at: .zero
        )

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioPreprocessorError.exportFailed("Could not create export session for composition")
        }

        // Write as M4A first (passthrough to preserve quality), then we resample below
        let m4aURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabrecord-export-\(UUID().uuidString).m4a")
        exportSession.outputURL = m4aURL
        exportSession.outputFileType = .m4a
        await exportSession.export()

        if let error = exportSession.error {
            throw AudioPreprocessorError.exportFailed(error.localizedDescription)
        }
        // Move/rename to the expected URL
        try FileManager.default.moveItem(at: m4aURL, to: outputURL)
    }

    /// Reads the input file and writes 16 kHz mono Float32 PCM to `outputURL` as a WAV.
    private func resampleTo16kMonoPCM(inputURL: URL, outputURL: URL) throws {
        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: inputURL)
        } catch {
            throw AudioPreprocessorError.conversionFailed("Could not open input: \(error.localizedDescription)")
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: inputFile.processingFormat, to: targetFormat) else {
            throw AudioPreprocessorError.conversionFailed("Could not create AVAudioConverter")
        }

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: targetFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioPreprocessorError.conversionFailed("Could not open output: \(error.localizedDescription)")
        }

        let inputFrameCapacity: AVAudioFrameCount = 4096
        let outputFrameCapacity = AVAudioFrameCount(
            Double(inputFrameCapacity) * targetFormat.sampleRate / inputFile.processingFormat.sampleRate + 1
        )

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFile.processingFormat,
            frameCapacity: inputFrameCapacity
        ),
        let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            throw AudioPreprocessorError.conversionFailed("Buffer allocation failed")
        }

        var reachedEnd = false
        while !reachedEnd {
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try inputFile.read(into: inputBuffer)
                    if inputBuffer.frameLength == 0 {
                        reachedEnd = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    return inputBuffer
                } catch {
                    reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }

            if let error = conversionError {
                throw AudioPreprocessorError.conversionFailed(error.localizedDescription)
            }

            if outputBuffer.frameLength > 0 {
                do {
                    try outputFile.write(from: outputBuffer)
                } catch {
                    throw AudioPreprocessorError.conversionFailed("Write failed: \(error.localizedDescription)")
                }
            }

            if status == .endOfStream { break }
        }
    }
}
