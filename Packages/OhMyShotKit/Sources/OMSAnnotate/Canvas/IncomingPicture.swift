import AppKit
import ImageIO
import OMSCore
import UniformTypeIdentifiers

/// A drag source that hands on a whole capture as it is, as the editor's drag-out handle does: never a picture to
/// combine into a capture, in its own editor's canvas or any other.
protocol CaptureDragSource: AnyObject {}

/// A picture coming in to be combined: its name in the picture store, its size in pixels, and its
/// pixels per point.
struct IncomingPicture {
    let name: String
    let pixelSize: CGSize
    let scale: CGFloat

    /// Whether a pasteboard offers pictures, without reading them.
    static func isOffered(by pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: imageFileOptions)
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    private static let imageFileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    /// The pictures a pasteboard offers, kept in the picture store: image files, or else image data.
    static func keep(from pasteboard: NSPasteboard) -> [IncomingPicture] {
        var names: [String] = []
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: imageFileOptions) as? [URL] ?? []
        for url in urls {
            if let name = try? PictureStore.shared.add(url) { names.append(name) }
        }
        if names.isEmpty, let data = pasteboard.data(forType: .png) {
            if let name = try? PictureStore.shared.add(data, fileExtension: "png") { names.append(name) }
        } else if names.isEmpty, let data = pasteboard.data(forType: .tiff),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            // Kept as PNG: pasteboard TIFF is uncompressed.
            if let name = try? PictureStore.shared.add(image) { names.append(name) }
        }
        return describe(names)
    }

    /// Picture files, kept in the picture store.
    static func keep(_ urls: [URL]) -> [IncomingPicture] {
        describe(urls.compactMap { try? PictureStore.shared.add($0) })
    }

    private static func describe(_ names: [String]) -> [IncomingPicture] {
        names.compactMap { name in
            guard let size = PictureStore.shared.pixelSize(named: name) else { return nil }
            return IncomingPicture(name: name, pixelSize: size, scale: resolution(of: name) ?? 0)
        }
    }

    /// Pixels per point a picture records, or nil when it records none (72 dpi).
    private static func resolution(of name: String) -> CGFloat? {
        guard
            let source = CGImageSourceCreateWithURL(PictureStore.shared.url(named: name) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let pixelsPerPoint = ImageLoader.pixelsPerPoint(of: source)
        else { return nil }
        return CGFloat(pixelsPerPoint)
    }
}
