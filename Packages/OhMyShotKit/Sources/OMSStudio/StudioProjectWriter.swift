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
