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
