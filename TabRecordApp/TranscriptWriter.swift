import Foundation

// MARK: - TranscriptWriter

/// Serialises `SegmentAligner.AttributedSegment` data to TXT, JSON, and SRT files.
struct TranscriptWriter {

    // MARK: - Public API

    /// Writes the requested output formats to disk alongside the recording.
    ///
    /// - Parameters:
    ///   - segments: Speaker-attributed segments from `SegmentAligner`.
    ///   - date: Recording timestamp — used to generate matching filenames.
    ///   - language: Detected or user-specified ISO 639-1 language code.
    ///   - formats: Which file formats to write.
    /// - Returns: URLs of all files that were written.
    @discardableResult
    func write(
        segments: [SegmentAligner.AttributedSegment],
        date: Date,
        language: String,
        formats: Set<TranscriptFormat>
    ) throws -> [URL] {
        var written: [URL] = []

        if formats.contains(.txt) {
            let url = OutputFileNamer.makeTranscriptURL(date: date, ext: "txt")
            let content = formatTxt(segments: segments)
            try content.write(to: url, atomically: true, encoding: .utf8)
            written.append(url)
        }

        if formats.contains(.json) {
            let url = OutputFileNamer.makeTranscriptURL(date: date, ext: "json")
            let data = try formatJSON(segments: segments, language: language)
            try data.write(to: url)
            written.append(url)
        }

        if formats.contains(.srt) {
            let url = OutputFileNamer.makeTranscriptURL(date: date, ext: "srt")
            let content = formatSRT(segments: segments)
            try content.write(to: url, atomically: true, encoding: .utf8)
            written.append(url)
        }

        return written
    }

    // MARK: - TXT

    func formatTxt(segments: [SegmentAligner.AttributedSegment]) -> String {
        guard !segments.isEmpty else { return "" }
        var lines: [String] = []
        for seg in segments {
            let header = "[\(formatTimestamp(seg.start)) → \(formatTimestamp(seg.end))] \(seg.speaker):"
            lines.append(header)
            lines.append(seg.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - JSON

    func formatJSON(
        segments: [SegmentAligner.AttributedSegment],
        language: String
    ) throws -> Data {
        let duration = segments.last?.end ?? 0
        let speakers = Array(Set(segments.map(\.speaker))).sorted()

        let jsonSegments: [[String: Any]] = segments.map { seg in
            let words: [[String: Any]] = seg.words.map { w in
                ["word": w.word, "start": w.start, "end": w.end, "probability": w.probability]
            }
            return [
                "start":   seg.start,
                "end":     seg.end,
                "speaker": seg.speaker,
                "text":    seg.text,
                "words":   words
            ]
        }

        let root: [String: Any] = [
            "language": language,
            "duration": duration,
            "speakers": speakers,
            "segments": jsonSegments
        ]

        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - SRT

    func formatSRT(segments: [SegmentAligner.AttributedSegment]) -> String {
        guard !segments.isEmpty else { return "" }

        // Split long segments into subtitle blocks of max ~42 chars / ~7 seconds each.
        let blocks = splitIntoSubtitleBlocks(segments)

        var output: [String] = []
        for (index, block) in blocks.enumerated() {
            output.append("\(index + 1)")
            output.append("\(srtTimecode(block.start)) --> \(srtTimecode(block.end))")
            output.append(block.text)
            output.append("")
        }
        return output.joined(separator: "\n")
    }

    // MARK: - Private helpers

    private struct SubtitleBlock {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    private func splitIntoSubtitleBlocks(
        _ segments: [SegmentAligner.AttributedSegment]
    ) -> [SubtitleBlock] {
        var blocks: [SubtitleBlock] = []
        let maxChars = 84          // 2 lines × 42 chars
        let maxDuration: Double = 7.0

        for seg in segments {
            let speakerPrefix = "[\(seg.speaker)] "
            let words = seg.words
            if words.isEmpty { continue }

            var chunkWords: [SegmentAligner.AttributedWord] = []
            var chunkStart = seg.start

            for word in words {
                chunkWords.append(word)
                let text = speakerPrefix + chunkWords.map(\.word).joined().trimmingCharacters(in: .whitespaces)
                let duration = (chunkWords.last?.end ?? chunkStart) - chunkStart

                if text.count > maxChars || duration > maxDuration {
                    // Flush everything except the last word if we went over.
                    if chunkWords.count > 1 {
                        let flush = Array(chunkWords.dropLast())
                        let flushText = speakerPrefix + flush.map(\.word).joined().trimmingCharacters(in: .whitespaces)
                        blocks.append(SubtitleBlock(
                            start: chunkStart,
                            end: flush.last!.end,
                            text: flushText
                        ))
                        chunkWords = [word]
                        chunkStart = word.start
                    }
                }
            }

            // Flush remaining words.
            if !chunkWords.isEmpty {
                let text = speakerPrefix + chunkWords.map(\.word).joined().trimmingCharacters(in: .whitespaces)
                blocks.append(SubtitleBlock(
                    start: chunkStart,
                    end: chunkWords.last!.end,
                    text: text
                ))
            }
        }
        return blocks
    }

    /// `HH:MM:SS` for TXT headers.
    func formatTimestamp(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = Int(t) / 60 % 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// `HH:MM:SS,mmm` for SRT timecodes.
    func srtTimecode(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = Int(t) / 60 % 60
        let s = Int(t) % 60
        let ms = Int((t - Double(Int(t))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
