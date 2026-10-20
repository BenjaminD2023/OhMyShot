import AppKit
import OMSCore
import Testing
@testable import OMSCapture

@MainActor
struct OverlayCanvasCursorTests {
    private static let display = DisplayInfo(
        id: 1, name: "Cursor fixture", frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        pixelSize: CGSize(width: 1600, height: 1200), backingScale: 2, maximumPotentialEDR: 1
    )
    private let canvas = CGPoint(x: 400, y: 400)

    private func makeView(purpose: OverlayController.Purpose = .screenshot, showsToolbar: Bool = true) -> OverlayView {
        let view = OverlayView(display: Self.display)
        view.reset(pointer: canvas, mode: .area, windows: [], showsToolbar: showsToolbar, purpose: purpose)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func cursorEvent(at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(
            with: .cursorUpdate, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
    }

    @Test func theStationaryCanvasCursorStartsWithInputAndHasTransparentPixels() throws {
        let original = NSCursor.current
        defer { original.set() }
        for purpose in [OverlayController.Purpose.screenshot, .annotate] {
            let view = makeView(purpose: purpose)
            NSCursor.arrow.set()
            view.cursorUpdate(with: try cursorEvent(at: canvas))
            #expect(NSCursor.current === NSCursor.arrow)
            view.beginCanvasCursorOwnership(at: canvas)
            #expect(NSCursor.current === OverlayCursorVisibility.canvasCursor)
            view.clear()
            #expect(NSCursor.current === NSCursor.arrow)
        }
        let data = try #require(OverlayCursorVisibility.canvasCursor.image.tiffRepresentation)
        let pixels = try #require(NSBitmapImageRep(data: data))
        #expect(pixels.pixelsWide > 0 && pixels.pixelsHigh > 0)
        for x in 0..<pixels.pixelsWide {
            for y in 0..<pixels.pixelsHigh { #expect(pixels.colorAt(x: x, y: y)?.alphaComponent == 0) }
        }
    }

    @Test func cursorUpdatesHandOffBetweenTheToolbarAndCanvasWithoutSelecting() throws {
        let original = NSCursor.current
        defer { original.set() }
        let view = makeView()
        let bar = view.debugToolbarFrame
        let onBar = CGPoint(x: bar.maxX - 10, y: bar.midY)
        var updates: [CGPoint] = []
        view.onCanvasCursorUpdate = { updates.append($0) }
        view.beginCanvasCursorOwnership(at: canvas)
        view.cursorUpdate(with: try cursorEvent(at: onBar))
        #expect(NSCursor.current === NSCursor.arrow)
        view.cursorUpdate(with: try cursorEvent(at: canvas))
        #expect(NSCursor.current === OverlayCursorVisibility.canvasCursor)
        #expect(updates == [onBar, canvas])
        // A selection fades the toolbar. Its former bounds then belong to the canvas too.
        var selection = SelectionModel(bounds: Self.display.frame, pixelsPerPoint: 2)
        selection.begin(at: canvas)
        selection.drag(to: onBar)
        view.show(selection: selection, showsReading: false, isDragging: true)
        view.cursorUpdate(with: try cursorEvent(at: onBar))
        #expect(NSCursor.current === OverlayCursorVisibility.canvasCursor)
        view.clear()
    }

    @Test func setupResetAndClearReleaseOnlyTheCanvasCursorAndIgnoreLateEvents() throws {
        let original = NSCursor.current
        defer { original.set() }
        let view = makeView()
        view.beginCanvasCursorOwnership(at: canvas)
        view.enterAnnotation()
        #expect(NSCursor.current === NSCursor.arrow)
        NSCursor.iBeam.set()
        view.cursorUpdate(with: try cursorEvent(at: canvas))
        #expect(NSCursor.current === NSCursor.iBeam, "The annotation or setup child keeps its own cursor")
        view.reset(pointer: canvas, mode: .area, windows: [], showsToolbar: false)
        view.beginCanvasCursorOwnership(at: canvas)
        view.reset(pointer: canvas, mode: .area, windows: [], showsToolbar: false, purpose: .text)
        #expect(NSCursor.current === NSCursor.arrow)
        view.cursorUpdate(with: try cursorEvent(at: canvas))
        #expect(NSCursor.current === NSCursor.arrow)
        view.reset(pointer: canvas, mode: .area, windows: [], showsToolbar: false)
        view.beginCanvasCursorOwnership(at: canvas)
        view.clear()
        #expect(NSCursor.current === NSCursor.arrow)
        NSCursor.pointingHand.set()
        view.cursorUpdate(with: try cursorEvent(at: canvas))
        #expect(NSCursor.current === NSCursor.pointingHand)
        view.beginCanvasCursorOwnership(at: canvas)
        NSCursor.openHand.set()
        view.clear()
        #expect(NSCursor.current === NSCursor.openHand, "Clearing does not replace another native cursor")
    }

    @Test func textColorMeasureRecordingAndScrollingKeepTheirNativeCursorPolicy() throws {
        let original = NSCursor.current
        defer { original.set() }
        for purpose in [OverlayController.Purpose.text, .color, .measure, .record, .scroll] {
            let view = makeView(purpose: purpose)
            NSCursor.crosshair.set()
            view.beginCanvasCursorOwnership(at: canvas)
            view.cursorUpdate(with: try cursorEvent(at: canvas))
            #expect(NSCursor.current === NSCursor.crosshair, "\(purpose)")
            view.clear()
            #expect(NSCursor.current === NSCursor.crosshair)
        }
    }

    @Test func acquiringAnotherDisplayDoesNotChangeTheCursorUntilThePointerReachesIt() throws {
        let original = NSCursor.current
        defer { original.set() }
        let left = makeView()
        let rightDisplay = DisplayInfo(
            id: 2, name: "Right display", frame: CGRect(x: 800, y: 0, width: 800, height: 600),
            pixelSize: CGSize(width: 1600, height: 1200), backingScale: 2, maximumPotentialEDR: 1
        )
        let right = OverlayView(display: rightDisplay)
        right.reset(pointer: canvas, mode: .area, windows: [], showsToolbar: false)
        left.beginCanvasCursorOwnership(at: canvas)
        NSCursor.openHand.set()
        right.beginCanvasCursorOwnership(at: canvas)
        #expect(NSCursor.current === NSCursor.openHand)
        right.cursorUpdate(with: try cursorEvent(at: canvas))
        #expect(NSCursor.current === OverlayCursorVisibility.canvasCursor)
        left.clear()
        right.clear()
    }

    @Test func aToolbarGripKeepsItsHandAndHidingTheBarReturnsTheCanvasCursor() throws {
        let original = NSCursor.current
        defer { original.set() }
        let view = makeView()
        let bar = try #require(view.subviews.compactMap { $0 as? AllInOneBar }.first)
        func findGrip(in root: NSView) -> CaptureBarHandle? {
            if let grip = root as? CaptureBarHandle { return grip }
            return root.subviews.lazy.compactMap { findGrip(in: $0) }.first
        }
        let grip = try #require(findGrip(in: bar))
        let handle = bar.dragHandleFrame
        let point = view.convert(CGPoint(x: handle.midX, y: handle.midY), from: bar)
        view.beginCanvasCursorOwnership(at: canvas)
        view.cursorUpdate(with: try cursorEvent(at: point))
        #expect(NSCursor.current === NSCursor.openHand)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        grip.mouseDown(with: try mouse(.leftMouseDown))
        view.cursorUpdate(with: try cursorEvent(at: point))
        #expect(NSCursor.current === NSCursor.closedHand)
        grip.mouseUp(with: try mouse(.leftMouseUp))
        view.cursorUpdate(with: try cursorEvent(at: point))
        #expect(NSCursor.current === NSCursor.openHand)
        view.setToolbarHidden(true)
        view.refreshCanvasCursor(at: point)
        #expect(NSCursor.current === OverlayCursorVisibility.canvasCursor)
        view.setToolbarHidden(false)
        view.refreshCanvasCursor(at: point)
        #expect(NSCursor.current === NSCursor.openHand)
        view.clear()
    }
}
