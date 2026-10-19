import AppKit
import OMSCore
import Testing
@testable import OMSCapture

@MainActor
struct MeasureOverlayTests {
    private func fixture(scale: Int, faint: Bool = false, size: CGSize = CGSize(width: 100, height: 60)) throws -> (DisplayInfo, CapturedFrame) {
        let frame = CGRect(origin: .zero, size: size)
        let width = Int(size.width) * scale, height = Int(size.height) * scale
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let level = faint ? 245.0 / 255 : 0
        context.setFillColor(CGColor(srgbRed: level, green: level, blue: level, alpha: 1))
        context.fill(CGRect(x: 30 * scale, y: 30 * scale, width: 40 * scale, height: 20 * scale))
        let image = try #require(context.makeImage())
        let display = DisplayInfo(
            id: 1, name: "Fixture", frame: frame, pixelSize: CGSize(width: image.width, height: image.height),
            backingScale: CGFloat(scale), maximumPotentialEDR: 1
        )
        return (display, CapturedFrame(image: image, hdrImage: nil, displayID: 1, frame: frame))
    }

    private func overlay(scale: Int, faint: Bool = false, size: CGSize = CGSize(width: 100, height: 60)) throws -> MeasureOverlay {
        let (display, frame) = try fixture(scale: scale, faint: faint, size: size)
        let overlay = MeasureOverlay(display: display)
        overlay.show(frame)
        overlay.movePointer(to: CGPoint(x: 45.25, y: 40.25))
        return overlay
    }

    private func waitForPixels(_ overlay: MeasureOverlay) async throws {
        for _ in 0..<200 {
            if overlay.showsLines { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(overlay.showsLines, "Synthetic measurement pixels did not load")
    }

    private func drag(_ overlay: MeasureOverlay, snapping: Bool = true) {
        overlay.beginBox(at: CGPoint(x: 20, y: 20))
        overlay.dragBox(to: CGPoint(x: 80, y: 58))
        overlay.endBox(snapping: snapping)
    }

    private func dragLargeArea(_ overlay: MeasureOverlay) throws {
        overlay.beginBox(at: CGPoint(x: 20, y: 20))
        overlay.dragBox(to: CGPoint(x: 780, y: 580))
        overlay.endBox()
        try #require(overlay.isFindingEdges, "Large selections return before edge detection finishes")
    }

    private func waitForSnap(_ overlay: MeasureOverlay) async throws {
        for _ in 0..<1_000 {
            if !overlay.isFindingEdges { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!overlay.isFindingEdges, "Synthetic selection edge detection did not finish")
    }

    @Test func largeSelectionsFinishInTheBackgroundAndApplyTheirBounds() async throws {
        let overlay = try overlay(scale: 1, size: CGSize(width: 800, height: 600))
        defer { overlay.clear() }
        try await waitForPixels(overlay)
        try dragLargeArea(overlay)
        #expect(overlay.measurement == "760 × 560 pt")
        #expect(overlay.accessibilityValue?.contains("Finding edges") == true)
        try await waitForSnap(overlay)
        #expect(overlay.measurement == "40 × 20 pt")
    }

    @Test func aNewManualSelectionAndClearRejectPendingAreaResults() async throws {
        let overlay = try overlay(scale: 1, size: CGSize(width: 800, height: 600))
        defer { overlay.clear() }
        try await waitForPixels(overlay)
        try dragLargeArea(overlay)
        overlay.beginBox(at: CGPoint(x: 100, y: 100))
        overlay.dragBox(to: CGPoint(x: 300, y: 250))
        overlay.endBox(snapping: false)
        #expect(!overlay.isFindingEdges && overlay.measurement == "200 × 150 pt")
        try await Task.sleep(for: .milliseconds(100))
        #expect(overlay.measurement == "200 × 150 pt")
        overlay.clear()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!overlay.isFindingEdges && overlay.measurement == nil)
    }

    @Test func aToleranceChangeReplacesThePendingSelectionResult() async throws {
        let overlay = try overlay(scale: 1, faint: true, size: CGSize(width: 800, height: 600))
        defer { overlay.clear() }
        try await waitForPixels(overlay)
        try dragLargeArea(overlay)
        overlay.tolerance = .high
        try await waitForSnap(overlay)
        #expect(overlay.measurement == "760 × 560 pt", "Old Medium bounds must not replace the newer High result")
    }

    @Test func aReplacementFrameRejectsTheOldFramesPendingBounds() async throws {
        let overlay = try overlay(scale: 1, size: CGSize(width: 800, height: 600))
        defer { overlay.clear() }
        try await waitForPixels(overlay)
        try dragLargeArea(overlay)
        let context = try #require(CGContext(
            data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        overlay.show(CapturedFrame(
            image: try #require(context.makeImage()), hdrImage: nil, displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        ))
        try await waitForSnap(overlay)
        #expect(overlay.measurement == "760 × 560 pt", "The new blank frame has no content to trim")
    }

    @Test func disabledSnappingKeepsLargeDrawnBoxesWithoutStartingAreaWork() async throws {
        let overlay = try overlay(scale: 2, size: CGSize(width: 800, height: 600))
        defer { overlay.clear() }
        overlay.snapsToContent = false
        try await waitForPixels(overlay)
        #expect(overlay.measurement == "40 × 20 pt", "Pointer measurements remain available")

        overlay.beginBox(at: CGPoint(x: 20, y: 20))
        overlay.dragBox(to: CGPoint(x: 780, y: 580))
        overlay.endBox()
        #expect(!overlay.isFindingEdges, "Disabled snapping must not start a large area scan")
        #expect(overlay.measurement == "760 × 560 pt")
        overlay.tolerance = .high
        #expect(!overlay.isFindingEdges && overlay.measurement == "760 × 560 pt")
    }

    @Test func disablingSnappingRestoresTheDrawnBoxAndLeavesItManual() async throws {
        let overlay = try overlay(scale: 2)
        defer { overlay.clear() }
        try await waitForPixels(overlay)
        drag(overlay)
        #expect(overlay.measurement == "40 × 20 pt")
        overlay.snapsToContent = false
        #expect(overlay.measurement == "60 × 38 pt")
        overlay.snapsToContent = true
        overlay.tolerance = .low
        #expect(overlay.measurement == "60 × 38 pt", "A box placed freely stays manual")
        drag(overlay)
        #expect(overlay.measurement == "40 × 20 pt")
    }

    #if DEBUG
    @Test func reusedViewsApplyTheSnappingChoiceForEachSession() async throws {
        let (display, frame) = try fixture(scale: 2)
        let view = OverlayView(display: display)
        defer { view.clear() }
        for enabled in [false, true, false] {
            view.reset(
                pointer: CGPoint(x: 45, y: 40), mode: .area, windows: [], showsToolbar: false,
                purpose: .measure, measureSnapsToContent: enabled
            )
            view.show(frame, frozen: true)
            for _ in 0..<200 {
                if view.debugMeasurement != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(view.debugMeasurement != nil)
            view.debugMeasureBox(CGRect(x: 20, y: 20, width: 60, height: 38))
            #expect(view.debugMeasurement == (enabled ? "40 × 20 pt" : "60 × 38 pt"))
        }
    }
    #endif

    @Test func measurementsUsePhysicalPixelsAndConvertBackToPoints() async throws {
        for scale in [1, 2] {
            let overlay = try overlay(scale: scale)
            defer { overlay.clear() }
            try await waitForPixels(overlay)
            #expect(overlay.measurement == "40 × 20 pt")
            overlay.unit = .pixels
            #expect(overlay.measurement == "\(40 * scale) × \(20 * scale) px")
            drag(overlay)
            #expect(overlay.measurement == "\(40 * scale) × \(20 * scale) px")
            overlay.unit = .points
            #expect(overlay.measurement == "40 × 20 pt")
        }
    }

    @Test func toleranceRecomputesOriginalSelectionAndManualBoxesStayManual() async throws {
        let overlay = try overlay(scale: 2, faint: true)
        defer { overlay.clear() }
        try await waitForPixels(overlay)
        drag(overlay)
        #expect(overlay.measurement == "40 × 20 pt")
        overlay.tolerance = .low
        #expect(overlay.measurement == "40 × 20 pt")
        overlay.tolerance = .high
        #expect(overlay.measurement == "60 × 38 pt")
        overlay.tolerance = .zero
        #expect(overlay.measurement == "40 × 20 pt")
        drag(overlay, snapping: false)
        #expect(overlay.measurement == "60 × 38 pt")
        overlay.tolerance = .low
        #expect(overlay.measurement == "60 × 38 pt")
    }

    @Test func clearingCancelsDelayedPixelsAndHidesEveryReading() async throws {
        let overlay = try overlay(scale: 2)
        overlay.clear()
        try await Task.sleep(for: .milliseconds(30))
        #expect(overlay.measurement == nil)
        #expect(overlay.layer.sublayers?.allSatisfy(\.isHidden) == true)
    }
}
