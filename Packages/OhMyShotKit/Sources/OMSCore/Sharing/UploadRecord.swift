import Foundation
import Observation
import OSLog

/// One finished upload, kept so its link can be copied again and the file removed from the storage later.
///
/// Records hold no secrets: a link is as private as the file's name in it (random by default), and a ShareX
/// deletion address is the key to the file, which the person already has on their Mac.
public struct UploadRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The capture the file came from, while it is in the history; nil for a file uploaded from elsewhere.
    public var captureID: UUID?
    public var date: Date
    /// The name the file was uploaded under.
    public var fileName: String
    public var destinationID: UUID
    public var destinationName: String
    /// `S3`, `WebDAV` or `Custom HTTP`.
    public var destinationKind: String
    public var link: URL
    public var deletionURL: URL?
    /// When a presigned link stops working; nil for a link that does not expire.
    public var expiresAt: Date?
    /// Where the file is in the storage (an S3 key, or a path below the WebDAV folder), for the kinds that can
    /// be deleted with a signed request.
    public var remoteKey: String?

    public init(
        id: UUID = UUID(),
        captureID: UUID?,
        date: Date,
        fileName: String,
        destination: UploadDestination,
        result: UploadResult
    ) {
        self.id = id
        self.captureID = captureID
        self.date = date
        self.fileName = fileName
        destinationID = destination.id
        destinationName = destination.name
        destinationKind = destination.kindName
        link = result.link
        deletionURL = result.deletionURL
        expiresAt = result.expiresAt
        remoteKey = result.remoteKey
    }

    public func isExpired(at now: Date = .now) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    /// How the file can be removed from the storage.
    public enum Removal: Equatable, Sendable {
        /// A signed DELETE sent to the destination; it has to still exist.
        case request
        /// The address the server gave for deleting, opened in the browser as ShareX does.
        case openAddress(URL)
    }

    public var removal: Removal? {
        if remoteKey != nil { return .request }
        if let deletionURL { return .openAddress(deletionURL) }
        return nil
    }
}

/// The finished uploads, newest first, saved as JSON beside the history.
///
/// The file is small (a few hundred records at most), read once when the store is made and written whole
/// after each change, so nothing here runs between uploads.
@MainActor
@Observable
public final class UploadRecordStore {
    public private(set) var records: [UploadRecord]

    @ObservationIgnored private let fileURL: URL?
    /// The most records kept; older ones are dropped as new ones arrive.
    public static let limit = 300

    /// - Parameter fileURL: nil keeps records in memory only, for tests.
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        records = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? Self.decoder.decode([UploadRecord].self, from: $0) } ?? []
        records.sort { $0.date > $1.date }
    }

    /// The standard location: Application Support, under this build's bundle identifier, beside the history.
    public static func standard() -> UploadRecordStore {
        let base = URL.applicationSupportDirectory.appending(path: Log.subsystem, directoryHint: .isDirectory)
        return UploadRecordStore(fileURL: base.appending(path: "Uploads.json"))
    }

    public func add(_ record: UploadRecord) {
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        // Newest first by when the upload happened, whatever order they are added in.
        records.sort { $0.date > $1.date }
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        save()
    }

    public func record(id: UUID) -> UploadRecord? {
        records.first { $0.id == id }
    }

    /// The newest record of a capture's uploads.
    public func latest(for captureID: UUID) -> UploadRecord? {
        records.first { $0.captureID == captureID }
    }

    /// The link of the capture's newest upload that still works.
    public func link(for captureID: UUID, at now: Date = .now) -> URL? {
        records.first { $0.captureID == captureID && !$0.isExpired(at: now) }?.link
    }

    /// The newest upload of the capture that can be removed from its storage.
    public func removable(for captureID: UUID) -> UploadRecord? {
        records.first { $0.captureID == captureID && $0.removal != nil }
    }

    public func forget(id: UUID) {
        guard records.contains(where: { $0.id == id }) else { return }
        records.removeAll { $0.id == id }
        save()
    }

    public func forgetAll() {
        guard !records.isEmpty else { return }
        records = []
        save()
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            Log.upload.error("Saving the upload records failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
