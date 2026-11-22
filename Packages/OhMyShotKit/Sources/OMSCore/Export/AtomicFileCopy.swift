import Darwin
import Foundation

/// Saves a movie or other file without removing the user's previous copy before the new one is complete.
/// The staging file is a sibling of the destination, so the final rename stays on one filesystem.
public enum AtomicFileCopy {
    @concurrent
    public static func copy(from source: URL, to destination: URL) async throws {
        try perform(from: source, to: destination, copy: { try FileManager.default.copyItem(at: $0, to: $1) }, checkCancellation: {
            try Task.checkCancellation()
        })
    }

    /// Saves a copy of `source` at `destination`, chosen in a Save panel, and says how it went: a file already there stays
    /// as it was until the copy is whole. Choosing `source` itself leaves it as it is and saves nothing.
    public static func save(_ source: URL, as destination: URL) async -> SaveOutcome {
        await SaveOutcome.saving(into: destination.deletingLastPathComponent()) {
            try refuseSaving(over: source, at: destination)
            try await copy(from: source, to: destination)
            return destination
        }
    }

    /// Throws when `destination` is `source`'s own file, however the folders on its way are written; a link to it is a
    /// file of its own, which the copy replaces, leaving `source` as it is. A capture's file in Capture
    /// History is no copy of it: taken for one, its card would close as saved, and with History off the capture would
    /// then go, taking the only file with it.
    public static func refuseSaving(over source: URL?, at destination: URL) throws {
        guard let source, isSameFile(source, destination) else { return }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
    }

    /// Whether `first` and `second` are one file now, however the folders on their way are written, and in either letter
    /// case on a disk that ignores case; a link to a file is a file of its own. False when either is missing.
    public static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        guard let one = identifier(of: first), let other = identifier(of: second) else { return false }
        return one.isEqual(other)
    }

    private static func identifier(of url: URL) -> (any NSObjectProtocol)? {
        let file = url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: url.lastPathComponent)
        return try? file.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    }

    /// The copy boundary is injectable for partial-write and cancellation tests; the commit always uses
    /// the filesystem's atomic rename, including when a destination already exists.
    static func perform(
        from source: URL, to destination: URL,
        copy: (URL, URL) throws -> Void,
        checkCancellation: () throws -> Void = {}
    ) throws {
        guard source.isFileURL, destination.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        try checkCancellation()
        let staging = destination.deletingLastPathComponent().appending(path: ".ohmyshot-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try copy(source, staging)
        try checkCancellation()
        let result = staging.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return Int32(EINVAL) }
                return Darwin.rename(from, to) == 0 ? 0 : errno
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    }
}
