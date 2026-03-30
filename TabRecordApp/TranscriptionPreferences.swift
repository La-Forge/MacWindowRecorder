import Foundation
import SwiftUI

// MARK: - WhisperModelVariant

enum WhisperModelVariant: String, CaseIterable, Identifiable {
    case largev3Turbo = "openai_whisper-large-v3-turbo"
    case largev3      = "openai_whisper-large-v3"
    case medium       = "openai_whisper-medium"
    case small        = "openai_whisper-small"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .largev3Turbo: return "Large v3 Turbo (recommended)"
        case .largev3:      return "Large v3 (max accuracy)"
        case .medium:       return "Medium (balanced)"
        case .small:        return "Small (fastest)"
        }
    }

    /// Approximate model download size on disk.
    var approximateSizeGB: Double {
        switch self {
        case .largev3Turbo: return 1.5
        case .largev3:      return 3.1
        case .medium:       return 0.7
        case .small:        return 0.25
        }
    }
}

// MARK: - AudioSource

enum AudioSource: String, CaseIterable, Identifiable {
    case speakerTrack = "speakerTrack"
    case micTrack     = "micTrack"
    case mixedTrack   = "mixedTrack"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speakerTrack: return "Speaker Audio (recommended)"
        case .micTrack:     return "Microphone"
        case .mixedTrack:   return "Mixed (speaker + mic)"
        }
    }
}

// MARK: - TranscriptFormat

enum TranscriptFormat: String, CaseIterable, Identifiable {
    case txt  = "txt"
    case json = "json"
    case srt  = "srt"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .txt:  return "Plain text (.txt)"
        case .json: return "JSON with timestamps (.json)"
        case .srt:  return "Subtitles (.srt)"
        }
    }
}

// MARK: - TranscriptionPreferences

/// UserDefaults-backed transcription settings. Observe via @ObservedObject or @StateObject.
final class TranscriptionPreferences: ObservableObject {

    // MARK: Stored properties

    @AppStorage("transcription.enabled")
    var enabled: Bool = true

    @AppStorage("transcription.modelRaw")
    private var modelRaw: String = WhisperModelVariant.largev3Turbo.rawValue

    /// ISO 639-1 language code override (e.g. "en", "fr"). Empty string = auto-detect.
    @AppStorage("transcription.language")
    var language: String = ""

    /// Number of speakers hint. 0 = auto-detect (1–8).
    @AppStorage("transcription.numSpeakers")
    var numSpeakers: Int = 0

    @AppStorage("transcription.audioSourceRaw")
    private var audioSourceRaw: String = AudioSource.speakerTrack.rawValue

    @AppStorage("transcription.formats.txt")
    var writeTxt: Bool = true

    @AppStorage("transcription.formats.json")
    var writeJson: Bool = true

    @AppStorage("transcription.formats.srt")
    var writeSrt: Bool = true

    // MARK: Computed properties with enum types

    var model: WhisperModelVariant {
        get { WhisperModelVariant(rawValue: modelRaw) ?? .largev3Turbo }
        set { modelRaw = newValue.rawValue }
    }

    var audioSource: AudioSource {
        get { AudioSource(rawValue: audioSourceRaw) ?? .speakerTrack }
        set { audioSourceRaw = newValue.rawValue }
    }

    var outputFormats: Set<TranscriptFormat> {
        var formats: Set<TranscriptFormat> = []
        if writeTxt  { formats.insert(.txt) }
        if writeJson { formats.insert(.json) }
        if writeSrt  { formats.insert(.srt) }
        return formats
    }
}
