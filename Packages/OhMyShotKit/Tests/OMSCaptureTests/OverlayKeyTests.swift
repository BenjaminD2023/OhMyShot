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

        func overlayView(_ view: OverlayView, didPressAt point: CGPoint) { heard.append("press") }
        func overlayView(_ view: OverlayView, didDragTo point: CGPoint, modifiers: NSEvent.ModifierFlags) { heard.append("drag") }
        func overlayView(_ view: OverlayView, didReleaseWith modifiers: NSEvent.ModifierFlags) { heard.append("release") }
        func overlayView(_ view: OverlayView, didChangeModifiers modifiers: NSEvent.ModifierFlags) { heard.append("modifiers") }
        func overlayView(_ view: OverlayView, didMovePointerTo point: CGPoint) { heard.append("move") }
        func overlayView(_ view: OverlayView, didPressSpace isRepeat: Bool) { heard.append("space") }
        func overlayViewDidReleaseSpace(_ view: OverlayView) { heard.append("space up") }
        func overlayView(_ view: OverlayView, didSelect rect: CGRect, modifiers: NSEvent.ModifierFlags) { heard.append("select") }
        func overlayView(_ view: OverlayView, didSelectWindow target: WindowTarget, modifiers: NSEvent.ModifierFlags) { heard.append("window") }
        func overlayView(_ view: OverlayView, didSwitchTo mode: OverlayView.Mode) { heard.append("switch") }
        func overlayViewDidCancel(_ view: OverlayView) { heard.append("cancel") }
        func overlayView(_ view: OverlayView, didPickColorAt point: CGPoint, modifiers: NSEvent.ModifierFlags, keyboard: Bool) { heard.append("pick") }
        func overlayView(_ view: OverlayView, didNudge pixels: CGVector) {
            heard.append("nudge")
            nudge = pixels
        }
        func overlayViewDidRequestSizing(_ view: OverlayView) { heard.append("size") }
        func overlayView(_ view: OverlayView, didCopyMeasurement text: String, ending: Bool) { heard.append("copy") }
        func overlayView(_ view: OverlayView, didChangeUnit unit: MeasureUnit) { heard.append("unit") }
        func overlayView(_ view: OverlayView, didChooseMode choice: AllInOneChoice) { heard.append("mode \(choice)") }
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
    /// area is framed after its drag; Measure's Tab is its unit).
    @Test func tabOpensTheSizeControlWhereAnAreaIsChosen() throws {
        for purpose in [OverlayController.Purpose.screenshot, .annotate] {
            let result = try press(48, characters: "\t", in: purpose)
            #expect(result.heard == ["size"] && !result.passedOn, "\(purpose): \(result.heard)")
        }
        for purpose in [OverlayController.Purpose.text, .record, .scroll, .color] {
            let result = try press(48, characters: "\t", in: purpose)
            #expect(result.heard.isEmpty && result.passedOn, "\(purpose): \(result.heard)")
        }
        let allInOne = try press(48, characters: "\t", in: .screenshot, allInOne: true)
        #expect(allInOne.heard.isEmpty && allInOne.passedOn)
        let window = try press(48, characters: "\t", in: .screenshot, mode: .window)
        #expect(window.heard.isEmpty && window.passedOn)
    }

    /// All-In-One's letters choose a mode before an area: O text, S scrolling, R recording; W a window, F the screen.
    @Test func allInOneLettersChooseWhatTheNextAreaIsFor() throws {
        let cases: [(UInt16, String, [String])] = [
            (31, "o", ["mode text"]), (1, "s", ["mode scroll"]), (15, "r", ["mode record"]),
            (13, "w", ["switch"]), (3, "f", ["select"]),
            // A: a plain capture of an area, letting go of what the next area was for.
            (0, "a", ["mode screenshot(nil)"]),
        ]
        for (code, letter, heard) in cases {
            let result = try press(code, characters: letter, in: .screenshot, allInOne: true)
            #expect(result.heard == heard && !result.passedOn, "\(letter): \(result.heard)")
        }
    }

    /// Capture Area's overlay has none of them: the letters are passed on.
    @Test func captureAreaPassesTheLettersOn() throws {
        for (code, letter) in [(UInt16(31), "o"), (1, "s"), (15, "r"), (13, "w"), (3, "f")] {
            let result = try press(code, characters: letter, in: .screenshot)
            #expect(result.heard.isEmpty && result.passedOn, "\(letter): \(result.heard)")
        }
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
}
