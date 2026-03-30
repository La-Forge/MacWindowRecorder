import Foundation

/// Groups the output file URLs produced by a single recording session.
struct RecordingFiles {
    /// Main MP4 with video + 3 audio tracks (mixed, speaker, mic).
    let videoURL: URL
    /// Microphone-only M4A export.
    let micURL: URL
    /// Speaker-only M4A export.
    let speakerURL: URL
    /// Timestamp of the recording (used for naming transcript files).
    let date: Date
}
