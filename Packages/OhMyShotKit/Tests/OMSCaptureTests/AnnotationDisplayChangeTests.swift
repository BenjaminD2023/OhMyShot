import CoreGraphics
import OMSCore
import Testing
@testable import OMSCapture

/// In-place annotation goes on through a change of displays as long as its own display is there as it was; the marks
/// are drawn on that display's frozen frame.
struct AnnotationDisplayChangeTests {
    private static func display(_ id: CGDirectDisplayID, x: CGFloat, width: CGFloat = 800, height: CGFloat = 600, scale: CGFloat = 2) -> DisplayInfo {
        DisplayInfo(
            id: id, name: "Display \(id)", frame: CGRect(x: x, y: 0, width: width, height: height),
            pixelSize: CGSize(width: width * scale, height: height * scale), backingScale: scale, maximumPotentialEDR: 1
        )
    }

    private static let builtIn = display(1, x: 0)
    private static let external = display(2, x: 800, width: 1600, height: 900, scale: 1)

    @Test func anotherDisplayComingOrGoingLeavesTheAnnotationBe() {
        #expect(OverlayController.keepsAnnotating(on: Self.builtIn, in: DisplayLayout(displays: [Self.builtIn, Self.external])))
        #expect(OverlayController.keepsAnnotating(on: Self.builtIn, in: DisplayLayout(displays: [Self.builtIn])))
        #expect(OverlayController.keepsAnnotating(on: Self.external, in: DisplayLayout(displays: [Self.builtIn, Self.external, Self.display(3, x: -800)])))
    }

    @Test func itsOwnDisplayRenamedLeavesTheAnnotationBe() {
        // A second monitor of the same model plugged in: macOS numbers the first one's name, and nothing else changes.
        let renamed = DisplayInfo(
            id: 2, name: "Display 2 (1)", frame: Self.external.frame, pixelSize: Self.external.pixelSize, backingScale: 1, maximumPotentialEDR: 1
        )
        #expect(OverlayController.keepsAnnotating(on: Self.external, in: DisplayLayout(displays: [Self.builtIn, renamed, Self.display(3, x: 2400)])))
    }

    @Test func itsOwnDisplayGoneMovedOrResizedEndsIt() {
        #expect(!OverlayController.keepsAnnotating(on: Self.external, in: DisplayLayout(displays: [Self.builtIn])))
        // Moved to the other side of the built-in display.
        #expect(!OverlayController.keepsAnnotating(on: Self.external, in: DisplayLayout(displays: [Self.builtIn, Self.display(2, x: -1600, width: 1600, height: 900, scale: 1)])))
        // Another resolution, or the same points at another scale.
        #expect(!OverlayController.keepsAnnotating(on: Self.builtIn, in: DisplayLayout(displays: [Self.display(1, x: 0, width: 1000, height: 750)])))
        #expect(!OverlayController.keepsAnnotating(on: Self.builtIn, in: DisplayLayout(displays: [Self.display(1, x: 0, scale: 1)])))
    }
}
