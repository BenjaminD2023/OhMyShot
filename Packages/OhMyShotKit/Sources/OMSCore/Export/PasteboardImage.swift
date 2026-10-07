import AppKit
import UniformTypeIdentifiers

/// An image on a pasteboard: the clipboard, or something being dragged.
public enum PasteboardImage {
    public enum Content: Sendable {
        case file(URL)
        case data(Data)
    }

    /// What a drop target registers for: image files and image data.
    public static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL] + preferredDataTypes

    private static let preferredDataTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier),
    ]

    /// Whether the pasteboard may hold an image, judged by its types alone: reading the types never asks
    /// for clipboard access, reading the contents may.
    public static func mayHoldImage(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains(.fileURL) || dataType(in: types) != nil
    }

    /// Whether the pasteboard holds an image. Reads file URLs, so it is for dragging pasteboards.
    public static func holdsImage(_ pasteboard: NSPasteboard) -> Bool {
        let urls = fileURLs(on: pasteboard)
        guard urls.isEmpty else { return urls.contains(where: ImageLoader.canLoad) }
        return dataType(in: pasteboard.types ?? []) != nil
    }

    /// The image on the pasteboard. A file wins over image data: Finder puts a copied file's icon beside
    /// its URL as TIFF, and the icon is not what the person meant.
    public static func read(_ pasteboard: NSPasteboard) -> Content? {
        let urls = fileURLs(on: pasteboard)
        guard urls.isEmpty else { return urls.first(where: ImageLoader.canLoad).map(Content.file) }
        guard let type = dataType(in: pasteboard.types ?? []), let data = pasteboard.data(forType: type) else { return nil }
        return .data(data)
    }

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        guard pasteboard.types?.contains(.fileURL) == true else { return [] }
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    /// The best image type offered: lossless first, then any other image type except icons.
    private static func dataType(in types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? {
        if let preferred = preferredDataTypes.first(where: types.contains) { return preferred }
        return types.first { type in
            guard let uti = UTType(type.rawValue) else { return false }
            return uti.conforms(to: .image) && !uti.conforms(to: .icns)
        }
    }
}
