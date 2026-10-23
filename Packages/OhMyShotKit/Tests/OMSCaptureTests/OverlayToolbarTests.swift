import AppKit
import OMSCore
import Testing
@testable import OMSCapture

/// The pointer over the overlay's bar: the system's arrow there, the drawn crosshair everywhere else.
@MainActor
struct OverlayToolbarTests {
    private static let display = DisplayInfo(
        id: 1, name: "Test", frame: CGRect(x: 1200, y: -200, width: 1440, height: 900),
        pixelSize: CGSize(width: 2880, height: 1800), backingScale: 2, maximumPotentialEDR: 1
    )

    private func makeView(showsToolbar: Bool = true) -> OverlayView {
        let view = OverlayView(display: Self.display)
        view.reset(pointer: CGPoint(x: 1800, y: 400), mode: .area, windows: [], showsToolbar: showsToolbar)
        return view
    }

    private func global(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + Self.display.frame.minX, y: point.y + Self.display.frame.minY)
    }

    @Test func overTheBarTheArrowShowsInPlaceOfTheCrosshair() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        let bar = view.debugToolbarFrame
        let onBar = global(CGPoint(x: bar.midX, y: bar.midY))
        view.movePointer(to: onBar)
        #expect(view.wantsSystemCursor(at: onBar))
        #expect(!view.debugPointerLayers.crosshair && view.debugPointerLayers.loupe == nil && view.debugPointerLayers.colorReading == nil)

        let offBar = global(CGPoint(x: bar.midX, y: bar.maxY + 200))
        view.movePointer(to: offBar)
        #expect(!view.wantsSystemCursor(at: offBar))
        #expect(view.debugPointerLayers.crosshair)
    }

    @Test func aDragOverTheFadedBarKeepsTheCrosshair() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        let bar = view.debugToolbarFrame
        let onBar = global(CGPoint(x: bar.midX, y: bar.midY))
        var selection = SelectionModel(bounds: Self.display.frame, pixelsPerPoint: Self.display.pixelsPerPoint)
        selection.begin(at: global(CGPoint(x: bar.midX - 300, y: bar.maxY + 300)))
        selection.drag(to: onBar, modifiers: [], snapping: nil)
        view.show(selection: selection, showsReading: true, isDragging: true)
        view.movePointer(to: onBar)
        #expect(!view.wantsSystemCursor(at: onBar))
        #expect(view.debugPointerLayers.crosshair)
    }

    /// Until the app is active the system's pointer shows, and the overlay draws none beside it; once hidden, the drawn
    /// one appears where the pointer is. A scripted render draws its own regardless.
    @Test func noPointerIsDrawnWhileTheSystemsShows() {
        let view = makeView(showsToolbar: false)
        view.systemPointerShows = true
        view.layoutSubtreeIfNeeded()
        let point = global(CGPoint(x: 720, y: 450))
        view.movePointer(to: point)
        #expect(!view.debugPointerLayers.crosshair && view.debugPointerLayers.loupe == nil && view.debugPointerLayers.colorReading == nil)

        view.systemPointerShows = false
        #expect(view.debugPointerLayers.crosshair && view.debugPointerLayers.colorReading != nil)
        view.systemPointerShows = true
        #expect(!view.debugPointerLayers.crosshair && view.debugPointerLayers.colorReading == nil)

        view.simulate(pointer: point)
        #expect(view.debugPointerLayers.crosshair)
    }

    @Test func withoutABarThePointerIsAlwaysDrawn() {
        let view = makeView(showsToolbar: false)
        view.layoutSubtreeIfNeeded()
        let point = global(CGPoint(x: 720, y: 60))
        view.movePointer(to: point)
        #expect(!view.wantsSystemCursor(at: point))
        #expect(view.debugPointerLayers.crosshair)
    }
}
