import Foundation

/// Produces output file URLs for TabRecord recordings.
///
/// Extracted from `MenuBarController` so the naming logic can be
/// unit-tested independently of AppKit.
enum OutputFileNamer {

    // MARK: - Public API

    /// Returns a URL for a new recording file, stamped with `date`.
    ///
    /// Example: `~/Movies/TabRecord/tabrecord-2026-03-13-143005.mp4`
    static func makeURL(date: Date = Date()) -> URL {
        let name = "tabrecord-\(formatter.string(from: date)).mp4"
        return recordingsDirectory().appendingPathComponent(name)
    }

    /// The directory where recordings are stored.
    static func recordingsDirectory() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return movies.appendingPathComponent("TabRecord")
    }

    // MARK: - Private

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
