import CoreGraphics
import Foundation
import ImageIO

/// Several pictures as one PDF, a page each: History's Export as PDF. The pictures are written as every copy that
/// leaves the app is (`PictureExport.prepare`: 1×, sRGB, the border, the watermark Settings add), so a PDF is no way
/// around them.
public enum PDFExport {
    /// How large each page is.
    public enum PageSize: String, CaseIterable, Sendable, Identifiable {
        /// Each page the size of its picture, in points.
        case picture
        /// A4 paper, turned to suit each picture, the picture fitted inside a margin.
        case a4
        /// US Letter paper, the same way.
        case letter

        public var id: String { rawValue }

        /// The paper, upright, in points; nil for pages the size of their pictures.
        public var paper: CGSize? {
            switch self {
            case .picture: nil
            case .a4: CGSize(width: 595.28, height: 841.89)
            case .letter: CGSize(width: 612, height: 792)
            }
        }
    }

    /// The margin round a picture on paper, in points: half an inch.
    public static let margin: CGFloat = 36

    public struct Page: @unchecked Sendable {
        public var image: CGImage
        /// Its pixels per point; nil when unknown, which is taken as one.
        public var pixelsPerPoint: Double?

        public init(image: CGImage, pixelsPerPoint: Double?) {
            self.image = image
            self.pixelsPerPoint = pixelsPerPoint
        }

        /// The picture's size in points.
        public var size: CGSize {
            let scale = max(pixelsPerPoint ?? 1, 0.01)
            return CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        }
    }

    public enum ExportError: Error {
        case nothingToWrite
        case cannotRead(URL)
        case cannotWrite
    }

    /// A page for a picture of `size` points, and where the picture is drawn on it (y up, as PDF has it). On paper the
    /// page is turned to the picture's shape and the picture fitted inside the margin, never enlarged, and centered.
    public static func layout(pictureSize size: CGSize, pageSize: PageSize) -> (page: CGRect, picture: CGRect) {
        guard var paper = pageSize.paper else {
            let page = CGRect(origin: .zero, size: CGSize(width: max(size.width, 1), height: max(size.height, 1)))
            return (page, page)
        }
        if size.width > size.height { paper = CGSize(width: paper.height, height: paper.width) }
        let room = CGSize(width: paper.width - margin * 2, height: paper.height - margin * 2)
        let scale = size.width > 0 && size.height > 0 ? min(1, room.width / size.width, room.height / size.height) : 1
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let picture = CGRect(x: (paper.width - drawn.width) / 2, y: (paper.height - drawn.height) / 2, width: drawn.width, height: drawn.height)
        return (CGRect(origin: .zero, size: paper), picture)
    }

    /// The PDF of `pages`, one picture a page, as they are given.
    public static func data(_ pages: [Page], pageSize: PageSize, title: String? = nil) throws -> Data {
        guard !pages.isEmpty else { throw ExportError.nothingToWrite }
        let data = NSMutableData()
        var info: [CFString: Any] = [kCGPDFContextCreator: "OhMyShot"]
        if let title { info[kCGPDFContextTitle] = title }
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, info as CFDictionary)
        else { throw ExportError.cannotWrite }
        for page in pages {
            let (box, picture) = layout(pictureSize: page.size, pageSize: pageSize)
            var mediaBox = box
            let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size) as CFData
            context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            context.interpolationQuality = .high
            context.draw(page.image, in: picture)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Reads each file, writes it as `output` has every copy written, and makes the PDF of them, off the main actor.
    /// `files` are the pictures in the order they are to appear, each with its pixels per point (nil to read it from
    /// the file).
    @concurrent
    public static func data(
        ofFiles files: [(url: URL, pixelsPerPoint: Double?)], output: ScreenshotOutput, pageSize: PageSize, title: String? = nil
    ) async throws -> Data {
        var pages: [Page] = []
        for file in files {
            guard let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { throw ExportError.cannotRead(file.url) }
            let prepared = PictureExport.prepare(image, pixelsPerPoint: file.pixelsPerPoint ?? ImageLoader.pixelsPerPoint(of: source), output: output)
            pages.append(Page(image: prepared.image, pixelsPerPoint: prepared.pixelsPerPoint))
        }
        return try data(pages, pageSize: pageSize, title: title)
    }
}
