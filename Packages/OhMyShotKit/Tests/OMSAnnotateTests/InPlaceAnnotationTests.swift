import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

@MainActor
struct InPlaceAnnotationTests {
    /// A display's frozen frame: 400 × 300 points at 2×, white with a black block at (100, 50) pt.
    private func frame() -> CGImage {
        let context = CGContext(
            data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        // y up: 50 pt from the top of 300 pt is 250 pt from the bottom; the block is 20 pt square.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 200, y: 600 - 100 - 40, width: 40, height: 40))
        return context.makeImage()!
    }

    private func view(selection: CGRect = CGRect(x: 80, y: 40, width: 100, height: 60)) -> InPlaceAnnotationView {
        InPlaceAnnotationView(
            frame: frame(), scale: 2, size: CGSize(width: 400, height: 300), selection: selection,
            actions: .init(copy: { _ in }, save: { _ in }, openInEditor: { _ in }, cancel: {})
        )
    }

    @Test func theSelectionIsTheCanvasInWholePixels() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(InPlaceAnnotationView.pixels(CGRect(x: 10.25, y: 5, width: 50.5, height: 20), scale: 2, within: bounds) == CGRect(x: 21, y: 10, width: 101, height: 40))
        // Kept on the display.
        #expect(InPlaceAnnotationView.pixels(CGRect(x: 380, y: 280, width: 50, height: 50), scale: 2, within: bounds) == CGRect(x: 760, y: 560, width: 40, height: 40))
        let annotator = view()
        #expect(annotator.session.document.canvas == CGRect(x: 160, y: 80, width: 200, height: 120))
        #expect(annotator.selectionRect == CGRect(x: 80, y: 40, width: 100, height: 60))
    }

    @Test func theCanvasLiesOnTheScreenAtItsOwnSize() {
        let annotator = view()
        annotator.layoutSubtreeIfNeeded()
        #expect(annotator.canvas.frame == annotator.selectionRect)
        #expect(annotator.canvas.zoom == 0.5)
        #expect(annotator.canvas.pictureFrame == annotator.canvas.bounds)
    }

    @Test func theResultIsTheSelectionWithItsMarksMovedIntoIt() throws {
        let annotator = view()
        var document = annotator.session.document
        document.items = [Annotation(shape: .rectangle(Box(rect: CGRect(x: 170, y: 90, width: 20, height: 20))), style: Style())]
        annotator.session.commit(document, actionName: "Add")
        let result = try #require(annotator.result())
        #expect(result.capture.width == 200 && result.capture.height == 120)
        #expect(result.document.pixelSize == CGSize(width: 200, height: 120))
        #expect(result.document.canvas == CGRect(x: 0, y: 0, width: 200, height: 120))
        guard case .rectangle(let box) = result.document.items.first?.shape else { Issue.record("no rectangle"); return }
        #expect(box.rect == CGRect(x: 10, y: 10, width: 20, height: 20))
        // The black block at (100, 50) pt is (40, 20) px into the selection.
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(result.capture, in: CGRect(x: -45, y: -(120 - 1 - 25), width: 200, height: 120))
        #expect(pixel[0] < 10 && pixel[3] == 255)
    }

    @Test func theResultIsWhereTheSelectionEndedUp() throws {
        let annotator = view()
        #expect(try #require(annotator.result()).area == CGRect(x: 80, y: 40, width: 100, height: 60))
        // Moved and resized, as dragging its frame does.
        var document = annotator.session.document
        document.canvas = CGRect(x: 100, y: 60, width: 300, height: 200)
        annotator.session.commit(document, actionName: "Resize Selection")
        let result = try #require(annotator.result())
        #expect(result.area == CGRect(x: 50, y: 30, width: 150, height: 100))
        #expect(result.capture.width == 300 && result.capture.height == 200)
    }

    @Test func picturesModesAreNotOfferedInPlace() throws {
        let annotator = view()
        #expect(!AnnotationCanvasView.inPlaceTools.contains(.crop) && !AnnotationCanvasView.inPlaceTools.contains(.background))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
        ))
        annotator.canvas.keyDown(with: event)
        #expect(annotator.session.tool == .select)
        let arrow = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ))
        annotator.canvas.keyDown(with: arrow)
        #expect(annotator.session.tool == .arrow)
    }

    @Test func inPlaceLeavesTheEditorsToolAlone() {
        let key = "annotation.tool"
        let before = UserDefaults.standard.string(forKey: key)
        let annotator = view()
        annotator.session.tool = .counter
        #expect(UserDefaults.standard.string(forKey: key) == before)
    }
}
