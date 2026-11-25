import AppKit
import OMSCore
import Testing
@testable import OMSCapture

#if DEBUG
/// Window mode's wheel goes into the parts of the hovered window and back out; their reading names them.
@MainActor
struct WindowPartsTests {
    private let display = DisplayInfo(
        id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 1600, height: 1200),
        backingScale: 2, maximumPotentialEDR: 1
    )
    private let window = WindowTarget(id: 7, frame: CGRect(x: 100, y: 100, width: 500, height: 400), ownerName: "Notes", title: nil, pid: 42)
    // Global points, y up: a sidebar, and a button in it, under the pointer at (180, 300).
    private let chain = [
        WindowElement(frame: CGRect(x: 150, y: 280, width: 80, height: 30), name: "button"),
        WindowElement(frame: CGRect(x: 100, y: 100, width: 160, height: 400), name: "group"),
    ]

    private func notch(_ lines: Int32) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: event))
    }

    /// The wheel value that goes in: toward you, as the device moves.
    private func inward() throws -> Int32 {
        let probe = try notch(1)
        let travel = probe.isDirectionInvertedFromDevice ? -probe.scrollingDeltaY : probe.scrollingDeltaY
        return travel > 0 ? -1 : 1
    }

    private func view(allowed: Bool) -> OverlayView {
        let view = OverlayView(display: display)
        view.canReadElements = { allowed }
        let chain = self.chain
        view.readElements = { _, _, _, _ in chain }
        view.displayLayout = DisplayLayout(displays: [display])
        view.reset(pointer: CGPoint(x: 180, y: 300), mode: .window, windows: [window], showsToolbar: false)
        return view
    }

    @Test func theWheelGoesIntoThePartsOfTheWindowAndBackOut() async throws {
        let view = view(allowed: true)
        defer { view.clear() }
        #expect(view.hoveredWindow == window && view.pickedElement == nil)
        let into = try inward()
        view.scrollWheel(with: try notch(into))
        for _ in 0..<100 where view.pickedElement == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        // In one step: the largest part first.
        #expect(view.pickedElement == chain[1])
        #expect(view.debugSizeReading == "group  ·  320 × 800")
        view.scrollWheel(with: try notch(into))
        #expect(view.pickedElement == chain[0])
        // No further in than the smallest part.
        view.scrollWheel(with: try notch(into))
        #expect(view.pickedElement == chain[0])
        view.scrollWheel(with: try notch(-into))
        view.scrollWheel(with: try notch(-into))
        #expect(view.pickedElement == nil)
        #expect(view.debugSizeReading.hasPrefix("Notes"))
    }

    @Test func withoutAccessibilityTheReadingSaysHowToAllowIt() throws {
        let view = view(allowed: false)
        defer { view.clear() }
        view.scrollWheel(with: try notch(try inward()))
        #expect(view.pickedElement == nil)
        #expect(view.debugSizeReading.contains("Accessibility"))
    }

    @Test func pressingReturnWithAPickedElementSelectsThatElementInsteadOfTheWholeWindow() async throws {
        final class ElementDelegate: OverlayViewDelegate {
            var selectedElements: [CGRect] = []
            var selectedWindows: [WindowTarget] = []
            func overlayView(_ view: OverlayView, didPressAt point: CGPoint) {}
            func overlayView(_ view: OverlayView, didDragTo point: CGPoint, modifiers: NSEvent.ModifierFlags) {}
            func overlayView(_ view: OverlayView, didReleaseWith modifiers: NSEvent.ModifierFlags) {}
            func overlayView(_ view: OverlayView, didChangeModifiers modifiers: NSEvent.ModifierFlags) {}
            func overlayView(_ view: OverlayView, didMovePointerTo point: CGPoint) {}
            func overlayView(_ view: OverlayView, didPressSpace isRepeat: Bool) {}
            func overlayViewDidReleaseSpace(_ view: OverlayView) {}
            func overlayView(_ view: OverlayView, didSelect rect: CGRect, modifiers: NSEvent.ModifierFlags) {}
            func overlayView(_ view: OverlayView, didSelectElement rect: CGRect, modifiers: NSEvent.ModifierFlags) {
                selectedElements.append(rect)
            }
            func overlayView(_ view: OverlayView, didSelectWindow target: WindowTarget, modifiers: NSEvent.ModifierFlags) {
                selectedWindows.append(target)
            }
            func overlayView(_ view: OverlayView, didSwitchTo mode: OverlayView.Mode) {}
            func overlayViewDidCancel(_ view: OverlayView) {}
            func overlayView(_ view: OverlayView, didPickColorAt point: CGPoint, modifiers: NSEvent.ModifierFlags, keyboard: Bool) {}
            func overlayView(_ view: OverlayView, didNudge pixels: CGVector) {}
            func overlayViewDidRequestSizing(_ view: OverlayView) {}
            func overlayView(_ view: OverlayView, didCopyMeasurement text: String, ending: Bool) {}
            func overlayView(_ view: OverlayView, didCaptureMeasurement measurement: RulerMeasurement, of frame: CapturedFrame) {}
            func overlayView(_ view: OverlayView, didChangeUnit unit: MeasureUnit) {}
            func overlayView(_ view: OverlayView, didChangeTolerance tolerance: MeasureTolerance) {}
            func overlayView(_ view: OverlayView, didChooseMode choice: AllInOneChoice) {}
            func overlayViewDidRequestMeasure(_ view: OverlayView) {}
        }

        let view = view(allowed: true)
        defer { view.clear() }
        let delegate = ElementDelegate()
        view.delegate = delegate
        view.scrollWheel(with: try notch(try inward()))
        for _ in 0..<100 where view.pickedElement == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(view.pickedElement == chain[1])
        let pressReturn = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        view.keyDown(with: pressReturn)
        #expect(delegate.selectedElements == [chain[1].frame])
        #expect(delegate.selectedWindows.isEmpty)
    }
}
#endif
