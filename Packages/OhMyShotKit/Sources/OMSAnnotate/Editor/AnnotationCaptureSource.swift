import CoreGraphics
import Foundation
import ImageIO
import OMSCore

nonisolated public struct AnnotationCaptureSource: Sendable {
    public let image: CGImage
    public let document: AnnotationDocument?
    public let requiresFlattenedCopy: Bool

    @concurrent public static func load(_ item: HistoryItem, from history: HistoryStore) async -> Self? {
        func image(at url: URL) -> CGImage? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        let annotations = history.annotationsURL(for: item)
        let marked = history.hasOriginal(item) || FileManager.default.fileExists(atPath: annotations.path(percentEncoded: false))
        if marked, let data = try? Data(contentsOf: annotations),
           let document = try? JSONDecoder().decode(AnnotationDocument.self, from: data),
           Self.canOpen(document),
           let original = image(at: history.originalURL(for: item)),
           document.pixelSize == CGSize(width: original.width, height: original.height) {
            return Self(image: original, document: document, requiresFlattenedCopy: false)
        }
        guard let flattened = image(at: history.fileURL(for: item)) else { return nil }
        return Self(image: flattened, document: nil, requiresFlattenedCopy: marked)
    }

    private static func canOpen(_ document: AnnotationDocument) -> Bool {
        func valid(_ rect: CGRect) -> Bool {
            rect.size.width > 0 && rect.size.height > 0 && rect.maxX.isFinite && rect.maxY.isFinite
        }
        guard !document.isEmpty, document.scale.isFinite, document.scale > 0, valid(document.canvas), valid(document.imageBounds),
              AnnotationRenderer.bitmapDimensions(for: document.canvas.integral.size) != nil,
              Set(document.items.map(\.id)).count == document.items.count else { return false }
        if let size = document.transform?.size, !AnnotationDocument.fitsPixelBudget(size) { return false }
        return document.items.allSatisfy {
            if case .redaction(let redaction) = $0.shape { return valid(redaction.rect.standardized) }
            return true
        }
    }

    @concurrent public func itemForEditing(_ item: HistoryItem, in history: HistoryStore) async throws -> HistoryItem {
        guard requiresFlattenedCopy else { return item }
        let png = try await ImageExporter.encode(image, as: .png)
        return try history.add(
            data: png, name: (item.fileName as NSString).deletingPathExtension, fileExtension: "png", kind: .screenshot,
            pixelWidth: image.width, pixelHeight: image.height, appName: item.appName, pixelsPerPoint: item.pixelsPerPoint,
            windowTitle: item.windowTitle
        )
    }
}

nonisolated extension AnnotationDocument {
    static func fitsPixelBudget(_ size: CGSize) -> Bool {
        (1...CGFloat(maxPictureSide)).contains(size.width) && (1...CGFloat(maxPictureSide)).contains(size.height)
            && size.width * size.height <= CGFloat(maxPictureArea)
    }
}
