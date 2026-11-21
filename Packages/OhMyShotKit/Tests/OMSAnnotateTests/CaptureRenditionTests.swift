import CoreGraphics
import Foundation
import OMSCore
import Testing
@testable import OMSAnnotate

struct CaptureRenditionTests {
    private let base = makeBase(width: 64, height: 40)
    private let oversized = Backdrop(fill: .clear, padding: 0, shadow: 0, ratio: .init(Int.max, 1))

    private var marked: AnnotationDocument {
        let mark = Annotation(shape: .redaction(Redaction(rect: CGRect(x: 10, y: 10, width: 20, height: 20))), style: Style(color: .black))
        return AnnotationDocument(pixelSize: CGSize(width: base.width, height: base.height), scale: 1, items: [mark])
    }

    @Test func failedAutomaticBackdropKeepsTheRedactionAndItsDocument() async throws {
        let marks = marked
        let shown = try #require(await CaptureRendition.render(marks: marks, adding: oversized, to: base))
        #expect(Pixels(base)[20, 20] == (255, 255, 255, 255))
        #expect(Pixels(shown.image)[20, 20] == (0, 0, 0, 255))
        #expect(try JSONDecoder().decode(AnnotationDocument.self, from: shown.document) == marks)
    }

    @Test func renderableAutomaticBackdropKeepsBothTheBackdropAndRedaction() async throws {
        var document = marked
        let backdrop = Backdrop(fill: .clear, padding: 0, cornerRadius: 0, shadow: 0, ratio: .init(2, 1))
        let shown = try #require(await CaptureRendition.render(marks: document, adding: backdrop, to: base))
        document.backdrop = backdrop
        #expect(try JSONDecoder().decode(AnnotationDocument.self, from: shown.document) == document)
        #expect(shown.image.width == 80 && shown.image.height == 40)
        #expect(Pixels(shown.image)[28, 20] == (0, 0, 0, 255))
    }

    @Test func unrenderableMarkupDoesNotProduceAnyRendition() async {
        var marks = marked
        marks.backdrop = oversized
        await #expect(throws: ImageExporter.ExportError.cannotEncode) {
            try await CaptureRendition.render(marks: marks, adding: nil, to: base)
        }
    }

    @Test func unencodableMarkupDoesNotOfferTheOriginal() async {
        var marks = marked
        marks.canvasBeforeGrowing = CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)
        await #expect(throws: EncodingError.self) {
            try await CaptureRendition.render(marks: marks, adding: nil, to: base)
        }
    }

    @Test func failedAutomaticBackdropWithoutMarkupCanUseTheOriginal() async throws {
        let empty = AnnotationDocument(pixelSize: CGSize(width: base.width, height: base.height), scale: 1)
        #expect(try await CaptureRendition.render(marks: empty, adding: oversized, to: base) == nil)
    }
}
