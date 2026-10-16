import AppKit
import OMSCore
import Testing
@testable import OMSCapture

/// The overlay's keys by purpose: the arrows and Return belong to Pick Color and Measure only.
@MainActor
struct OverlayKeyTests {
    /// What the overlay told its controller, by name.
    private final class Recorder: OverlayViewDelegate {
        var heard: [String] = []

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
        func overlayView(_ view: OverlayView, didNudge pixels: CGVector) { heard.append("nudge") }
        func overlayView(_ view: OverlayView, didCopyMeasurement text: String, ending: Bool) { heard.append("copy") }
        func overlayView(_ view: OverlayView, didChangeUnit unit: MeasureUnit) { heard.append("unit") }
        /// Whether an area shows chosen, which Return takes.
        var hasChosenArea = false
        func overlayViewDidPressReturn(_ view: OverlayView, modifiers: NSEvent.ModifierFlags) -> Bool {
            heard.append("return")
            return hasChosenArea
        }
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
    private func press(_ keyCode: UInt16, in purpose: OverlayController.Purpose, areaChosen: Bool = false) throws -> (heard: [String], passedOn: Bool) {
        let view = OverlayView(display: Self.display)
        let recorder = Recorder()
        recorder.hasChosenArea = areaChosen
        let passedOn = PassedOn()
        view.delegate = recorder
        view.nextResponder = passedOn
        view.reset(pointer: CGPoint(x: 400, y: 300), mode: .area, windows: [], showsToolbar: false, purpose: purpose)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
        ))
        view.keyDown(with: event)
        return (recorder.heard, !passedOn.keys.isEmpty)
    }

    private static let arrows: [UInt16] = [123, 124, 125, 126]
    private static let returns: [UInt16] = [36, 76]

    @Test func whileCapturingTheArrowsAndReturnArePassedOn() throws {
        for purpose in [OverlayController.Purpose.screenshot, .text, .annotate, .record, .scroll] {
            for key in Self.arrows {
                let result = try press(key, in: purpose)
                #expect(result.heard.isEmpty && result.passedOn, "key \(key) in \(purpose): \(result.heard)")
            }
        }
        for purpose in [OverlayController.Purpose.annotate, .record, .scroll] {
            for key in Self.returns {
                let result = try press(key, in: purpose)
                #expect(result.heard.isEmpty && result.passedOn, "key \(key) in \(purpose): \(result.heard)")
            }
        }
    }

    /// Return takes an area the URL API chose ahead; with none it is passed on.
    @Test func whileCapturingReturnTakesAnAreaChosenAhead() throws {
        for purpose in [OverlayController.Purpose.screenshot, .text] {
            for key in Self.returns {
                let none = try press(key, in: purpose)
                #expect(none.heard == ["return"] && none.passedOn, "key \(key) in \(purpose): \(none.heard)")
                let chosen = try press(key, in: purpose, areaChosen: true)
                #expect(chosen.heard == ["return"] && !chosen.passedOn, "key \(key) in \(purpose): \(chosen.heard)")
            }
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
