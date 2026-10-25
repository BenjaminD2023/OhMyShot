import Foundation

/// Serializes project snapshots off the main actor. There is no suspension between checking a revision
/// and replacing its file, so an older snapshot can never overwrite a newer one.
actor StudioProjectWriter {
    typealias Write = @Sendable (Data, URL) throws -> Void

    private var writtenRevision = -1
    private let write: Write

    init(write: @escaping Write = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }) {
        self.write = write
    }

    func save(_ project: StudioProject, revision: Int, to url: URL) throws {
        guard revision > writtenRevision else { return }
        let data = try JSONEncoder().encode(project)
        try write(data, url)
        writtenRevision = revision
    }
}

/// Selection belongs to the document rather than to separate controls. Choosing a range also lets go of
/// any zoom, cut or camera layout, whichever input method made the choice.
nonisolated public enum StudioSelection: Equatable, Sendable {
    case none
    case range(ClosedRange<Double>)
    case zoom(UUID)
    case cut(Double)
    case cameraSegment(UUID)
}

/// Only values which affect motion in recording time. Appearance, cuts, and preview resolution do not.
nonisolated struct StudioMotionKey: Equatable, Sendable {
    struct Zoom: Equatable, Sendable {
        let start: Double
        let end: Double
        let scale: Double
    }

    let smoothing: Double
    let hidesWhenIdle: Bool
    let hidesWhileTyping: Bool
    let zooms: [Zoom]

    init(_ project: StudioProject) {
        smoothing = min(max(project.cursor.smoothing, 0), 1)
        hidesWhenIdle = project.cursor.hidesWhenIdle
        hidesWhileTyping = project.cursor.hidesWhileTyping
        zooms = project.zooms.map { Zoom(start: $0.start, end: $0.end, scale: $0.scale) }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.scale < $1.scale
        }
    }
}
