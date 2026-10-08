import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pictures a document uses besides the capture: a background's picture and images combined into the
/// capture. Kept in a folder of the app's own under names drawn from their contents, so a document
/// stays whole when the original file moves, and the same picture added twice is kept once.
///
/// Read at the size asked for and remembered, so a slider or a zoom does not read a picture again.
nonisolated public final class PictureStore: @unchecked Sendable {
    /// The app's store: in its Application Support folder, or a temporary one for a process that is
    /// not the app, such as a test run.
    public static var shared: PictureStore {
        storeLock.withLock { current }
    }

    /// Moves the shared store to `directory`, as tests do to keep their pictures out of the app's folder.
    public static func use(_ directory: URL) {
        storeLock.withLock {
            if current.directory != directory { current = PictureStore(directory: directory) }
        }
    }

    private static let storeLock = NSLock()
    nonisolated(unsafe) private static var current = PictureStore(directory: Bundle.main.bundleIdentifier.map {
        URL.applicationSupportDirectory.appending(path: $0, directoryHint: .isDirectory).appending(path: "Pictures", directoryHint: .isDirectory)
    } ?? URL.temporaryDirectory.appending(path: "OhMyShot Pictures", directoryHint: .isDirectory))

    /// A background is soft: 4096 pixels across is plenty, where a larger one would cost a hundred
    /// megabytes.
    public static let backgroundLimit = 4096
    /// Combined images keep every pixel they have, up to this.
    public static let imageLimit = 16384

    public let directory: URL
    private let lock = NSLock()
    private let cache = NSCache<NSString, CGImage>()

    public init(directory: URL) {
        self.directory = directory
        cache.totalCostLimit = 256 << 20
    }

    /// Copies the picture at `url` into the folder; returns the name it is kept under.
    public func add(_ url: URL) throws -> String {
        try add(Data(contentsOf: url), fileExtension: url.pathExtension)
    }

    /// Keeps encoded picture data (PNG, JPEG, HEIC, TIFF…); returns the name it is kept under.
    public func add(_ data: Data, fileExtension: String) throws -> String {
        let digest = data.withUnsafeBytes { raw -> UInt64 in
            // FNV-1a: enough to tell one person's pictures apart.
            raw.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
        }
        let suffix = fileExtension.isEmpty ? "png" : fileExtension.lowercased()
        let name = String(format: "%016llx", digest) + "." + suffix
        let destination = url(named: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            try data.write(to: destination, options: .atomic)
        }
        return name
    }

    /// Keeps an image, as PNG; returns the name it is kept under.
    public func add(_ image: CGImage) throws -> String {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return try add(data as Data, fileExtension: "png")
    }

    public func url(named name: String) -> URL {
        directory.appending(path: (name as NSString).lastPathComponent)
    }

    public func contains(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(named: name).path(percentEncoded: false))
    }

    /// The picture's size in pixels, without reading its pixels.
    public func pixelSize(named name: String) -> CGSize? {
        guard
            let source = CGImageSourceCreateWithURL(url(named: name) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        // Orientations 5 to 8 turn the picture a quarter.
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// The picture, scaled so its longer side is at least `longest` pixels where it has them, and at
    /// most `limit`. Read in steps of powers of two.
    public func image(named name: String, fitting longest: Int, limit: Int) -> CGImage? {
        var size = 256
        while size < longest, size < limit { size *= 2 }
        size = min(size, limit)
        let key = "\(name)@\(size)" as NSString
        lock.lock()
        let cached = cache.object(forKey: key)
        lock.unlock()
        if let cached { return cached }
        guard
            let source = CGImageSourceCreateWithURL(url(named: name) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        else { return nil }
        lock.lock()
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        lock.unlock()
        return image
    }
}
