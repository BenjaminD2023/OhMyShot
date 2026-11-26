import AppKit
import CoreGraphics
import OMSCore
import Testing
@testable import OMSCapture

#if DEBUG
/// Multi-display overlay focus migration (`F-02`), All-In-One setup exits (`F-01`), and All-In-One Record
/// multi-window selection (`U-02`).
@MainActor
struct OverlayMultiDisplayAndAllInOneTests {
    /// Two synthetic displays placed far from real screen coordinates so `NSEvent.mouseLocation` never
    /// interferes with deterministic startup on `displayA` (`layout.primary`).
    private static let displayA = DisplayInfo(
        id: 101, name: "Left", frame: CGRect(x: 100_000, y: 0, width: 800, height: 600),
        pixelSize: CGSize(width: 1600, height: 1200), backingScale: 2, maximumPotentialEDR: 1
    )
    private static let displayB = DisplayInfo(
        id: 102, name: "Right", frame: CGRect(x: 100_800, y: 0, width: 800, height: 600),
        pixelSize: CGSize(width: 1600, height: 1200), backingScale: 2, maximumPotentialEDR: 1
    )
    private static let layout = DisplayLayout(displays: [displayA, displayB])

    private static func solidFrame(on display: DisplayInfo, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CapturedFrame {
        let width = Int(display.pixelSize.width)
        let height = Int(display.pixelSize.height)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return CapturedFrame(image: try #require(context.makeImage()), hdrImage: nil, displayID: display.id, frame: display.frame)
    }

    private func makeController() throws -> OverlayController {
        let controller = OverlayController(layoutProvider: { Self.layout }, capturer: ScreenCapturer(content: ShareableContentCache()))
        controller.presentsPanels = false
        controller.injectedFrames = [
            Self.displayA.id: try Self.solidFrame(on: Self.displayA, red: 1, green: 0, blue: 0),
            Self.displayB.id: try Self.solidFrame(on: Self.displayB, red: 0, green: 0, blue: 1),
        ]
        return controller
    }

    /// `U-02`: Choosing multiple windows while All-In-One is in Record mode enters recording setup for their
    /// union area instead of ending and dropping the session.
    @Test func allInOneRecordWithMultipleWindowsEntersRecordingSetup() throws {
        let controller = try makeController()
        defer { controller.cancel() }

        var outcomes: [OverlayController.Outcome] = []
        var willSetUpCount = 0
        controller.onWillSetUpRecording = { willSetUpCount += 1 }
        controller.begin(mode: .area, purpose: .screenshot, options: .init(allInOne: .init())) { outcomes.append($0) }

        let viewA = try #require(controller.overlayView(for: Self.displayA.id))
        controller.overlayView(viewA, didChooseMode: .record)

        let first = WindowTarget(id: 1, frame: CGRect(x: 100_100, y: 100, width: 200, height: 150), ownerName: "AppA", title: "One")
        let second = WindowTarget(id: 2, frame: CGRect(x: 100_250, y: 200, width: 200, height: 150), ownerName: "AppB", title: "Two")
        let expectedUnion = first.frame.union(second.frame)

        controller.overlayView(viewA, didSelectWindows: [first, second], modifiers: [])

        #expect(controller.isActive)
        #expect(outcomes.isEmpty)
        #expect(willSetUpCount == 1)
        #expect(controller.didSetUpRecording)
        let setup = try #require(controller.recordingSetup)
        #expect(setup.target == .area(expectedUnion))

        // Confirming Record completes with `.record(.area(expectedUnion), ...)`.
        setup.debugRecord()
        #expect(!controller.isActive)
        #expect(outcomes.count == 1)
        if case .record(let target, let display, _) = outcomes.first {
            #expect(target == .area(expectedUnion))
            #expect(display == Self.displayA)
        } else {
            Issue.record("Expected .record outcome, got \(String(describing: outcomes.first))")
        }
    }

    /// `F-01`: Pressing Delete/Backspace, Space, or W in All-In-One's framed setup exits back into area
    /// selection, direct window selection, or the window picker without ending the session.
    @Test func allInOneSetupBackspaceSpaceAndWReturnToSelectionModes() async throws {
        let controller = try makeController()
        defer { controller.cancel() }

        let initialArea = CGRect(x: 100_100, y: 120, width: 320, height: 200)
        var outcomes: [OverlayController.Outcome] = []
        controller.freezesScreen = false
        controller.begin(mode: .area, purpose: .screenshot, options: .init(allInOne: .init()), choosing: initialArea) { outcomes.append($0) }

        let setup1 = try #require(controller.allInOneSetup)
        #expect(controller.isActive && outcomes.isEmpty)

        // Backspace clears the framed area and returns to free area selection across both displays.
        _ = setup1.debugAct("backspace")
        #expect(controller.isActive)
        #expect(outcomes.isEmpty)
        #expect(controller.allInOneSetup == nil)
        let viewA = try #require(controller.overlayView(for: Self.displayA.id))
        let viewB = try #require(controller.overlayView(for: Self.displayB.id))
        #expect(viewA.mode == .area && !viewA.isAnnotating)
        #expect(viewB.mode == .area && !viewB.isAnnotating)
        #expect(controller.keyDisplayID == Self.displayA.id)
        #expect(controller.firstResponder(on: Self.displayA.id) === viewA)

        // Frame an area again, then press Space to enter direct window selection mode.
        controller.simulateSelection(initialArea)
        let setup2 = try #require(controller.allInOneSetup)
        _ = setup2.debugAct("space")
        #expect(controller.isActive && outcomes.isEmpty)
        #expect(controller.allInOneSetup == nil)
        #expect(viewA.mode == .window && !viewA.isAnnotating)
        #expect(viewB.mode == .window && !viewB.isAnnotating)

        // Switch back to area, frame again, then press W to open the Window Picker.
        controller.overlayView(viewA, didSwitchTo: .area)
        controller.simulateSelection(initialArea)
        let setup3 = try #require(controller.allInOneSetup)
        _ = setup3.debugAct("w")
        #expect(controller.isActive && outcomes.isEmpty)
        #expect(controller.allInOneSetup == nil)
        #expect(controller.activeWindowPicker != nil)
    }

    /// `F-02`: Moving the pointer across displays migrates keyboard focus so display-scoped keys operate
    /// on the pointer's display, while drags and hosted setup views keep focus locked.
    @Test func movingPointerAcrossDisplaysMigratesKeyboardFocusAndRoutesKeys() async throws {
        let controller = try makeController()
        defer { controller.cancel() }

        var outcomes: [OverlayController.Outcome] = []
        controller.freezesScreen = false
        controller.begin(mode: .area, purpose: .screenshot, options: .init(allInOne: .init())) { outcomes.append($0) }

        // Wait briefly for injected frames to load onto both displays.
        for _ in 0..<50 where !controller.hasFrames {
            try await Task.sleep(for: .milliseconds(5))
        }

        let viewA = try #require(controller.overlayView(for: Self.displayA.id))
        let viewB = try #require(controller.overlayView(for: Self.displayB.id))
        #expect(controller.keyDisplayID == Self.displayA.id)
        #expect(controller.firstResponder(on: Self.displayA.id) === viewA)

        // Move pointer onto Display B: focus migrates to Display B and Display A clears its stale pointer.
        let pointOnB = CGPoint(x: 101_100, y: 250)
        controller.overlayView(viewA, didMovePointerTo: pointOnB)
        #expect(controller.keyDisplayID == Self.displayB.id)
        #expect(controller.firstResponder(on: Self.displayB.id) === viewB)
        #expect(viewA.currentPointer == nil)
        #expect(viewB.currentPointer != nil)

        // While dragging on Display B, moving onto Display A does NOT steal key focus.
        controller.overlayView(viewB, didPressAt: pointOnB)
        controller.overlayView(viewB, didMovePointerTo: CGPoint(x: 100_300, y: 250))
        #expect(controller.keyDisplayID == Self.displayB.id)
        controller.overlayViewDidResetDrag(viewB)

        // Move back onto Display B and press F: captures Display B's whole screen, not Display A's.
        controller.overlayView(viewA, didMovePointerTo: pointOnB)
        #expect(controller.keyDisplayID == Self.displayB.id)
        let pressF = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3
        ))
        viewB.keyDown(with: pressF)

        if case .allInOne(.screenshot(nil), let rect, let display, _) = outcomes.first {
            #expect(display == Self.displayB)
            #expect(rect == Self.displayB.frame)
        } else {
            Issue.record("Expected fullscreen All-In-One capture on Display B, got \(String(describing: outcomes.first))")
        }
    }

    /// `F-02`: In window mode, moving the pointer onto another display clears stale `pointer` and non-spanning
    /// `hoveredWindow` on the old display, while keeping a spanning window highlighted without late-exit flicker.
    @Test func windowModeClearsNonSpanningHoverAndPreservesSpanningWindowAcrossDisplays() throws {
        let viewA = OverlayView(display: Self.displayA)
        let viewB = OverlayView(display: Self.displayB)
        let onlyOnA = WindowTarget(id: 10, frame: CGRect(x: 100_100, y: 100, width: 300, height: 250), ownerName: "AppA", title: "Left")
        let onlyOnB = WindowTarget(id: 20, frame: CGRect(x: 101_000, y: 100, width: 300, height: 250), ownerName: "AppB", title: "Right")
        let spanning = WindowTarget(id: 30, frame: CGRect(x: 100_650, y: 350, width: 300, height: 150), ownerName: "Span", title: "Across")
        let windows = [onlyOnA, onlyOnB, spanning]

        let pointOnA = CGPoint(x: 100_200, y: 200)
        viewA.reset(pointer: pointOnA, mode: .window, windows: windows, showsToolbar: false)
        viewB.reset(pointer: pointOnA, mode: .window, windows: windows, showsToolbar: false)
        #expect(viewA.hoveredWindow == onlyOnA && viewA.currentPointer != nil)
        #expect(viewB.hoveredWindow == nil && viewB.currentPointer == nil)

        // Move onto a window exclusively on Display B: Display A clears both pointer and hoveredWindow.
        let pointOnB = CGPoint(x: 101_100, y: 200)
        viewA.movePointer(to: pointOnB)
        viewB.movePointer(to: pointOnB)
        #expect(viewA.currentPointer == nil && viewA.hoveredWindow == nil)
        #expect(viewB.currentPointer != nil && viewB.hoveredWindow == onlyOnB)

        // Move onto the spanning window on Display B: Display A keeps the spanning highlight with nil pointer.
        let pointOnSpanInB = CGPoint(x: 100_850, y: 400)
        viewA.movePointer(to: pointOnSpanInB)
        viewB.movePointer(to: pointOnSpanInB)
        #expect(viewA.currentPointer == nil && viewA.hoveredWindow == spanning)
        #expect(viewB.currentPointer != nil && viewB.hoveredWindow == spanning)

        // A late mouseExited on Display A after the pointer already moved onto Display B must not wipe the spanning hover.
        let exitEvent = try #require(NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        viewA.mouseExited(with: exitEvent)
        #expect(viewA.hoveredWindow == spanning)
    }

    /// `F-02`: When a hosted setup view is open on Display A, pointer movement onto Display B does not steal focus.
    @Test func hostedSetupViewKeepsFocusWhenPointerMovesToAnotherDisplay() throws {
        let controller = try makeController()
        defer { controller.cancel() }

        let initialArea = CGRect(x: 100_100, y: 120, width: 320, height: 200)
        controller.freezesScreen = false
        controller.begin(mode: .area, purpose: .screenshot, options: .init(allInOne: .init()), choosing: initialArea) { _ in }

        let viewA = try #require(controller.overlayView(for: Self.displayA.id))
        let setup = try #require(controller.allInOneSetup)
        #expect(controller.keyDisplayID == Self.displayA.id)
        #expect(controller.firstResponder(on: Self.displayA.id) === setup)

        controller.overlayView(viewA, didMovePointerTo: CGPoint(x: 101_100, y: 250))
        #expect(controller.keyDisplayID == Self.displayA.id)
        #expect(controller.firstResponder(on: Self.displayA.id) === setup)
    }

    /// `U-03`: Picking an Accessibility element of a window in All-In-One mode routes into All-In-One's
    /// area setup bar instead of skipping the bar and capturing immediately.
    @Test func pickedElementInAllInOneRoutesIntoAreaSetupBar() throws {
        let controller = try makeController()
        defer { controller.cancel() }

        var outcomes: [OverlayController.Outcome] = []
        controller.freezesScreen = false
        controller.begin(mode: .area, purpose: .screenshot, options: .init(allInOne: .init())) { outcomes.append($0) }

        let viewA = try #require(controller.overlayView(for: Self.displayA.id))
        let elementFrame = CGRect(x: 100_120, y: 140, width: 240, height: 180)
        controller.overlayView(viewA, didSelectElement: elementFrame, modifiers: [])

        #expect(controller.isActive && outcomes.isEmpty)
        let setup = try #require(controller.allInOneSetup)
        #expect(setup.area == elementFrame)
    }

    /// `U-03`: Clicking "Select on Screen" in the modal Window Picker seamlessly transitions to direct
    /// on-screen window hover/click mode across all displays.
    @Test func windowPickerSelectOnScreenTransitionsToDirectWindowMode() throws {
        let controller = try makeController()
        defer { controller.cancel() }

        var outcomes: [OverlayController.Outcome] = []
        controller.freezesScreen = false
        controller.begin(mode: .windowPicker, purpose: .screenshot) { outcomes.append($0) }

        let picker = try #require(controller.activeWindowPicker)
        let switchAction = try #require(picker.onSelectOnScreen)
        switchAction()

        #expect(controller.isActive && outcomes.isEmpty)
        #expect(controller.activeWindowPicker == nil)
        let viewA = try #require(controller.overlayView(for: Self.displayA.id))
        let viewB = try #require(controller.overlayView(for: Self.displayB.id))
        #expect(viewA.mode == .window && viewB.mode == .window)
    }

    /// `F-03`: Shift-clicking windows on Display A and Display B combines both in a shared multi-window
    /// selection with consistent order badges ("1" on Display A, "2" on Display B).
    @Test func shiftClickingWindowsAcrossDisplaysCombinesBoth() throws {
        let controller = try makeController()
        defer { controller.cancel() }

        var outcomes: [OverlayController.Outcome] = []
        controller.freezesScreen = false
        controller.begin(mode: .area, purpose: .screenshot) { outcomes.append($0) }

        let winA = WindowTarget(id: 11, frame: CGRect(x: 100_100, y: 100, width: 300, height: 240), ownerName: "AppA", title: "Left")
        let winB = WindowTarget(id: 22, frame: CGRect(x: 100_950, y: 120, width: 300, height: 240), ownerName: "AppB", title: "Right")
        let viewA = try #require(controller.overlayView(for: Self.displayA.id))
        let viewB = try #require(controller.overlayView(for: Self.displayB.id))
        viewA.switchMode(to: .window, windows: [winA, winB])
        viewB.switchMode(to: .window, windows: [winA, winB])

        // Hover and Shift-click Window A on Display A.
        controller.overlayView(viewA, didMovePointerTo: CGPoint(x: 100_200, y: 200))
        #expect(viewA.hoveredWindow == winA)
        let shiftClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 200, y: 200), modifierFlags: .shift, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        viewA.mouseUp(with: shiftClick)
        #expect(viewA.selectedWindows == [winA] && viewB.selectedWindows == [winA])
        #expect(viewA.debugSelectedWindowBadges == ["1"] && viewB.debugSelectedWindowBadges.isEmpty)

        // Move onto Display B and Shift-click Window B.
        controller.overlayView(viewA, didMovePointerTo: CGPoint(x: 101_050, y: 200))
        #expect(viewB.hoveredWindow == winB)
        viewB.mouseUp(with: shiftClick)
        #expect(viewA.selectedWindows == [winA, winB] && viewB.selectedWindows == [winA, winB])
        #expect(viewA.debugSelectedWindowBadges == ["1"] && viewB.debugSelectedWindowBadges == ["2"])

        // Confirm with an unshifted click on Display B -> ends with both windows.
        let confirmClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 250, y: 200), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        viewB.mouseUp(with: confirmClick)
        #expect(!controller.isActive && outcomes.count == 1)
        if case .windows(let targets, _) = outcomes.first {
            #expect(targets == [winA, winB])
        } else {
            Issue.record("Expected .windows([winA, winB]), got \(String(describing: outcomes.first))")
        }
    }

    /// `M-04`: `L` recalls the last area in `.record` and `.scroll` sessions, and Annotate Area's
    /// Tab sizing bar labels its primary action "Annotate".
    @Test func lastAreaWorksInRecordAndScrollAndAnnotateSizingUsesAnnotateLabel() async throws {
        let recalled = CGRect(x: 100_120, y: 120, width: 320, height: 200)

        // Record session recalls last area into RecordingSetupView.
        do {
            let controller = try makeController()
            defer { controller.cancel() }
            controller.freezesScreen = false
            controller.lastArea = recalled
            controller.begin(mode: .area, purpose: .record) { _ in }
            let viewA = try #require(controller.overlayView(for: Self.displayA.id))
            controller.overlayViewDidRequestLastArea(viewA)
            let setup = try #require(controller.recordingSetup)
            #expect(setup.target == .area(recalled))
        }

        // Scroll session recalls last area into ScrollingSetupView.
        do {
            let controller = try makeController()
            defer { controller.cancel() }
            controller.freezesScreen = false
            controller.lastArea = recalled
            controller.begin(mode: .area, purpose: .scroll) { _ in }
            let viewA = try #require(controller.overlayView(for: Self.displayA.id))
            controller.overlayViewDidRequestLastArea(viewA)
            let setup = try #require(controller.scrollingSetup)
            #expect(setup.area == recalled)
        }

        // Annotate Area always freezes the screen (hasInput becomes true once the first frame loads)
        // and labels its sizing bar's primary action "Annotate" instead of "Capture".
        do {
            let controller = try makeController()
            defer { controller.cancel() }
            controller.lastArea = recalled
            controller.begin(mode: .area, purpose: .annotate) { _ in }
            for _ in 0..<50 where !controller.hasFrames {
                try await Task.sleep(for: .milliseconds(5))
            }
            let viewA = try #require(controller.overlayView(for: Self.displayA.id))
            controller.overlayViewDidRequestLastArea(viewA)
            let setup = try #require(controller.allInOneSetup)
            #expect(setup.primaryActionTitle == "Annotate")
        }
    }
}
#endif
