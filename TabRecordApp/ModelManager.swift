import Foundation
import WhisperKit
import SpeakerKit

// MARK: - ModelIdentifier

enum ModelIdentifier: Hashable {
    case whisper(WhisperModelVariant)
    case speaker
}

// MARK: - ModelError

enum ModelError: LocalizedError {
    case insufficientDiskSpace(required: Int64, available: Int64)
    case downloadFailed(String)
    case modelNotFound(ModelIdentifier)

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let required, let available):
            let req = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let avail = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Not enough disk space. Need \(req), only \(avail) available."
        case .downloadFailed(let msg):
            return "Model download failed: \(msg)"
        case .modelNotFound(let id):
            return "Model not found: \(id)"
        }
    }
}

// MARK: - ModelManager

/// Manages on-device CoreML model download and caching for WhisperKit and SpeakerKit.
///
/// Models are stored in `~/Library/Application Support/TabRecord/Models/`.
/// All methods are safe to call from any concurrency context.
actor ModelManager {

    // MARK: - Paths

    static let modelsDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("TabRecord/Models", isDirectory: true)
    }()

    // MARK: - Public API

    /// Returns the local path to the requested Whisper model, downloading if needed.
    func ensureWhisperModel(_ variant: WhisperModelVariant) async throws -> URL {
        let destination = Self.modelsDirectory.appendingPathComponent(variant.rawValue, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        try checkDiskSpace(requiredGB: variant.approximateSizeGB + 0.5)
        do {
            // WhisperKit's built-in download API fetches from argmaxinc/whisperkit-coreml on HuggingFace.
            let downloaded = try await WhisperKit.download(
                variant: variant.rawValue,
                downloadBase: Self.modelsDirectory
            )
            return downloaded
        } catch {
            throw ModelError.downloadFailed(error.localizedDescription)
        }
    }

    /// Returns the local path to the SpeakerKit diarization model, downloading if needed.
    func ensureSpeakerModel() async throws -> URL {
        let destination = Self.modelsDirectory.appendingPathComponent("speakerkit", isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        // ~300 MB for SpeakerKit CoreML models
        try checkDiskSpace(requiredGB: 0.8)
        do {
            let downloaded = try await SpeakerKit.download(
                downloadBase: Self.modelsDirectory
            )
            return downloaded
        } catch {
            throw ModelError.downloadFailed(error.localizedDescription)
        }
    }

    /// List of model identifiers currently cached on disk.
    var installedModels: [ModelIdentifier] {
        var result: [ModelIdentifier] = []
        let fm = FileManager.default
        for variant in WhisperModelVariant.allCases {
            let path = Self.modelsDirectory.appendingPathComponent(variant.rawValue).path
            if fm.fileExists(atPath: path) { result.append(.whisper(variant)) }
        }
        let speakerPath = Self.modelsDirectory.appendingPathComponent("speakerkit").path
        if fm.fileExists(atPath: speakerPath) { result.append(.speaker) }
        return result
    }

    /// Removes a cached model from disk.
    func deleteModel(_ id: ModelIdentifier) throws {
        let url: URL
        switch id {
        case .whisper(let variant):
            url = Self.modelsDirectory.appendingPathComponent(variant.rawValue)
        case .speaker:
            url = Self.modelsDirectory.appendingPathComponent("speakerkit")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ModelError.modelNotFound(id)
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Approximate bytes used by all downloaded models.
    var totalInstalledSizeBytes: Int64 {
        (try? directorySize(Self.modelsDirectory)) ?? 0
    }

    // MARK: - Private

    private func checkDiskSpace(requiredGB: Double) throws {
        let requiredBytes = Int64(requiredGB * 1_000_000_000)
        guard let available = availableDiskSpaceBytes() else { return }
        if available < requiredBytes {
            throw ModelError.insufficientDiskSpace(required: requiredBytes, available: available)
        }
    }

    private func availableDiskSpaceBytes() -> Int64? {
        let values = try? Self.modelsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values?.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        return nil
    }

    private func directorySize(_ url: URL) throws -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }
}
