import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// Return in the annotation editor copies and closes, unless it has something of its own to finish. Nothing is shown.
@MainActor
struct EditorReturnTests {
    private func makeCanvas(tool: AnnotationTool) throws -> (AnnotationCanvasView, AnnotationSession, NSWindow) {
        let context = try #require(CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let session = AnnotationSession(image: try #require(context.makeImage()), scale: 1, tool: tool)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvasView(session: session)
        canvas.contentInsets = NSEdgeInsetsZero
        canvas.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(canvas)
        canvas.layoutSubtreeIfNeeded()
        return (canvas, session, window)
    }

    private func returnKey(code: UInt16 = 36) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code
        ))
    }

    @Test func returnCopiesAndClosesWithNothingToFinish() throws {
        let (canvas, _, window) = try makeCanvas(tool: .arrow)
        defer { window.close() }
        var returned = 0
        canvas.onReturn = { returned += 1 }
        canvas.keyDown(with: try returnKey())
        canvas.keyDown(with: try returnKey(code: 76))
        #expect(returned == 2)
    }

    /// Crop's Return applies the frame, as it always has: the window stays.
    @Test func cropKeepsItsReturn() throws {
        let (canvas, _, window) = try makeCanvas(tool: .crop)
        defer { window.close() }
        var returned = 0
        canvas.onReturn = { returned += 1 }
        canvas.keyDown(with: try returnKey())
        #expect(returned == 0)
    }
}
