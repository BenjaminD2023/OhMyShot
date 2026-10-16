import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes captures and writes them to disk with ImageIO.
///
/// ScreenCaptureKit can write files itself (`SCScreenshotConfiguration.fileURL`), but on macOS 27.2 beta
/// it treats that URL as a directory and fails; ImageIO also gives control over format options.
public enum ImageExporter {
    public enum Format: String, CaseIterable, Sendable {
        case png
        case jpeg
        case heic

        public var type: UTType {
            switch self {
            case .png: .png
            case .jpeg: .jpeg
            case .heic: .heic
            }
        }

        public var fileExtension: String {
            switch self {
            case .png: "png"
            case .jpeg: "jpg"
            case .heic: "heic"
            }
        }
    }

    public enum ExportError: Error, Equatable, Sendable {
        case cannotEncode
        case cannotRead
    }

    /// Encodes an image. Large captures take tens of milliseconds, so this runs off the main actor.
    @concurrent
    public static func encode(_ image: CGImage, as format: Format, quality: Double = 0.9) async throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, format.type.identifier as CFString, 1, nil) else {
            throw ExportError.cannotEncode
        }
        var properties: [CFString: Any] = [:]
        if format != .png {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.cannotEncode }
        return data as Data
    }

    /// Writes encoded data atomically, so a reader never sees a half-written file.
    public static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// Encodes and writes in one step.
    public static func write(_ image: CGImage, to url: URL, format: Format, quality: Double = 0.9) async throws {
        try write(try await encode(image, as: format, quality: quality), to: url)
    }

    /// A file URL in `directory` named `name.ext` that does not exist yet: "name (2).ext" and so on.
    public static func availableURL(in directory: URL, name: String, format: Format) -> URL {
        availableURL(in: directory, name: name, fileExtension: format.fileExtension)
    }

    /// The same for any kind of file, a recording's included.
    public static func availableURL(in directory: URL, name: String, fileExtension: String) -> URL {
        var candidate = directory.appending(path: "\(name).\(fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = directory.appending(path: "\(name) (\(counter)).\(fileExtension)")
            counter += 1
        }
        return candidate
    }
}
