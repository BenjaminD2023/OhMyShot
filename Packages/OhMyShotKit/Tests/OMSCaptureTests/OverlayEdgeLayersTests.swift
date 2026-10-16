import AppKit
import OMSCore
import Testing
@testable import OMSCapture

/// The overlay's panels and views are reused between sessions, so what one session hides a new one must bring back.
@MainActor
struct OverlayEdgeLayersTests {
    private static let display = DisplayInfo(
        id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 1600, height: 1200),
        backingScale: 2, maximumPotentialEDR: 1
    )

    private func reset(_ view: OverlayView) {
        view.reset(pointer: CGPoint(x: 400, y: 300), mode: .area, windows: [], showsToolbar: false, snapsToText: true)
    }

    @Test func aNewSessionShowsTheSelectionsEdgesInPlaceAnnotationHid() {
        let view = OverlayView(display: Self.display)
        reset(view)
        #expect(view.debugEdgeLayersShow.border && view.debugEdgeLayersShow.snapped)
        view.enterAnnotation()
        #expect(!view.debugEdgeLayersShow.border && !view.debugEdgeLayersShow.snapped)
        view.clear()
        reset(view)
        #expect(view.debugEdgeLayersShow.border && view.debugEdgeLayersShow.snapped)
    }
}
