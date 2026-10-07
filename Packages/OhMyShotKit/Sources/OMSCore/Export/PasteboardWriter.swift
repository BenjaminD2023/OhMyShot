import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Puts captures on the clipboard.
///
/// PNG goes on eagerly; TIFF, which some older apps read instead, is produced only if an app asks for
/// it, because a full-display TIFF is tens of megabytes.
public enum PasteboardWriter {
    /// - Parameters:
    ///   - png: the capture, already encoded.
    ///   - fileURL: also offered as a file when given, for apps that paste files rather than images.
    @MainActor
    public static func write(png: Data, image: CGImage, fileURL: URL? = nil) {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setDataProvider(LazyTIFFProvider(image: image), forTypes: [.tiff])
        if let fileURL {
            item.setString(fileURL.absoluteString, forType: .fileURL)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}

private final class LazyTIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private let image: CGImage

    init(image: CGImage) {
        self.image = image
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.tiff.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        item.setData(data as Data, forType: .tiff)
    }
}
