import CoreGraphics
import Foundation
import OMSCore
import Testing
@testable import OMSAnnotate

/// A picture's own watermark: drawn over its marks, kept in its project, and set and taken back as one step.
@MainActor
struct WatermarkDocumentTests {
    private let scratch = ScratchDefaults()

    private func white(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func aWatermarkIsDrawnKeptAndTakenBackAsOneStep() throws {
        let base = try white(400, 300)
        let session = AnnotationSession(image: base, scale: 1, defaults: scratch.make())
        session.undoManager.groupsByEvent = false
        #expect(session.document.isEmpty)
        session.undoManager.beginUndoGrouping()
        session.changeWatermark("Watermark") { $0 = Watermark(text: "Draft", opacity: 0.4) }
        session.undoManager.endUndoGrouping()
        #expect(!session.document.isEmpty && session.document.watermark?.text == "Draft")
        // The next picture starts from it.
        #expect(session.lastWatermark.text == "Draft")

        // Drawn into the finished picture.
        let rendered = try #require(AnnotationRenderer.flatten(session.document, base: base))
        let context = try #require(CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 1600,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: 400, height: 300))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        #expect((0..<(400 * 300)).filter { data[$0 * 4] < 250 }.count > 500)

        // Kept in the project, which needs format 3, and in the history's JSON.
        let project = try AnnotationProject.read(AnnotationProject(capture: base, document: session.document).data())
        #expect(project.document.watermark == session.document.watermark)
        #expect(AnnotationProject.version(for: session.document) == 3)

        session.undo()
        #expect(session.document.watermark == nil && session.document.isEmpty)
    }
}
