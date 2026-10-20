import AppKit
import Testing
@testable import OMSCapture
import OMSCore

@MainActor
struct MeasureCaptureTests {
    private func largeFixture() async throws -> MeasureOverlay {
        let area = CGRect(x: 0, y: 0, width: 800, height: 600)
        let context = try #require(CGContext(
            data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(area)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 200, y: 200, width: 400, height: 200))
        let image = try #require(context.makeImage())
        let display = DisplayInfo(
            id: 8, name: "Large drawn screen", frame: area, pixelSize: area.size,
            backingScale: 1, maximumPotentialEDR: 1
        )
        let overlay = MeasureOverlay(display: display)
        overlay.show(CapturedFrame(image: image, hdrImage: nil, displayID: display.id, frame: area))
        overlay.movePointer(to: CGPoint(x: 400, y: 300))
        for _ in 0..<400 {
            if overlay.showsLines { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(overlay.showsLines)
        return overlay
    }

    private func selectLargeArea(_ overlay: MeasureOverlay) throws {
        overlay.beginBox(at: CGPoint(x: 20, y: 20))
        overlay.dragBox(to: CGPoint(x: 780, y: 580))
        overlay.endBox()
        try #require(overlay.isFindingEdges, "Large selections must return before scanning finishes")
    }

    private func waitForSnap(_ overlay: MeasureOverlay) async throws {
        for _ in 0..<1_000 {
            if !overlay.isFindingEdges { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!overlay.isFindingEdges, "The synthetic area scan did not finish")
    }

    private func fixture(scale: Int = 2, origin: CGPoint = .zero) async throws -> (MeasureOverlay, CapturedFrame) {
        let area = CGRect(origin: origin, size: CGSize(width: 100, height: 60))
        let context = try #require(CGContext(
            data: nil, width: 100 * scale, height: 60 * scale, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100 * scale, height: 60 * scale))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 30 * scale, y: 30 * scale, width: 40 * scale, height: 20 * scale))
        let image = try #require(context.makeImage())
        let frame = CapturedFrame(image: image, hdrImage: nil, displayID: 7, frame: area)
        let display = DisplayInfo(
            id: 7, name: "Drawn screen", frame: area, pixelSize: CGSize(width: image.width, height: image.height),
            backingScale: CGFloat(scale), maximumPotentialEDR: 1
        )
        let overlay = MeasureOverlay(display: display)
        overlay.show(frame)
        overlay.movePointer(to: CGPoint(x: 45, y: 40))
        for _ in 0..<200 {
            if overlay.showsLines { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(overlay.showsLines)
        overlay.beginBox(at: CGPoint(x: 20, y: 20))
        overlay.dragBox(to: CGPoint(x: 80, y: 58))
        #expect(overlay.endBox() == nil, "Drawing selects; it does not capture")
        return (overlay, frame)
    }

    @Test func clickingInsideKeepsTheSelectionUntilReleaseAndAllowsSmallPointerJitter() async throws {
        let (overlay, _) = try await fixture()
        defer { overlay.clear() }
        overlay.beginBox(at: CGPoint(x: 45, y: 40))
        #expect(overlay.measurement == "40 × 20 pt")
        overlay.dragBox(to: CGPoint(x: 46, y: 40.5))
        #expect(overlay.measurement == "40 × 20 pt")
        #expect(overlay.endBox(at: CGPoint(x: 46, y: 40.5)) == CGRect(x: 30, y: 30, width: 40, height: 20))
    }

    @Test func draggingFromInsideStartsANewSelection() async throws {
        let (overlay, _) = try await fixture()
        defer { overlay.clear() }
        overlay.beginBox(at: CGPoint(x: 45, y: 40))
        overlay.dragBox(to: CGPoint(x: 90, y: 58))
        #expect(overlay.endBox(at: CGPoint(x: 90, y: 58), snapping: false) == nil)
        #expect(overlay.measurement == "45 × 18 pt")
        overlay.beginBox(at: CGPoint(x: 60, y: 50))
        #expect(overlay.endBox(at: CGPoint(x: 60, y: 50)) == CGRect(x: 45, y: 40, width: 45, height: 18))
    }

    @Test func clickingOutsideClearsAndReleasingOutsideCannotCapture() async throws {
        let (overlay, _) = try await fixture()
        defer { overlay.clear() }
        overlay.beginBox(at: CGPoint(x: 69, y: 40))
        #expect(overlay.endBox(at: CGPoint(x: 71, y: 40)) == nil)
        #expect(overlay.measurement == "40 × 20 pt")
        overlay.beginBox(at: CGPoint(x: 10, y: 10))
        #expect(overlay.endBox(at: CGPoint(x: 10, y: 10)) == nil)
        overlay.beginBox(at: CGPoint(x: 45, y: 40))
        #expect(overlay.endBox(at: CGPoint(x: 45, y: 40)) == nil, "The old box was cleared by the outside click")
    }

    @Test func modifierReleaseAndCancelledSessionsCannotCapture() async throws {
        let (overlay, _) = try await fixture()
        defer { overlay.clear() }
        overlay.beginBox(at: CGPoint(x: 45, y: 40))
        #expect(overlay.endBox(at: CGPoint(x: 45, y: 40), allowsCapture: false) == nil)
        #expect(overlay.measurement == "40 × 20 pt")
        overlay.beginBox(at: CGPoint(x: 45, y: 40))
        overlay.clear()
        #expect(overlay.endBox(at: CGPoint(x: 45, y: 40)) == nil)
    }

    @Test func selectedScreenshotUsesOnlyFrozenPixelsAtDisplayScaleAndNegativeOrigins() async throws {
        for scale in [1, 2] {
            let (overlay, frozen) = try await fixture(scale: scale, origin: CGPoint(x: -400, y: 100))
            defer { overlay.clear() }
            overlay.beginBox(at: CGPoint(x: 45, y: 40))
            let local = try #require(overlay.endBox(at: CGPoint(x: 45, y: 40)))
            let global = local.offsetBy(dx: frozen.frame.minX, dy: frozen.frame.minY)
            let screenshot = try #require(frozen.cropped(to: global))
            #expect(screenshot.frame == CGRect(x: -370, y: 130, width: 40, height: 20))
            #expect(screenshot.image.width == 40 * scale && screenshot.image.height == 20 * scale)
            #expect(screenshot.pixelsPerPoint == CGFloat(scale) && screenshot.displayID == 7)
            // The drawn selection's outline and readings live in layers, so they cannot reach this crop.
            #expect(screenshot.color(atPixel: 0, 0)?.hex == "#000000")
            #expect(screenshot.color(atPixel: screenshot.image.width - 1, screenshot.image.height - 1)?.hex == "#000000")
        }
    }

    @Test func aClickWhileFindingEdgesCapturesTheFinalBoxEvenAfterThePointerLeaves() async throws {
        let overlay = try await largeFixture()
        defer { overlay.clear() }
        var captures: [CGRect] = []
        overlay.onCapture = { captures.append($0) }
        try selectLargeArea(overlay)
        overlay.beginBox(at: CGPoint(x: 400, y: 300))
        #expect(overlay.endBox(at: CGPoint(x: 400, y: 300)) == nil)
        #expect(captures.isEmpty)
        overlay.movePointer(to: nil)
        try await waitForSnap(overlay)
        #expect(captures == [CGRect(x: 200, y: 200, width: 400, height: 200)])
        #expect(overlay.measurement == "400 × 200 pt")
    }

    @Test func queuedClickOutsideTheFinalContentDoesNotCaptureTheOriginalDrag() async throws {
        let overlay = try await largeFixture()
        defer { overlay.clear() }
        var captures: [CGRect] = []
        overlay.onCapture = { captures.append($0) }
        try selectLargeArea(overlay)
        overlay.beginBox(at: CGPoint(x: 50, y: 50))
        #expect(overlay.endBox(at: CGPoint(x: 50, y: 50)) == nil)
        try await waitForSnap(overlay)
        #expect(captures.isEmpty)
        #expect(overlay.measurement == "400 × 200 pt")
    }

    @Test func changingToleranceCancelsAQueuedCaptureAndReplacesThePendingScan() async throws {
        let overlay = try await largeFixture()
        defer { overlay.clear() }
        var captures: [CGRect] = []
        overlay.onCapture = { captures.append($0) }
        try selectLargeArea(overlay)
        overlay.beginBox(at: CGPoint(x: 400, y: 300))
        overlay.endBox(at: CGPoint(x: 400, y: 300))
        overlay.tolerance = .high
        try await waitForSnap(overlay)
        #expect(captures.isEmpty)
        #expect(overlay.measurement == "400 × 200 pt")
    }

    @Test func aNewDragAndClearInvalidateLargeSelectionWork() async throws {
        let overlay = try await largeFixture()
        defer { overlay.clear() }
        var captures: [CGRect] = []
        overlay.onCapture = { captures.append($0) }
        try selectLargeArea(overlay)
        overlay.beginBox(at: CGPoint(x: 400, y: 300))
        overlay.endBox(at: CGPoint(x: 400, y: 300))
        overlay.beginBox(at: CGPoint(x: 10, y: 10))
        overlay.dragBox(to: CGPoint(x: 100, y: 100))
        overlay.endBox(snapping: false)
        #expect(!overlay.isFindingEdges)
        #expect(overlay.measurement == "90 × 90 pt")
        overlay.clear()
        try await Task.sleep(for: .milliseconds(100))
        #expect(captures.isEmpty)
        #expect(overlay.measurement == nil && !overlay.isFindingEdges)
    }

    @Test func replacingTheFrozenFrameRejectsOldBoundsAndQueuedCapture() async throws {
        let overlay = try await largeFixture()
        defer { overlay.clear() }
        var captures: [CGRect] = []
        overlay.onCapture = { captures.append($0) }
        try selectLargeArea(overlay)
        overlay.beginBox(at: CGPoint(x: 400, y: 300))
        overlay.endBox(at: CGPoint(x: 400, y: 300))
        let context = try #require(CGContext(
            data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        overlay.show(CapturedFrame(
            image: try #require(context.makeImage()), hdrImage: nil, displayID: 8,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        ))
        try await waitForSnap(overlay)
        #expect(captures.isEmpty)
        #expect(overlay.measurement == "760 × 560 pt", "The old frame's 400 × 200 bounds must not overwrite the replacement")
    }

    @Test func aQueuedClickFinishesAfterLeavingWhileInitialPixelsAreStillLoading() async throws {
        let area = CGRect(x: 0, y: 0, width: 800, height: 600)
        let context = try #require(CGContext(
            data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(area)
        let display = DisplayInfo(id: 9, name: "Loading screen", frame: area, pixelSize: area.size, backingScale: 1, maximumPotentialEDR: 1)
        let overlay = MeasureOverlay(display: display)
        defer { overlay.clear() }
        var captures: [CGRect] = []
        overlay.onCapture = { captures.append($0) }
        overlay.show(CapturedFrame(image: try #require(context.makeImage()), hdrImage: nil, displayID: display.id, frame: area))
        overlay.movePointer(to: CGPoint(x: 400, y: 300))
        // No actor suspension yet: the initial pixel-copy task has not started.
        try selectLargeArea(overlay)
        overlay.beginBox(at: CGPoint(x: 400, y: 300))
        #expect(overlay.endBox(at: CGPoint(x: 400, y: 300)) == nil && captures.isEmpty)
        overlay.movePointer(to: nil)
        try await waitForSnap(overlay)
        #expect(captures == [CGRect(x: 20, y: 20, width: 760, height: 560)])
    }
}
