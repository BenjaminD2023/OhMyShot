import AppKit
import OMSCore
import Testing
@testable import OMSCapture

/// All-In-One's Measure: the overlay turns into Measure where it stands, on the frame it holds, without its bar.
@MainActor
struct AllInOneMeasureTests {
    /// A 2× display 800 × 600 points with its bottom-left corner at the origin, so its points are global ones.
    private static let display = DisplayInfo(
        id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 1600, height: 1200),
        backingScale: 2, maximumPotentialEDR: 1
    )

    private static func whiteFrame() throws -> CapturedFrame {
        let context = try #require(CGContext(
            data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        return CapturedFrame(image: try #require(context.makeImage()), hdrImage: nil, displayID: display.id, frame: display.frame)
    }

    /// The frame All-In-One holds stays and holds still, on a live screen too; the bar goes, the help is Measure's, and
    /// the ruler measures in the unit given.
    @Test func theOverlayMeasuresOnTheFrameItHolds() throws {
        let frame = try Self.whiteFrame()
        for frozen in [true, false] {
            let view = OverlayView(display: Self.display)
            defer { view.clear() }
            view.reset(pointer: CGPoint(x: 400, y: 300), mode: .area, windows: [], showsToolbar: true, purpose: .screenshot, allInOne: true)
            view.show(frame, frozen: frozen)
            view.layoutSubtreeIfNeeded()
            let bar = view.debugToolbarFrame
            let onBar = CGPoint(x: bar.midX, y: bar.midY)
            #expect(view.wantsSystemCursor(at: onBar) && view.isFrozen == frozen)

            view.turnToMeasure(pointer: CGPoint(x: 400, y: 300), colorFormat: .hex, unit: .pixels, tolerance: .medium, snapsToContent: false)
            #expect(view.frame()?.image === frame.image, "frozen \(frozen)")
            #expect(view.isFrozen && !view.isAllInOne, "frozen \(frozen)")
            #expect(!view.wantsSystemCursor(at: onBar), "frozen \(frozen)")
            #expect(view.accessibilityHelp()?.hasPrefix("Point at something to measure it") == true)
            view.debugMeasureBox(CGRect(x: 100, y: 100, width: 100, height: 50))
            #expect(view.debugMeasurement == MeasureUnit.pixels.reading(width: 200, height: 100, pixelsPerPoint: 2), "frozen \(frozen)")
        }
    }

    /// Turned to before the display's frame has arrived, the ruler takes the frame when it does, held still.
    @Test func aFrameArrivingLaterIsMeasuredHeldStill() throws {
        let view = OverlayView(display: Self.display)
        defer { view.clear() }
        view.reset(pointer: CGPoint(x: 400, y: 300), mode: .area, windows: [], showsToolbar: true, purpose: .screenshot, allInOne: true)
        view.turnToMeasure(pointer: CGPoint(x: 400, y: 300), colorFormat: .hex, unit: .points, tolerance: .medium, snapsToContent: false)
        #expect(view.frame() == nil && !view.isFrozen)
        let frame = try Self.whiteFrame()
        view.show(frame, frozen: OverlayController.Purpose.measure.holdsStill(freezesScreen: false))
        #expect(view.frame()?.image === frame.image && view.isFrozen)
    }
}
