import Foundation

/// A Studio recording's project, kept beside it in the history, and the movie exported from Studio that takes the
/// recording's place.
extension HistoryStore {
    /// A Studio recording's project, a folder beside it: what the pointer did while recording, the source
    /// movie once an export has taken its place, and the Studio window's settings.
    public func studioURL(for item: HistoryItem) -> URL {
        directory.appending(path: "\(item.fileName).studio", directoryHint: .isDirectory)
    }

    public func hasStudioProject(_ item: HistoryItem) -> Bool {
        FileManager.default.fileExists(atPath: studioURL(for: item).path(percentEncoded: false))
    }

    /// The Studio recording as it was made, kept in its project for Studio to film again.
    public func studioSourceURL(for item: HistoryItem) -> URL {
        studioURL(for: item).appending(path: "source.mp4")
    }

    /// The Studio recording as it was made, copied into its project (a clone, which takes no room) the first
    /// time it is asked for, while the history still holds it. Studio films that copy, which never moves, so
    /// a movie exported into the history while the Studio window is open never becomes what it films.
    public func studioSource(for item: HistoryItem) throws -> URL {
        let source = studioSourceURL(for: item)
        guard !FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else { return source }
        // Once a movie has taken its place, the history no longer holds the recording as it was made.
        guard !hasStudioMovie(item) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: studioURL(for: item), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fileURL(for: item), to: source)
        return source
    }

    /// Whether a movie exported from Studio has taken the recording's place in the history.
    public func hasStudioMovie(_ item: HistoryItem) -> Bool {
        FileManager.default.fileExists(atPath: studioMovieMarkerURL(for: item).path(percentEncoded: false))
    }

    /// Keeps a movie exported from Studio, the file at `exported` (moved in), in place of the recording, which
    /// stays in its project (see `studioSource(for:)`), and `project`, the settings it was made with, beside
    /// it. Returns the record with the movie's size and length.
    @discardableResult
    public func replaceStudioMovie(
        of item: HistoryItem, withFileAt exported: URL, pixelWidth: Int, pixelHeight: Int, duration: TimeInterval, project: Data
    ) throws -> HistoryItem {
        _ = try studioSource(for: item)
        try FileManager.default.removeItem(at: fileURL(for: item))
        try FileManager.default.moveItem(at: exported, to: fileURL(for: item))
        try project.write(to: studioMovieMarkerURL(for: item), options: .atomic)
        return try updated(item, pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: duration)
    }

    /// The settings the movie in the history was made with, when one exported from Studio is there: the
    /// Studio window compares them with the project's to know whether the movie is still its own.
    public func studioMovieProject(of item: HistoryItem) -> Data? {
        try? Data(contentsOf: studioMovieMarkerURL(for: item))
    }

    /// In the project, there once a movie exported from Studio has taken the recording's place: the settings
    /// that movie was made with.
    private func studioMovieMarkerURL(for item: HistoryItem) -> URL {
        studioURL(for: item).appending(path: "exported.json")
    }
}
