import AppKit
import OMSCore
import UniformTypeIdentifiers

/// The system's Save panel for a capture, shown from the run loop.
public enum SavePanel {
    /// Asks where to save a copy. The first of `types` is the file's default type; a name typed with another of them
    /// is kept, so a screenshot saved as HEIC can be saved as `.png` by naming it so.
    /// - Parameters:
    ///   - name: the file's name, without its extension.
    ///   - directory: where the panel opens.
    /// - Returns: the place chosen, or nil when the person cancelled.
    public static func ask(name: String, types: [UTType], directory: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            // From the run loop, as a menu's action would run it: inside a task a modal panel would hold every other
            // task on the main actor until it closed.
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    continuation.resume(returning: run(name: name, types: types, directory: directory))
                }
            }
        }
    }

    private static func run(name: String, types: [UTType], directory: URL) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = defaultFileName(name: name, type: types.first)
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// The name the panel starts with: `name` and the extension of `type`. A screenshot's is the one every other way of
    /// saving it uses ("jpg", where the system's preferred extension for JPEG is "jpeg"); another kind of file takes
    /// the system's.
    nonisolated static func defaultFileName(name: String, type: UTType?) -> String {
        let format = ImageExporter.Format.allCases.first { $0.type == type }
        guard let fileExtension = format?.fileExtension ?? type?.preferredFilenameExtension else { return name }
        return "\(name).\(fileExtension)"
    }

    /// The types a screenshot may be saved as, the format Settings choose first.
    public static func pictureTypes(preferring format: ImageExporter.Format) -> [UTType] {
        [format.type] + ImageExporter.Format.allCases.filter { $0 != format }.map(\.type)
    }
}
