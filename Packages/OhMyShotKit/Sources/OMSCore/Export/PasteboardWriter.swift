import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Puts captures on the clipboard.
///
/// PNG goes on eagerly; TIFF, which some older apps read instead, is produced only if an app asks for
/// it, because a full-display TIFF is tens of megabytes. Until then only the PNG is held, never the picture's
/// pixels, which for a long scrolling capture are hundreds of megabytes; past `largestTIFF` pixels no TIFF is
/// offered at all. Once made, the TIFF stays in the app for as long as the capture is on the clipboard, so it
/// is compressed (LZW, which every TIFF reader takes): an interface's screenshot comes to a tenth of its pixels'
/// size or less, a photo's to about a third, for 0.3–0.8 s on the main thread at a 6K display's size.
public enum PasteboardWriter {
    /// The most pixels a picture offered as TIFF may have: about a 6K display's.
    static let largestTIFF = 24_000_000

    /// - Parameters:
    ///   - png: the capture, already encoded.
    ///   - fileURL: also offered as a file when given, for apps that paste files rather than images.
    ///   - pasteboard: the clipboard; scripted checks and tests write to one of their own.
    @MainActor
    public static func write(png: Data, image: CGImage, fileURL: URL? = nil, to pasteboard: NSPasteboard = .general) {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if image.width * image.height <= largestTIFF {
            item.setDataProvider(LazyTIFFProvider(png: png), forTypes: [.tiff])
        }
        if let fileURL {
            item.setString(fileURL.absoluteString, forType: .fileURL)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    /// Puts a file on the clipboard, as Finder's Copy does: a recording, which pastes into chats, mail,
    /// and upload forms as the file.
    @MainActor
    public static func write(fileURL: URL, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
    }

    /// Puts several files on the clipboard, as Finder's Copy does with a selection.
    @MainActor
    public static func write(fileURLs: [URL], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects(fileURLs.map { $0 as NSURL })
    }
}

private final class LazyTIFFProvider: NSObject, NSPasteboardItemDataProvider {
    /// TIFF's compression tag for LZW.
    private static let lzw = 5

    private let png: Data

    init(png: Data) {
        self.png = png
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.tiff.identifier as CFString, 1, nil) else { return }
        let compressed = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: Self.lzw]] as CFDictionary
        CGImageDestinationAddImage(destination, image, compressed)
        guard CGImageDestinationFinalize(destination) else { return }
        item.setData(data as Data, forType: .tiff)
    }
}
