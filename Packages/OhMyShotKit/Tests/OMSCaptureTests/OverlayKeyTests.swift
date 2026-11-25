import AppKit
import OMSCore
import Testing
@testable import OMSCapture

/// The overlay's keys by purpose: Return belongs to Pick Color and Measure only; the arrows move the crosshair there
/// and while an area is chosen; Tab opens Capture Area's size control.
@MainActor
struct OverlayKeyTests {
    /// What the overlay told its controller, by name.
    private final class Recorder: OverlayViewDelegate {
        var heard: [String] = []
        /// The last nudge, in pixels, down positive.
        var nudge: CGVector?
        /// What F last handed on.
        var captured: (measurement: RulerMeasurement, frame: CapturedFrame)?
        /// The modifiers forwarded with the last window or multi-window selection.
        var lastWindowModifiers: NSEvent.ModifierFlags?

        func overlayView(_ view: OverlayView, didPressAt point: CGPoint) { heard.append("press") }
        func overlayView(_ view: OverlayView, didDragTo point: CGPoint, modifiers: NSEvent.ModifierFlags) { heard.append("drag") }
        func overlayView(_ view: OverlayView, didReleaseWith modifiers: NSEvent.ModifierFlags) { heard.append("release") }
        func overlayView(_ view: OverlayView, didChangeModifiers modifiers: NSEvent.ModifierFlags) { heard.append("modifiers") }
        func overlayView(_ view: OverlayView, didMovePointerTo point: CGPoint) { heard.append("move") }
        func overlayView(_ view: OverlayView, didPressSpace isRepeat: Bool) { heard.append("space") }
        func overlayViewDidReleaseSpace(_ view: OverlayView) { heard.append("space up") }
        func overlayView(_ view: OverlayView, didSelect rect: CGRect, modifiers: NSEvent.ModifierFlags) { heard.append("select") }
        func overlayView(_ view: OverlayView, didSelectElement rect: CGRect, modifiers: NSEvent.ModifierFlags) { heard.append("element") }
        func overlayView(_ view: OverlayView, didSelectWindow target: WindowTarget, modifiers: NSEvent.ModifierFlags) {
            heard.append("window")
            lastWindowModifiers = modifiers
        }
        func overlayView(_ view: OverlayView, didSelectWindows targets: [WindowTarget], modifiers: NSEvent.ModifierFlags) {
            heard.append("windows \(targets.map(\.id))")
            lastWindowModifiers = modifiers
        }
        func overlayView(_ view: OverlayView, didChangeSelectedWindows targets: [WindowTarget]) {}
        func overlayView(_ view: OverlayView, didSwitchTo mode: OverlayView.Mode) { heard.append("switch") }
        func overlayViewDidRequestWindowPicker(_ view: OverlayView) { heard.append("windowPicker") }
        func overlayViewDidCancel(_ view: OverlayView) { heard.append("cancel") }
        func overlayView(_ view: OverlayView, didPickColorAt point: CGPoint, modifiers: NSEvent.ModifierFlags, keyboard: Bool) { heard.append("pick") }
        func overlayView(_ view: OverlayView, didChangeColorFormat format: ColorFormat) { heard.append("colorFormat \(format.rawValue)") }
        func overlayView(_ view: OverlayView, didNudge pixels: CGVector) {
            heard.append("nudge")
            nudge = pixels
        }
        func overlayViewDidRequestSizing(_ view: OverlayView) { heard.append("size") }
        func overlayViewDidRequestLastArea(_ view: OverlayView) { heard.append("lastArea") }
        func overlayViewDidResetDrag(_ view: OverlayView) { heard.append("resetDrag") }
        func overlayView(_ view: OverlayView, didCopyMeasurement text: String, ending: Bool) { heard.append("copy") }
        func overlayView(_ view: OverlayView, didCaptureMeasurement measurement: RulerMeasurement, of frame: CapturedFrame) {
            heard.append("capture")
            captured = (measurement, frame)
        }
        func overlayView(_ view: OverlayView, didChangeUnit unit: MeasureUnit) { heard.append("unit") }
        func overlayView(_ view: OverlayView, didChangeTolerance tolerance: MeasureTolerance) { heard.append("tolerance \(tolerance.rawValue)") }
        func overlayView(_ view: OverlayView, didChooseMode choice: AllInOneChoice) { heard.append("mode \(choice)") }
        func overlayViewDidRequestMeasure(_ view: OverlayView) { heard.append("measure") }
    }

    /// Takes the keys the overlay passes on, so none reaches the end of the chain and beeps.
    private final class PassedOn: NSResponder {
        var keys: [UInt16] = []

        override func keyDown(with event: NSEvent) {
            keys.append(event.keyCode)
        }
    }

    private static let display = DisplayInfo(
        id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 1600, height: 1200),
        backingScale: 2, maximumPotentialEDR: 1
    )

    /// What pressing `keyCode` in an overlay for `purpose`, the pointer in its middle, tells the controller,
    /// and whether the key was passed on.
    private func press(
        _ keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = [], in purpose: OverlayController.Purpose,
        mode: OverlayView.Mode = .area, allInOne: Bool = false
    ) throws -> (heard: [String], passedOn: Bool, nudge: CGVector?) {
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        let passedOn = PassedOn()
        view.delegate = recorder
        view.nextResponder = passedOn
        view.reset(pointer: CGPoint(x: 400, y: 300), mode: mode, windows: [], showsToolbar: false, purpose: purpose, allInOne: allInOne)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
        view.keyDown(with: event)
        return (recorder.heard, !passedOn.keys.isEmpty, recorder.nudge)
    }

    @Test func wOpensTheWindowPreviewWhileSpaceKeepsDirectPointing() throws {
        for purpose in [OverlayController.Purpose.screenshot, .record] {
            let result = try press(13, characters: "w", in: purpose)
            #expect(result.heard == ["windowPicker"] && !result.passedOn)
            #expect(try press(49, characters: " ", in: purpose).heard == ["space"])
        }
        for purpose in [OverlayController.Purpose.annotate, .scroll, .text, .color, .measure] {
            #expect(try press(13, characters: "W", modifiers: .shift, in: purpose).heard.isEmpty)
        }
        #expect(try press(13, characters: "w", in: .screenshot, allInOne: true).heard == ["windowPicker"])
        #expect(try press(13, characters: "W", modifiers: [.command, .shift], in: .screenshot).heard.isEmpty)
    }

    private static let arrows: [UInt16] = [123, 124, 125, 126]
    private static let returns: [UInt16] = [36, 76]

    /// Return is a color picker's and the ruler's; choosing an area, it is passed on.
    @Test func whileCapturingReturnIsPassedOn() throws {
        for purpose in [OverlayController.Purpose.screenshot, .text, .annotate, .record, .scroll] {
            for key in Self.returns {
                let result = try press(key, in: purpose)
                #expect(result.heard.isEmpty && result.passedOn, "key \(key) in \(purpose): \(result.heard)")
            }
        }
    }

    /// Choosing an area, the arrows move the crosshair, or the corner being dragged, a pixel at a time (down positive),
    /// ten with Shift; choosing a window, which has no crosshair, they are passed on.
    @Test func whileChoosingAnAreaTheArrowsNudgeByAPixel() throws {
        let steps: [(UInt16, CGVector)] = [
            (123, CGVector(dx: -1, dy: 0)), (124, CGVector(dx: 1, dy: 0)), (125, CGVector(dx: 0, dy: 1)), (126, CGVector(dx: 0, dy: -1)),
        ]
        for purpose in [OverlayController.Purpose.screenshot, .text, .annotate, .record, .scroll] {
            for (key, step) in steps {
                let result = try press(key, in: purpose)
                #expect(result.heard == ["nudge"] && result.nudge == step && !result.passedOn, "key \(key) in \(purpose): \(result.heard)")
            }
        }
        #expect(try press(124, modifiers: .shift, in: .screenshot).nudge == CGVector(dx: 10, dy: 0))
        #expect(try press(125, modifiers: .shift, in: .screenshot, allInOne: true).nudge == CGVector(dx: 0, dy: 10))
        for key in Self.arrows {
            let result = try press(key, in: .screenshot, mode: .window)
            #expect(result.heard.isEmpty && result.passedOn, "key \(key) in window mode: \(result.heard)")
        }
    }

    /// Tab frames the area for a size typed, in Capture Area and Annotate Area; elsewhere it is passed on (All-In-One's
    /// area is framed after its drag; Measure's Tab is its unit; Pick Color's Tab cycles color format).
    @Test func tabOpensTheSizeControlWhereAnAreaIsChosen() throws {
        for purpose in [OverlayController.Purpose.screenshot, .annotate] {
            let result = try press(48, characters: "\t", in: purpose)
            #expect(result.heard == ["size"] && !result.passedOn, "\(purpose): \(result.heard)")
        }
        for purpose in [OverlayController.Purpose.text, .record, .scroll] {
            let result = try press(48, characters: "\t", in: purpose)
            #expect(result.heard.isEmpty && result.passedOn, "\(purpose): \(result.heard)")
        }
        let colorForward = try press(48, characters: "\t", in: .color)
        #expect(colorForward.heard == ["colorFormat rgb"] && !colorForward.passedOn)
        let colorBackward = try press(48, characters: "\t", modifiers: .shift, in: .color)
        #expect(colorBackward.heard == ["colorFormat displayP3"] && !colorBackward.passedOn)
        let allInOne = try press(48, characters: "\t", in: .screenshot, allInOne: true)
        #expect(allInOne.heard.isEmpty && allInOne.passedOn)
        let window = try press(48, characters: "\t", in: .screenshot, mode: .window)
        #expect(window.heard.isEmpty && window.passedOn)
    }

    /// All-In-One's letters choose a mode before an area: O text, S scrolling, R recording; W a window, F the screen; M
    /// turns the overlay into Measure.
    @Test func allInOneLettersChooseWhatTheNextAreaIsFor() throws {
        let cases: [(UInt16, String, [String])] = [
            (31, "o", ["mode text"]), (1, "s", ["mode scroll"]), (15, "r", ["mode record"]),
            (13, "w", ["windowPicker"]), (3, "f", ["select"]), (46, "m", ["measure"]),
            // A: a plain capture of an area, letting go of what the next area was for.
            (0, "a", ["mode screenshot(nil)"]),
        ]
        for (code, letter, heard) in cases {
            let result = try press(code, characters: letter, in: .screenshot, allInOne: true)
            #expect(result.heard == heard && !result.passedOn, "\(letter): \(result.heard)")
        }
    }

    /// Other All-In-One purpose letters are passed on by Capture Area.
    @Test func captureAreaPassesTheOtherModeLettersOn() throws {
        for (code, letter) in [(UInt16(31), "o"), (1, "s"), (15, "r"), (3, "f"), (46, "m")] {
            let result = try press(code, characters: letter, in: .screenshot)
            #expect(result.heard.isEmpty && result.passedOn, "\(letter): \(result.heard)")
        }
    }

    /// Every letter on All-In-One's bar is its own and none is L's or C's, which recall the last area and take a color
    /// there; M, which takes no area, is no key of the framed area's either, where the bar's other mode letters stay.
    @Test func allInOneLettersNeverCollide() {
        let letters = AllInOneBar.Choice.allCases.compactMap(\.key)
        #expect(Set(letters).count == letters.count)
        #expect(Set(letters).isDisjoint(with: ["l", "c"]))
        #expect(AllInOneBar.Choice(key: "m") == .measure && AllInOneBar.Choice.measure.purpose == nil)
        #expect(AllInOneSetupView.choice(for: "m") == nil)
        #expect(["o", "s", "r"].map(AllInOneSetupView.choice(for:)) == [.text, .scroll, .record])
    }

    /// Once All-In-One turns into Measure, the keys are Measure's: T sets the tolerance and Tab the unit, while M and
    /// All-In-One's other letters are passed on.
    @Test func turnedToMeasureTheKeysAreMeasures() throws {
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        let passedOn = PassedOn()
        view.delegate = recorder
        view.nextResponder = passedOn
        view.reset(pointer: CGPoint(x: 400, y: 300), mode: .area, windows: [], showsToolbar: false, purpose: .screenshot, allInOne: true)
        view.turnToMeasure(pointer: CGPoint(x: 400, y: 300), colorFormat: .hex, unit: .points, tolerance: .medium, snapsToContent: true)
        for (code, character) in [(UInt16(17), "t"), (48, "\t"), (46, "m"), (31, "o"), (15, "r")] {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: code
            ))
            view.keyDown(with: event)
        }
        #expect(recorder.heard == ["tolerance high", "unit"])
        #expect(passedOn.keys == [46, 31, 15])
    }

    @Test func pickingAColorTheArrowsMoveAndReturnPicks() throws {
        for key in Self.arrows {
            #expect(try press(key, in: .color).heard == ["nudge"], "key \(key)")
        }
        for key in Self.returns {
            #expect(try press(key, in: .color).heard == ["pick"], "key \(key)")
        }
    }

    @Test func measuringReturnNeverPicksAColor() throws {
        for key in Self.arrows {
            #expect(try press(key, in: .measure).heard == ["nudge"], "key \(key)")
        }
        // With nothing measured yet there is nothing to copy; above all, no color is picked.
        for key in Self.returns {
            let result = try press(key, in: .measure)
            #expect(!result.heard.contains("pick") && !result.passedOn, "key \(key): \(result.heard)")
        }
        #expect(try press(48, in: .measure).heard == ["unit"])
    }

    /// F keeps the display with what is measured on it: only while measuring, without Command, Control, or Option, and
    /// only once something is measured.
    @Test func measuringFCapturesTheDisplayWithTheMeasurement() throws {
        let empty = try press(3, characters: "f", in: .measure)
        #expect(empty.heard.isEmpty && !empty.passedOn)
        for purpose in [OverlayController.Purpose.screenshot, .annotate, .color, .text, .record, .scroll] {
            #expect(try !press(3, characters: "f", in: purpose).heard.contains("capture"))
        }

        let view = OverlayView(display: Self.display)
        defer { view.clear() }
        let recorder = Recorder()
        let passedOn = PassedOn()
        view.delegate = recorder
        view.nextResponder = passedOn
        view.reset(pointer: CGPoint(x: 400, y: 300), mode: .area, windows: [], showsToolbar: false, purpose: .measure)
        let context = try #require(CGContext(
            data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        let frame = CapturedFrame(image: try #require(context.makeImage()), hdrImage: nil, displayID: Self.display.id, frame: Self.display.frame)
        view.show(frame, frozen: true)
        view.debugMeasureBox(CGRect(x: 100, y: 100, width: 100, height: 50))
        func f(_ modifiers: NSEvent.ModifierFlags = []) throws {
            view.keyDown(with: try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: "f",
                charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3
            )))
        }
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
            try f(modifier)
        }
        #expect(!recorder.heard.contains("capture"))
        try f()
        #expect(recorder.heard.last == "capture")
        #expect(recorder.captured?.frame.image === frame.image)
        // The box in the frame's pixels from its top left: 100 pt up from the bottom of a 600 pt display, at 2×.
        #expect(recorder.captured?.measurement == RulerMeasurement(
            shape: .box(CGRect(x: 200, y: 900, width: 200, height: 100)), unit: .points, pixelsPerPoint: 2
        ))
    }

    @Test func toleranceKeysBelongOnlyToMeasureWithoutCommandModifiers() throws {
        let keys: [(UInt16, String, String)] = [(17, "t", "high"), (24, "=", "high"), (24, "+", "high"), (27, "-", "low")]
        for (code, character, expected) in keys {
            let result = try press(code, characters: character, in: .measure)
            #expect(result.heard == ["tolerance \(expected)"] && !result.passedOn)
            for purpose in [OverlayController.Purpose.screenshot, .annotate, .color, .text, .record, .scroll] {
                #expect(try press(code, characters: character, in: purpose).heard.isEmpty)
            }
            for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
                #expect(try press(code, characters: character, modifiers: modifier, in: .measure).heard.isEmpty)
            }
        }
    }

    @Test func windowModeCyclesOverlappingWindowsAndCombinesShiftClicksIncludingReturn() throws {
        let front = WindowTarget(id: 10, frame: CGRect(x: 100, y: 100, width: 400, height: 300), ownerName: "AppA", title: "Front")
        let back = WindowTarget(id: 20, frame: CGRect(x: 150, y: 120, width: 400, height: 300), ownerName: "AppB", title: "Back")
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        view.delegate = recorder
        view.reset(pointer: CGPoint(x: 200, y: 200), mode: .window, windows: [front, back], showsToolbar: false, purpose: .screenshot)
        #expect(view.hoveredWindow == front)

        // Tab cycles to the overlapping window behind.
        let tab = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ))
        view.keyDown(with: tab)
        #expect(view.hoveredWindow == back)

        // Shift-click adds and toggles `back` in `selectedWindows` without ending the session.
        let shiftUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 200, y: 200), modifierFlags: .shift, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        view.mouseUp(with: shiftUp)
        #expect(view.selectedWindows == [back] && recorder.heard.isEmpty)
        view.mouseUp(with: shiftUp)
        #expect(view.selectedWindows.isEmpty && recorder.heard.isEmpty)
        view.mouseUp(with: shiftUp)
        #expect(view.selectedWindows == [back] && recorder.heard.isEmpty)

        // Tab cycles back to `front`; Shift adds it too, and Return finishes with both windows.
        view.keyDown(with: tab)
        #expect(view.hoveredWindow == front)
        let shiftFrontUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 200, y: 200), modifierFlags: .shift, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        view.mouseUp(with: shiftFrontUp)
        #expect(view.selectedWindows == [back, front] && recorder.heard.isEmpty)
        let enter = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        view.keyDown(with: enter)
        #expect(recorder.heard == ["windows [20, 10]"])
    }

    @Test func unshiftedWindowClickConfirmsLockedWindowsWithoutAppendingUnshiftedHover() throws {
        let front = WindowTarget(id: 10, frame: CGRect(x: 100, y: 100, width: 400, height: 300), ownerName: "AppA", title: "Front")
        let back = WindowTarget(id: 20, frame: CGRect(x: 150, y: 120, width: 400, height: 300), ownerName: "AppB", title: "Back")
        let third = WindowTarget(id: 30, frame: CGRect(x: 120, y: 110, width: 400, height: 300), ownerName: "AppC", title: "Third")
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        view.delegate = recorder
        view.reset(pointer: CGPoint(x: 200, y: 200), mode: .window, windows: [front, back, third], showsToolbar: false, purpose: .screenshot)
        let tab = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ))
        view.keyDown(with: tab)
        #expect(view.hoveredWindow == back)
        let shiftUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 200, y: 200), modifierFlags: .shift, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        view.mouseUp(with: shiftUp)
        #expect(view.selectedWindows == [back] && recorder.heard.isEmpty)

        // Tab to `third` and Shift-click to add a second locked window; then Tab to `front` (unlocked hover).
        view.keyDown(with: tab)
        #expect(view.hoveredWindow == third)
        view.mouseUp(with: shiftUp)
        #expect(view.selectedWindows == [back, third] && recorder.heard.isEmpty)

        view.keyDown(with: tab)
        #expect(view.hoveredWindow == front)
        #if DEBUG
        #expect(view.debugHasLockedWindowPaths)
        #expect(view.debugSelectedWindowBadges == ["1", "2"])
        #expect(view.debugHasHoveredWindowPath && view.debugHoveredBorderDashed)
        #endif

        // An unshifted click confirms ONLY `selectedWindows`, never silently appending the unshifted hovered 3rd window.
        let clickUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 200, y: 200), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        view.mouseUp(with: clickUp)
        #expect(recorder.heard == ["windows [20, 30]"])
    }

    @Test func allInOneWindowModeUsesTheSameShiftMultiSelection() throws {
        let front = WindowTarget(id: 10, frame: CGRect(x: 100, y: 100, width: 400, height: 300), ownerName: "AppA", title: "Front")
        let back = WindowTarget(id: 20, frame: CGRect(x: 150, y: 120, width: 400, height: 300), ownerName: "AppB", title: "Back")
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        view.delegate = recorder
        view.reset(pointer: CGPoint(x: 200, y: 200), mode: .window, windows: [front, back], showsToolbar: false, purpose: .screenshot, allInOne: true)
        let tab = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
        ))
        view.keyDown(with: tab)
        let shiftUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 200, y: 200), modifierFlags: .shift, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        view.mouseUp(with: shiftUp)
        view.keyDown(with: tab)
        let shiftFrontUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 200, y: 200), modifierFlags: .shift, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        view.mouseUp(with: shiftFrontUp)
        let enter = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        view.keyDown(with: enter)
        #expect(recorder.heard == ["windows [20, 10]"])
    }

    @Test func allInOneAreaModeReturnFinishesItsShiftSelectedWindows() throws {
        let front = WindowTarget(id: 10, frame: CGRect(x: 100, y: 100, width: 400, height: 300), ownerName: "AppA", title: "Front")
        let back = WindowTarget(id: 20, frame: CGRect(x: 150, y: 120, width: 400, height: 300), ownerName: "AppB", title: "Back")
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        view.delegate = recorder
        view.reset(pointer: CGPoint(x: 200, y: 200), mode: .area, windows: [], showsToolbar: false, purpose: .screenshot, allInOne: true)
        view.setSelectedWindows([back, front])
        let enter = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        view.keyDown(with: enter)
        #expect(recorder.heard == ["windows [20, 10]"])
    }

    @Test func recordWindowModeDoesNotTreatShiftAsMultiSelection() throws {
        let target = WindowTarget(id: 10, frame: CGRect(x: 100, y: 100, width: 400, height: 300), ownerName: "AppA", title: "Front")
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        view.delegate = recorder
        view.reset(pointer: CGPoint(x: 200, y: 200), mode: .window, windows: [target], showsToolbar: false, purpose: .record)
        let shiftUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 200, y: 200), modifierFlags: .shift, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        view.mouseUp(with: shiftUp)
        #expect(view.selectedWindows.isEmpty)
        #expect(recorder.heard == ["window"])
    }

    @Test func recallLastAreaAndMidDragReset() throws {
        // L in area mode recalls the last captured area for screenshot, annotate, record, and scroll.
        for purpose in [OverlayController.Purpose.screenshot, .annotate, .record, .scroll] {
            #expect(try press(37, characters: "l", in: purpose).heard == ["lastArea"], "\(purpose)")
        }
        for purpose in [OverlayController.Purpose.text, .color, .measure] {
            #expect(try press(37, characters: "l", in: purpose).heard.isEmpty, "\(purpose)")
        }

        // During a selection drag, Backspace or right-click resets the drag instead of cancelling the overlay.
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        view.delegate = recorder
        view.reset(pointer: CGPoint(x: 200, y: 200), mode: .area, windows: [], showsToolbar: false, purpose: .screenshot)
        var selection = SelectionModel(bounds: Self.display.frame, pixelsPerPoint: 2)
        selection.begin(at: CGPoint(x: 100, y: 200))
        selection.drag(to: CGPoint(x: 200, y: 100))
        view.show(selection: selection, showsReading: true, isDragging: true)

        let backspace = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{8}", charactersIgnoringModifiers: "\u{8}", isARepeat: false, keyCode: 51
        ))
        view.keyDown(with: backspace)
        #expect(recorder.heard == ["resetDrag"])

        let rightClick = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: CGPoint(x: 150, y: 150), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        view.rightMouseDown(with: rightClick)
        #expect(recorder.heard == ["resetDrag", "resetDrag"])

        // Once not dragging, right-click cancels the overlay session.
        view.show(selection: SelectionModel(bounds: Self.display.frame, pixelsPerPoint: 2), showsReading: false, isDragging: false)
        view.rightMouseDown(with: rightClick)
        #expect(recorder.heard.last == "cancel")
    }

    private func key(_ keyCode: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
    }

    /// ? shows the purpose's keys a sentence a line, as its VoiceOver help says them; Escape puts them away and does
    /// nothing more, any other key puts them away and does what it does, and ? again puts them away.
    @Test func questionMarkShowsThePurposesKeysUntilAnotherKey() throws {
        for purpose: OverlayController.Purpose in [.screenshot, .annotate, .text, .color, .measure, .record, .scroll] {
            let view = OverlayView(display: Self.display)
            let recorder = Recorder()
            view.delegate = recorder
            view.reset(pointer: CGPoint(x: 400, y: 300), mode: .area, windows: [], showsToolbar: false, purpose: purpose)
            view.keyDown(with: try key(44, "?", modifiers: .shift))
            #expect(view.showsKeys, "\(purpose)")
            #expect(view.debugKeys == Sentences.split(view.keyHelp).joined(separator: "\n"), "\(purpose)")
            #expect(view.debugKeys.split(separator: "\n").count > 1, "\(purpose)")
            view.keyDown(with: try key(53, "\u{1b}"))
            #expect(!view.showsKeys && recorder.heard.isEmpty, "\(purpose)")
            view.keyDown(with: try key(44, "?", modifiers: .shift))
            view.keyDown(with: try key(44, "?", modifiers: .shift))
            #expect(!view.showsKeys && recorder.heard.isEmpty, "\(purpose)")
        }
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        view.delegate = recorder
        view.reset(pointer: CGPoint(x: 400, y: 300), mode: .area, windows: [], showsToolbar: false, purpose: .screenshot)
        view.keyDown(with: try key(44, "?", modifiers: .shift))
        view.keyDown(with: try key(49, " "))
        #expect(!view.showsKeys)
        #expect(recorder.heard == ["space"])
        // A new session starts without them.
        view.keyDown(with: try key(44, "?", modifiers: .shift))
        view.reset(pointer: CGPoint(x: 400, y: 300), mode: .area, windows: [], showsToolbar: false, purpose: .screenshot)
        #expect(!view.showsKeys)
    }

    /// The keys sit centered across the display, 40 pt from the edge the pointer is further from, over the bar when it
    /// shows, and inside the display.
    /// Choosing a window has keys of its own, and Space takes the help each way with it.
    @Test func choosingAWindowShowsItsOwnKeys() throws {
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        view.delegate = recorder
        view.reset(pointer: CGPoint(x: 400, y: 300), mode: .area, windows: [], showsToolbar: false, purpose: .screenshot)
        let area = view.keyHelp
        #expect(area.contains("Tab to type a size"))
        view.switchMode(to: .window, windows: [])
        #expect(view.keyHelp.hasPrefix("Click a window to choose it"))
        view.keyDown(with: try key(44, "?", modifiers: .shift))
        #expect(view.debugKeys == Sentences.split(view.keyHelp).joined(separator: "\n"))
        view.switchMode(to: .area, windows: [])
        #expect(view.keyHelp == area)
        // Capture Window starts on windows.
        view.reset(pointer: CGPoint(x: 400, y: 300), mode: .window, windows: [], showsToolbar: false, purpose: .screenshot)
        #expect(view.keyHelp.hasPrefix("Click a window to choose it"))
    }

    /// A ⌘ key goes to the overlay's key equivalents before its keys: it puts the keys away all the same.
    @Test func aCommandKeyPutsTheKeysAway() throws {
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        view.delegate = recorder
        view.reset(pointer: CGPoint(x: 400, y: 300), mode: .area, windows: [], showsToolbar: false, purpose: .measure)
        view.keyDown(with: try key(44, "?", modifiers: .shift))
        #expect(view.showsKeys)
        _ = view.performKeyEquivalent(with: try key(8, "c", modifiers: .command))
        #expect(!view.showsKeys)
    }

    /// In-place annotation takes the display over with its own keys: the selection's go.
    @Test func annotationTakingOverPutsTheKeysAway() throws {
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        view.delegate = recorder
        view.reset(pointer: CGPoint(x: 400, y: 300), mode: .area, windows: [], showsToolbar: false, purpose: .annotate)
        view.keyDown(with: try key(44, "?", modifiers: .shift))
        #expect(view.showsKeys)
        view.enterAnnotation()
        #expect(!view.showsKeys)
    }

    @Test func theKeysSitByTheEdgeAwayFromThePointer() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = CGSize(width: 300, height: 120)
        // y up: a pointer in the upper half sends them to the bottom, one in the lower half to the top.
        #expect(OverlayView.keysFrame(size: size, pointer: CGPoint(x: 100, y: 500), in: bounds, avoiding: nil) == CGRect(x: 250, y: 40, width: 300, height: 120))
        #expect(OverlayView.keysFrame(size: size, pointer: CGPoint(x: 100, y: 100), in: bounds, avoiding: nil) == CGRect(x: 250, y: 440, width: 300, height: 120))
        #expect(OverlayView.keysFrame(size: size, pointer: nil, in: bounds, avoiding: CGRect(x: 200, y: 40, width: 400, height: 42)).minY == 94)
        let high = OverlayView.keysFrame(size: size, pointer: nil, in: bounds, avoiding: CGRect(x: 0, y: 500, width: 10, height: 80))
        #expect(high.maxY == 594)
    }

    @Test func returnDoesNotSubmitRetainedAllInOneWindowsWhileDraggingAnArea() throws {
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        let passedOn = PassedOn()
        view.delegate = recorder
        view.nextResponder = passedOn
        view.reset(pointer: CGPoint(x: 400, y: 300), mode: .area, windows: [], showsToolbar: false, purpose: .screenshot, allInOne: true)
        let first = WindowTarget(id: 10, frame: CGRect(x: 80, y: 80, width: 200, height: 150), ownerName: "Notes", title: nil)
        let second = WindowTarget(id: 20, frame: CGRect(x: 320, y: 120, width: 220, height: 160), ownerName: "Safari", title: nil)
        view.setSelectedWindows([first, second])

        var selection = SelectionModel(bounds: Self.display.frame, pixelsPerPoint: Self.display.pixelsPerPoint)
        selection.begin(at: CGPoint(x: 100, y: 100))
        selection.drag(to: CGPoint(x: 260, y: 220))
        view.show(selection: selection, showsReading: true, isDragging: true)
        view.keyDown(with: try key(36, "\r"))
        #expect(recorder.heard.isEmpty && passedOn.keys == [36])

        view.show(selection: SelectionModel(bounds: Self.display.frame, pixelsPerPoint: Self.display.pixelsPerPoint), showsReading: false, isDragging: false)
        view.keyDown(with: try key(36, "\r"))
        #expect(recorder.heard == ["windows [10, 20]"])
    }

    @Test func rightClickAndEscapeInMeasureModeCancelActiveBoxDragWithoutCancellingOverlay() throws {
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        view.delegate = recorder
        view.reset(pointer: CGPoint(x: 200, y: 200), mode: .area, windows: [], showsToolbar: false, purpose: .measure)

        let mouseDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let mouseDrag = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 260, y: 220), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let rightClick = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: CGPoint(x: 260, y: 220), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        view.mouseDown(with: mouseDown)
        view.mouseDragged(with: mouseDrag)
        #expect(view.isDraggingMeasureBox)
        recorder.heard.removeAll()

        // Right-click during a box drag cancels only the box, keeping the Measure overlay active.
        view.rightMouseDown(with: rightClick)
        #expect(!view.isDraggingMeasureBox)
        #expect(recorder.heard.isEmpty)

        // Escape during a box drag also cancels only the box, keeping the Measure overlay active.
        view.mouseDown(with: mouseDown)
        view.mouseDragged(with: mouseDrag)
        #expect(view.isDraggingMeasureBox)
        recorder.heard.removeAll()
        view.keyDown(with: try key(53, "\u{1b}"))
        #expect(!view.isDraggingMeasureBox)
        #expect(recorder.heard.isEmpty)

        // Right-click when no box drag is active cancels the overlay.
        view.rightMouseDown(with: rightClick)
        #expect(recorder.heard == ["cancel"])
    }

    #if DEBUG
    @Test func shortcutHintCapsuleShowsForColorAndWindowAndStaysClampedClearOfToolbar() throws {
        let view = OverlayView(display: Self.display)
        view.reset(pointer: CGPoint(x: 400, y: 300), mode: .area, windows: [], showsToolbar: false, purpose: .color)
        #expect(view.debugHintText == "⌥ Click for details · Tab Format")
        let colorHint = try #require(view.debugHintFrame)
        #expect(view.bounds.insetBy(dx: 5, dy: 5).contains(colorHint))

        view.reset(pointer: CGPoint(x: 400, y: 300), mode: .window, windows: [], showsToolbar: true, purpose: .screenshot)
        view.layoutSubtreeIfNeeded()
        #expect(view.debugHintText == "Scroll Element · Tab Cycle · ⇧ Click Multi-select")
        let windowHint = try #require(view.debugHintFrame)
        #expect(view.bounds.insetBy(dx: 5, dy: 5).contains(windowHint))
        #expect(!windowHint.intersects(view.debugToolbarFrame))

        // Area screenshot mode shows no bottom hint capsule.
        view.reset(pointer: CGPoint(x: 400, y: 300), mode: .area, windows: [], showsToolbar: true, purpose: .screenshot)
        #expect(view.debugHintText == nil)
    }
    #endif

    @Test func optionClickAndOptionReturnForwardOptionWithoutConflictingWithShiftMultiSelect() throws {
        let front = WindowTarget(id: 10, frame: CGRect(x: 100, y: 100, width: 400, height: 300), ownerName: "AppA", title: "Front")
        let back = WindowTarget(id: 20, frame: CGRect(x: 150, y: 120, width: 400, height: 300), ownerName: "AppB", title: "Back")
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        view.delegate = recorder
        view.reset(pointer: CGPoint(x: 200, y: 200), mode: .window, windows: [front, back], showsToolbar: false, purpose: .screenshot)

        // Option-click on a hovered window selects it immediately and forwards .option.
        let optionClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 200, y: 200), modifierFlags: .option, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        view.mouseUp(with: optionClick)
        #expect(recorder.heard == ["window"])
        #expect(recorder.lastWindowModifiers?.contains(.option) == true)

        // Option-Return on a single hovered window also preserves .option.
        recorder.heard = []
        recorder.lastWindowModifiers = nil
        let optionReturn = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        view.keyDown(with: optionReturn)
        #expect(recorder.heard == ["window"])
        #expect(recorder.lastWindowModifiers?.contains(.option) == true)

        // Shift-click still toggles multi-window selection, and Option-Return preserves .option for the combined capture.
        recorder.heard = []
        recorder.lastWindowModifiers = nil
        let shiftClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: 200, y: 200), modifierFlags: .shift, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        view.mouseUp(with: shiftClick)
        #expect(view.selectedWindows == [front] && recorder.heard.isEmpty)

        view.cycleWindow()
        #expect(view.hoveredWindow == back)
        view.mouseUp(with: shiftClick)
        #expect(view.selectedWindows == [front, back] && recorder.heard.isEmpty)

        view.keyDown(with: optionReturn)
        #expect(recorder.heard == ["windows [10, 20]"])
        #expect(recorder.lastWindowModifiers?.contains(.option) == true)
    }
}
