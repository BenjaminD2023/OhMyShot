import AppKit
import OMSCore
import Testing
@testable import OMSUI

/// Where the windows shown with a recording lie against the dim over the rest of the screen: none of them
/// may be dimmed. Panels are made, never shown.
struct RecordingWindowLevelTests {
    @Test func theDimLiesUnderTheControlBarTheKeystrokesAndTheClickRings() {
        let windows: [(name: String, level: NSWindow.Level)] = [
            ("control bar", ControlBarPanel(frame: .zero).level),
            ("keystrokes", KeystrokeDisplay(mode: .all).makePanel().level),
            ("click rings", ClickHighlights().makePanel().level),
        ]
        for window in windows {
            #expect(RecordingWindowLevel.dim < window.level, "\(window.name)")
        }
    }
}
