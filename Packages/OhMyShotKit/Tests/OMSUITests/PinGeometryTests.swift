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

    @Test func cornerButtonsStandInTheTopCornersOfARoomyPin() {
        let buttons = PinGeometry.cornerButtons(in: CGSize(width: 300, height: 200), button: 24)
        #expect(buttons.close == CGRect(x: 8, y: 168, width: 24, height: 24))
        #expect(buttons.more == CGRect(x: 268, y: 168, width: 24, height: 24))
    }

    @Test func aOneLineCardHasThemCenteredInItsHeight() {
        // A one-line text card is 38 pt tall at 100 percent.
        let buttons = PinGeometry.cornerButtons(in: CGSize(width: 103, height: 38), button: 24)
        #expect(buttons.close == CGRect(x: 8, y: 7, width: 24, height: 24))
        #expect(buttons.more == CGRect(x: 71, y: 7, width: 24, height: 24))
        // At 40 pt the two placements meet, so zooming never makes the buttons jump.
        #expect(PinGeometry.cornerButtons(in: CGSize(width: 103, height: 40), button: 24).close?.maxY == 32)
    }

    @Test func aNarrowPinHasCloseAloneAndATinyOneNeither() {
        let narrow = PinGeometry.cornerButtons(in: CGSize(width: 64, height: 64), button: 24)
        #expect(narrow.close == CGRect(x: 8, y: 32, width: 24, height: 24) && narrow.more == nil)
        #expect(narrow.trailing == CGRect(x: 32, y: 32, width: 24, height: 24))
        #expect(PinGeometry.cornerButtons(in: CGSize(width: 39, height: 64), button: 24).close == nil)
        #expect(PinGeometry.cornerButtons(in: CGSize(width: 200, height: 35), button: 24).close == nil)
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
