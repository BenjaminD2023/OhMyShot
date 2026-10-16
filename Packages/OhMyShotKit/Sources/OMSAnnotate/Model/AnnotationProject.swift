import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A capture with its marks in one file, opened again with every mark still editable: the capture as it
/// was taken, the document, and every picture the document uses (a background's, combined images), so
/// the file can travel to another Mac.
///
/// A binary property list, so the pictures are kept as they are rather than spelled out in text.
nonisolated public struct AnnotationProject: Sendable {
    public static let fileExtension = "ohmyshot"
    /// The newest format this version reads and writes. Format 2 adds what an earlier version would read
    /// wrongly or not at all: a capture turned, flipped, or resized, combined images turned with it, and
    /// highlight boxes.
    static let version = 2

    /// The oldest format that holds `document`, so a project nothing new is in is still read by an earlier
    /// version, and one it would misread is refused there rather than opened wrong and written over.
    static func version(for document: AnnotationDocument) -> Int {
        let usesNewer = document.transform != nil || document.items.contains { item in
            switch item.shape {
            case .highlightBox: true
            case .image(let image): image.orientation != nil
            default: false
            }
        }
        return usesNewer ? 2 : 1
    }

    /// The project file type: the one the app declares, or one made from the extension.
    public static var contentType: UTType {
        UTType(filenameExtension: fileExtension, conformingTo: .data) ?? .data
    }

    public enum ReadError: LocalizedError {
        case newerVersion
        case unreadableCapture

        public var errorDescription: String? {
            switch self {
            case .newerVersion: String(localized: "This project was made by a newer version of OhMyShot.", bundle: .module)
            case .unreadableCapture: String(localized: "The capture in this project can't be read.", bundle: .module)
            }
        }
    }

    /// The capture as it was taken.
    public var capture: CGImage
    public var document: AnnotationDocument
    /// The capture already encoded, as a project read from a file has it: written again as it is.
    public var capturePNG: Data?

    public init(capture: CGImage, document: AnnotationDocument, capturePNG: Data? = nil) {
        self.capture = capture
        self.document = document
        self.capturePNG = capturePNG
    }

    private struct Contents: Codable {
        var version: Int
        /// The capture, as PNG.
        var capture: Data
        var document: AnnotationDocument
        /// Every picture the document uses, by its name in the picture store.
        var pictures: [String: Data]
    }

    /// The names of the pictures `document` uses.
    static func pictureNames(of document: AnnotationDocument) -> Set<String> {
        var names = Set<String>()
        if case .picture(let name) = document.backdrop?.fill { names.insert(name) }
        for item in document.items {
            if case .image(let image) = item.shape { names.insert(image.name) }
        }
        return names
    }

    /// The project as a file's contents. Pictures missing from `store` are left out; they draw as their
    /// stand-ins when the project opens.
    public func data(pictures store: PictureStore = .shared) throws -> Data {
        let png = try capturePNG ?? Self.png(capture)
        var pictures: [String: Data] = [:]
        for name in Self.pictureNames(of: document) {
            pictures[name] = try? Data(contentsOf: store.url(named: name))
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(Contents(version: Self.version(for: document), capture: png, document: document, pictures: pictures))
    }

    private static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    public func write(to url: URL, pictures store: PictureStore = .shared) throws {
        try data(pictures: store).write(to: url, options: .atomic)
    }

    /// Reads a project, putting the pictures it carries into `store` where they are missing.
    public static func read(from url: URL, pictures store: PictureStore = .shared) throws -> AnnotationProject {
        try read(Data(contentsOf: url), pictures: store)
    }

    public static func read(_ data: Data, pictures store: PictureStore = .shared) throws -> AnnotationProject {
        let contents = try PropertyListDecoder().decode(Contents.self, from: data)
        guard contents.version <= version else { throw ReadError.newerVersion }
        guard
            let source = CGImageSourceCreateWithData(contents.capture as CFData, nil),
            let capture = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw ReadError.unreadableCapture }
        for (name, picture) in contents.pictures where !store.contains(name) {
            // Kept under the name the document uses, which is the one its contents give anyway.
            let kept = try store.add(picture, fileExtension: (name as NSString).pathExtension)
            if kept != name {
                try? FileManager.default.copyItem(at: store.url(named: kept), to: store.url(named: name))
            }
        }
        return AnnotationProject(capture: capture, document: contents.document, capturePNG: contents.capture)
    }
}
