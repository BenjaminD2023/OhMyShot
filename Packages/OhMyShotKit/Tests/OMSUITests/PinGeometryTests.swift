import CoreGraphics
import Testing
@testable import OMSUI

struct PinGeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func aCaptureIsPinnedWhereItWasAtItsOwnSize() {
        let area = CGRect(x: 120.5, y: 300, width: 400, height: 250)
        let placed = PinGeometry.initialFrame(size: CGSize(width: 400, height: 250), requested: area, visible: screen)
        #expect(placed.frame == area && placed.zoom == 1)
    }

    @Test func aLargerPictureIsCenteredOnItsArea() {
        // A window captured with its shadow is larger than the window.
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let placed = PinGeometry.initialFrame(size: CGSize(width: 480, height: 380), requested: window, visible: screen)
        #expect(placed.frame == CGRect(x: 60, y: 60, width: 480, height: 380) && placed.zoom == 1)
    }

    @Test func aPictureFromElsewhereIsCenteredAndFitsTheScreen() {
        let small = PinGeometry.initialFrame(size: CGSize(width: 200, height: 100), requested: nil, visible: screen)
        #expect(small.frame == CGRect(x: 400, y: 350, width: 200, height: 100) && small.zoom == 1)
        let large = PinGeometry.initialFrame(size: CGSize(width: 2000, height: 1000), requested: nil, visible: screen)
        #expect(large.zoom == 0.4)
        #expect(large.frame == CGRect(x: 100, y: 200, width: 800, height: 400))
    }

    @Test func zoomingKeepsThePointUnderThePointer() {
        let frame = CGRect(x: 100, y: 100, width: 200, height: 100)
        let anchor = CGPoint(x: 150, y: 125)
        let zoomed = PinGeometry.zoomed(frame, by: 2, around: anchor)
        #expect(zoomed == CGRect(x: 50, y: 75, width: 400, height: 200))
        // The anchor sits at the same fraction of the pin before and after.
        #expect((anchor.x - zoomed.minX) / zoomed.width == (anchor.x - frame.minX) / frame.width)
    }

    @Test func scrollingZoomsAndFadesWithinBounds() {
        #expect(abs(PinGeometry.zoom(1, scrolledBy: 1, precise: false) - 1.105) < 0.001)
        #expect(PinGeometry.zoom(7.9, scrolledBy: 50, precise: false) == 8)
        #expect(PinGeometry.zoom(0.11, scrolledBy: -50, precise: false) == 0.1)
        #expect(abs(PinGeometry.opacity(0.8, scrolledBy: -1, precise: false) - 0.75) < 0.0001)
        #expect(PinGeometry.opacity(0.3, scrolledBy: -10, precise: false) == 0.2)
        #expect(PinGeometry.opacity(0.95, scrolledBy: 3, precise: false) == 1)
    }
}
