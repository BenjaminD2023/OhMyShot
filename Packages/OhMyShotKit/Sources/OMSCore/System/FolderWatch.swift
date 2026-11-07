import Darwin
import Dispatch
import Foundation

/// Tells when a folder's entries change, or when the folder itself is removed or moved. It runs on kernel events,
/// so an unchanged folder costs nothing. Once the folder is gone the watch ends; start a new one on the folder made
/// in its place.
public final class FolderWatch: Sendable {
    private let source: any DispatchSourceFileSystemObject

    /// Nil when the folder can't be opened, for example when it isn't there. `changed` is told whether the folder is
    /// gone, on `queue`.
    public init?(folder: URL, queue: DispatchQueue = .main, changed: @escaping @Sendable (_ gone: Bool) -> Void) {
        let descriptor = open(folder.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke], queue: queue)
        source.setEventHandler { [weak source] in
            guard let source else { return }
            let gone = !source.data.isDisjoint(with: [.delete, .rename, .revoke])
            if gone { source.cancel() }
            changed(gone)
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    public func stop() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
