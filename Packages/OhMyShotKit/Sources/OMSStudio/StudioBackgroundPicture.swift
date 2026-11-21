import CoreGraphics
import Foundation
import ImageIO
import OMSCore
import UniformTypeIdentifiers

/// A picture chosen for a Studio movie's background, kept in the project's folder so it goes wherever the project
/// goes, under a name drawn from its contents, so the same picture chosen twice is kept once. A picture no larger
/// than `largestSide` is kept as it came; a larger one is kept that large, as a background is soft and the movie is
/// never larger than 3840 pixels. It is read no larger than the movie shows it.
nonisolated enum StudioBackgroundPicture {
    /// What every kept picture's name starts with, so the ones no longer used can be told apart.
    static let prefix = "background-"
    /// The longest side a picture is kept at.
    static let largestSide = 4096

    /// Keeps the picture at `url` in `folder`; returns the name it is kept under. Throws when it isn't a picture
    /// that can be read.
    static func keep(_ url: URL, in folder: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = pixelSize(of: source),
              CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(longest: 64)) != nil
        else { throw CocoaError(.fileReadCorruptFile) }
        let data: Data
        let fileExtension: String
        if max(size.width, size.height) <= CGFloat(largestSide), !url.pathExtension.isEmpty {
            data = try Data(contentsOf: url)
            fileExtension = url.pathExtension.lowercased()
        } else {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(longest: largestSide)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
            data = try ImageExporter.encoded(image, as: opaque ? .jpeg : .png)
            fileExtension = opaque ? "jpg" : "png"
        }
        let digest = data.withUnsafeBytes { raw -> UInt64 in
            // FNV-1a, as the editor names its pictures: enough to tell one person's pictures apart.
            raw.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
        }
        let name = prefix + String(format: "%016llx", digest) + "." + fileExtension
        let destination = self.url(named: name, in: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            try data.write(to: destination, options: .atomic)
        }
        return name
    }

    /// Where the picture named `name` is kept: always in `folder` itself, whatever the name says.
    static func url(named name: String, in folder: URL) -> URL {
        folder.appending(path: (name as NSString).lastPathComponent)
    }

    /// The picture named `name`, read just large enough to cover `canvas` (pixels), never larger than it is; nil
    /// when it has gone or can't be read.
    static func image(named name: String, in folder: URL, covering canvas: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url(named: name, in: folder) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = pixelSize(of: source), size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, max(canvas.width / size.width, canvas.height / size.height))
        let longest = max(1, Int((max(size.width, size.height) * scale).rounded(.up)))
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(longest: longest))
    }

    /// The picture named `name` with its longer side `longest` pixels, for the inspector's tile.
    static func thumbnail(named name: String, in folder: URL, longest: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url(named: name, in: folder) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions(longest: longest))
    }

    /// Removes the pictures kept in `folder` but `used`.
    static func removeUnused(in folder: URL, keeping used: (String) -> Bool) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)) else { return }
        for name in names where name.hasPrefix(prefix) && !used(name) {
            try? FileManager.default.removeItem(at: url(named: name, in: folder))
        }
    }

    /// The picture's size in pixels as it shows, turned as its orientation says, without reading its pixels.
    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        // Orientations 5 to 8 turn the picture a quarter.
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    private static func thumbnailOptions(longest: Int) -> CFDictionary {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
    }
}
