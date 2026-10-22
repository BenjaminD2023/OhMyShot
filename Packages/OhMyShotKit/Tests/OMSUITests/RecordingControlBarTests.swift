import AppKit
import Testing
@testable import OMSUI

/// The control bar while recording is paused: the dot gives way to a pause symbol, the time pulses, and Resume is lit.
@MainActor
struct RecordingControlBarTests {
    private func bar() -> ControlBarView {
        ControlBarView(actions: RecordingControlBar.Actions(pause: {}, resume: {}, restart: {}, delete: {}, stop: {}))
    }

    @Test func recordingLooksAsItDid() {
        let view = bar()
        view.update(elapsed: .seconds(42), paused: false)
        #expect(view.debugPausedLook == (false, false, false))
    }

    @Test func pausedLightsResumeAndPulsesTheTime() {
        let view = bar()
        view.update(elapsed: .seconds(42), paused: true)
        let look = view.debugPausedLook
        #expect(look.resumeLit)
        #expect(look.markShown)
        // Never under Reduce Motion.
        #expect(look.pulses == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        view.update(elapsed: .seconds(43), paused: false)
        #expect(view.debugPausedLook == (false, false, false))
    }

    /// Delete's question stands still in the time's place, and the pulse comes back when the question goes.
    @Test func aQuestionStopsThePulse() {
        let view = bar()
        view.update(elapsed: .seconds(42), paused: true)
        view.debugPressDelete()
        #expect(!view.debugPausedLook.pulses)
        #expect(view.debugPausedLook.resumeLit)
    }
}
