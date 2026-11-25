import CoreGraphics
import Foundation
import OMSCore

/// The picture of a project open in the editor, rendered into the caches for dragging out and saving copies. Each opened
/// project gets a folder of its own, so two projects with one name, from two folders, never share a picture; the picture
/// keeps the project's name, which is what a drag hands over. It goes a while after its editor closes.
nonisolated public enum ProjectPicture {
    /// Where the pictures are kept.
    public static var standardFolder: URL {
        AppFolders.caches.appending(path: "Projects", directoryHint: .isDirectory)
    }

    /// How long a picture stays once its editor has closed: an app it was dropped on may read it a little later, as a
    /// mail draft or a browser's upload does.
    public static let lifetimeAfterClosing: Duration = .seconds(300)

    /// Renders `project`'s picture into a new folder of its own, named after the project file at `file`.
    @concurrent
    public static func make(for project: AnnotationProject, from file: URL, in folder: URL = standardFolder) async throws -> URL {
        guard let image = await AnnotationRenderer.render(project.document, base: project.capture) else { throw CocoaError(.fileReadCorruptFile) }
        let data = try await ImageExporter.encode(image, as: .png, pixelsPerPoint: Double(project.document.scale))
        let directory = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let picture = directory.appending(path: file.deletingPathExtension().lastPathComponent + ".png")
        try data.write(to: picture, options: .atomic)
        return picture
    }

    /// Removes a picture `make` made, with its folder, once a drop that took it has had time to read it.
    @discardableResult
    public static func remove(_ picture: URL, after delay: Duration = lifetimeAfterClosing) -> Task<Void, Never> {
        let directory = picture.deletingLastPathComponent()
        return Task.detached(priority: .background) {
            try? await Task.sleep(for: delay)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Removes what an earlier run left in `folder`: the folders of editors closed just before the app quit, and the
    /// pictures older versions kept under the project's name alone. Whatever was made since `start` is an open
    /// editor's, and stays.
    public static func removeLeftovers(before start: Date, in folder: URL = standardFolder) {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        for item in contents {
            guard let made = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, made < start else { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }
}
