import AppKit
import OMSCore
import Testing
@testable import OMSCapture

/// What L brings back after a session: the area it took, whatever All-In-One took it for; a window, a color, or nothing
/// leave the last one in place.
struct TakenAreaTests {
    /// A 2× display 800 × 600 points with its bottom-left corner at the origin.
    private static let display = DisplayInfo(
        id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 1600, height: 1200),
        backingScale: 2, maximumPotentialEDR: 1
    )
    private static let area = CGRect(x: 100, y: 200, width: 300, height: 150)
    private static let window = WindowTarget(id: 10, frame: CGRect(x: 50, y: 50, width: 400, height: 300), ownerName: "Notes", title: "Today")

    @Test func everyAllInOneChoiceLeavesItsAreaForL() {
        for choice: AllInOneChoice in [.screenshot(nil), .screenshot(.copy), .screenshot(.annotate), .text, .scroll, .record] {
            let outcome = OverlayController.Outcome.allInOne(choice, Self.area, display: Self.display, frozen: nil)
            #expect(outcome.takenArea == Self.area, "\(choice)")
        }
        #expect(OverlayController.Outcome.region(Self.area, display: Self.display, modifiers: [], frozen: nil).takenArea == Self.area)
        #expect(OverlayController.Outcome.record(.area(Self.area), display: Self.display, choices: RecordingChoices()).takenArea == Self.area)
        #expect(OverlayController.Outcome.record(.display, display: Self.display, choices: RecordingChoices()).takenArea == Self.display.frame)
        #expect(OverlayController.Outcome.scroll(Self.area, display: Self.display, autoScrolls: false).takenArea == Self.area)
    }

    @Test func aWindowOrNothingLeavesNoArea() {
        #expect(OverlayController.Outcome.window(Self.window, modifiers: []).takenArea == nil)
        #expect(OverlayController.Outcome.windows([Self.window], modifiers: []).takenArea == nil)
        #expect(OverlayController.Outcome.record(.window(Self.window), display: Self.display, choices: RecordingChoices()).takenArea == nil)
        #expect(OverlayController.Outcome.annotated.takenArea == nil)
        #expect(OverlayController.Outcome.cancelled.takenArea == nil)
    }
}
