import CoreGraphics
import Foundation
import OMSCore

nonisolated public enum CaptureRendition {
    @concurrent public static func render(
        marks: AnnotationDocument, adding backdrop: Backdrop?, to base: CGImage
    ) async throws -> (image: CGImage, document: Data)? {
        func render(_ document: AnnotationDocument) throws -> (image: CGImage, document: Data) {
            guard let image = AnnotationRenderer.flatten(document, base: base) else { throw ImageExporter.ExportError.cannotEncode }
            return (image, try JSONEncoder().encode(document))
        }

        if marks.backdrop == nil, let backdrop {
            var decorated = marks
            decorated.backdrop = backdrop
            if let rendered = try? render(decorated) { return rendered }
        }
        guard !marks.isEmpty else { return nil }
        return try render(marks)
    }
}
