import AppKit
import OMSCore
import Testing
@testable import OMSCapture

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

    @Test func nativeToolbarTakesTheCursorAndHiddenToolbarReleasesItsWholeRegion() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        let bar = view.debugToolbarFrame
        let point = CGPoint(x: bar.midX, y: bar.midY)
        view.movePointer(to: global(point))
        #expect(view.wantsSystemCursor(at: global(point)))
        #expect(!view.debugPointerLayers.crosshair && view.debugPointerLayers.colorReading == nil)
        #expect(view.hitTest(point) !== view)
        view.setToolbarHidden(true)
        #expect(view.debugToolbarIsHidden)
        #expect(!view.wantsSystemCursor(at: global(point)))
        #expect(view.debugPointerLayers.crosshair)
        #expect(view.hitTest(point) === view)
        view.setToolbarHidden(false)
        #expect(view.wantsSystemCursor(at: global(point)))
        #expect(!view.debugPointerLayers.crosshair)
    }

    @Test func movingTheToolbarStaysOnScreenAndResetRestoresItsDefaultPosition() {
        let view = makeView()
        let initial = view.debugToolbarFrame
        view.debugMoveToolbar(by: CGVector(dx: 100, dy: 120))
        #expect(view.debugToolbarFrame.origin == CGPoint(x: initial.minX + 100, y: initial.minY + 120))
        view.debugMoveToolbar(by: CGVector(dx: 10000, dy: -10000))
        #expect(view.bounds.insetBy(dx: 8, dy: 8).contains(view.debugToolbarFrame))
        view.setToolbarHidden(true)
        view.reset(pointer: global(.zero), mode: .area, windows: [], showsToolbar: true)
        #expect(view.debugToolbarFrame == initial)
        #expect(!view.toolbarHiddenByUser && !view.debugToolbarIsHidden)
    }

    @Test func aSelectionDoesNotRestoreAnExplicitlyHiddenToolbar() {
        let view = makeView()
        view.setToolbarHidden(true)
        var selection = SelectionModel(bounds: Self.display.frame, pixelsPerPoint: 2)
        selection.begin(at: global(CGPoint(x: 100, y: 100)))
        selection.drag(to: global(CGPoint(x: 300, y: 300)))
        view.show(selection: selection, showsReading: true, isDragging: true)
        view.show(selection: selection, showsReading: true, isDragging: false)
        #expect(view.debugToolbarIsHidden && view.toolbarHiddenByUser)
        view.setToolbarHidden(false)
        let bar = view.debugToolbarFrame
        view.show(selection: selection, showsReading: true, isDragging: true)
        #expect(!view.wantsSystemCursor(at: global(CGPoint(x: bar.midX, y: bar.midY))))
    }

    @Test func onlyPlainHRequestsAVisibilityChangeAndUnavailableBarsStayHidden() throws {
        let view = makeView()
        var requests = 0
        view.onToolbarVisibilityToggle = { requests += 1; view.setToolbarHidden(!view.toolbarHiddenByUser) }
        for flags: NSEvent.ModifierFlags in [[], .command, .control, .option, .shift, []] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: "h", charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4
            ))
            view.keyDown(with: event)
        }
        #expect(requests == 2 && !view.debugToolbarIsHidden)
        let unavailable = makeView(showsToolbar: false)
        unavailable.setToolbarHidden(false)
        #expect(unavailable.debugToolbarIsHidden)
        view.enterAnnotation()
        view.setToolbarHidden(false)
        #expect(view.debugToolbarIsHidden)
    }

    @Test func hOnAnotherDisplayCanRestoreTheSessionsToolbar() throws {
        let view = makeView(showsToolbar: false)
        var requests = 0
        view.onToolbarVisibilityToggle = { requests += 1 }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "h", charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4
        ))
        view.keyDown(with: event)
        #expect(requests == 1 && view.debugToolbarIsHidden)
    }
}
