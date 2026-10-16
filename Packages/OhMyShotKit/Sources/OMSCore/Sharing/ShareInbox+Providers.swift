import Foundation
import UniformTypeIdentifiers

/// Reading what another app shares: an item provider holds a picture as data, as a file, or as the address
/// of a file (Finder shares those).
extension NSItemProvider {
    /// Whether this item may hold a picture, judged by its types alone.
    public var mayHoldPicture: Bool {
        registersPictureType || hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    /// Whether this item says it is a picture.
    public var registersPictureType: Bool {
        registeredContentTypes.contains { $0.conforms(to: .image) }
    }

    /// Whether this item is a picture: it says so, or it is the address of a file named like one. Finder shares
    /// its files that second way as well, and a folder or a document is not counted for a picture.
    public func holdsPicture() async -> Bool {
        if registersPictureType { return true }
        guard hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return false }
        guard let file = try? await fileURL() else { return false }
        return ImageLoader.canLoad(file)
    }

    /// The file this item is the address of.
    fileprivate func fileURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                if let error { return continuation.resume(throwing: error) }
                switch item {
                case let url as URL: continuation.resume(returning: url)
                case let data as Data: continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }
}

extension ShareInbox.Batch {
    /// Copies the picture an item provider holds into the batch, and returns where it went; nil when the item
    /// is not a picture. A picture the system hands over as a temporary file is copied before that file goes.
    public func addPicture(from provider: NSItemProvider) async throws -> URL? {
        if let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) }) {
            return try await copyFile(of: provider, as: type)
        }
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        guard let file = try await provider.fileURL(), ImageLoader.canLoad(file) else { return nil }
        // The file arrives with the extension's access to it (a scoped one, if the system gave it so); the
        // picture is copied out while that holds.
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        return try store(copyOf: file)
    }

    private func copyFile(of provider: NSItemProvider, as type: UTType) async throws -> URL {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { file, error in
                guard let file else { return continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                // The system deletes the file when this returns, so it is copied now.
                continuation.resume(with: Result { try self.store(copyOf: file, named: suggestedName ?? file.lastPathComponent, type: type) })
            }
        }
    }
}
