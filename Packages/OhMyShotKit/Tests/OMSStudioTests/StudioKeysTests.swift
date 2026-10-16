import AppKit
import Foundation
import OMSCore
import Testing
@testable import OMSStudio

/// Which keys a Studio recording writes down, and that none typed while the system keeps keystrokes private are.
struct StudioKeysTests {
    private static func press(_ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) -> Keystroke {
        Keystroke(keyCode: keyCode, modifiers: modifiers, characters: characters, keyCharacters: characters)
    }

    @Test func keysAreWrittenDownWhenTheBarShowedThemOrSettingsKeepsThem() {
        func mode(shows: Bool, keeps: Bool, allowed: Bool, window: Bool = false, mode: KeystrokeMode = .all) -> KeystrokeMode? {
            TelemetryRecorder.keystrokeMode(
                showsKeystrokes: shows, keepsForStudio: keeps, recordsWindow: window, inputMonitoringAllowed: allowed, mode: mode
            )
        }
        // Keystrokes off on the bar, kept for Studio: written down, in Settings' mode.
        #expect(mode(shows: false, keeps: true, allowed: true) == .all)
        #expect(mode(shows: false, keeps: true, allowed: true, mode: .shortcuts) == .shortcuts)
        // On the bar: written down whether or not Settings keeps keys for Studio.
        #expect(mode(shows: true, keeps: false, allowed: true) == .all)
        // Neither: none.
        #expect(mode(shows: false, keeps: false, allowed: true) == nil)
        // Without Input Monitoring there are none to write, whichever asked.
        #expect(mode(shows: true, keeps: true, allowed: false) == nil)
        #expect(mode(shows: false, keeps: true, allowed: false) == nil)
    }

    @Test func aWindowRecordedOnItsOwnKeepsKeysOnlyWhenTheBarShowedThem() {
        func mode(shows: Bool, keeps: Bool, window: Bool) -> KeystrokeMode? {
            TelemetryRecorder.keystrokeMode(
                showsKeystrokes: shows, keepsForStudio: keeps, recordsWindow: window, inputMonitoringAllowed: true, mode: .all
            )
        }
        // What is typed in other apps is no part of a window: Settings alone keeps none of it.
        #expect(mode(shows: false, keeps: true, window: true) == nil)
        #expect(mode(shows: false, keeps: false, window: true) == nil)
        // Chosen on the bar for a window, as Studio lets it be, they are kept as before.
        #expect(mode(shows: true, keeps: true, window: true) == .all)
        #expect(mode(shows: true, keeps: false, window: true) == .all)
        // An area or a display is as it was.
        #expect(mode(shows: false, keeps: true, window: false) == .all)
    }

    /// Off until turned on: what is typed is kept only when asked for.
    @Test func keepingKeysForStudioIsOffUntilTurnedOnAndIsRemembered() throws {
        let suite = "OMSStudioTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(!settings.recordingKeepsKeysForStudio)
        settings.recordingKeepsKeysForStudio = true
        #expect(SettingsStore(defaults: defaults).recordingKeepsKeysForStudio)
        settings.recordingKeepsKeysForStudio = false
        #expect(!SettingsStore(defaults: defaults).recordingKeepsKeysForStudio)
    }

    @Test func keysTypedWhileTheSystemKeepsThemPrivateAreNeverWrittenDown() {
        let recorder = TelemetryRecorder()
        recorder.keyMode = .all
        var secure = false
        recorder.isSecureInputOn = { secure }
        recorder.press(Self.press("a", keyCode: 0), at: 1)
        // A password field has focus: neither the key nor a shortcut is kept, nor a press that would only zoom.
        secure = true
        recorder.press(Self.press("p", keyCode: 35), at: 2)
        recorder.press(Self.press("s", keyCode: 1, modifiers: .command), at: 2.1)
        secure = false
        recorder.press(Self.press("b", keyCode: 11), at: 3)
        let keys = recorder.stop().keys
        #expect(keys.map(\.characters) == ["a", "b"])
        #expect(keys.map(\.time) == [1, 3])
    }

    @Test func underShortcutsOnlyTypingIsOnlyAPress() {
        let recorder = TelemetryRecorder()
        recorder.keyMode = .shortcuts
        recorder.isSecureInputOn = { false }
        recorder.press(Self.press("h", keyCode: 4), at: 1)
        recorder.press(Self.press("s", keyCode: 1, modifiers: .command), at: 2)
        let keys = recorder.stop().keys
        #expect(keys.count == 2)
        // The typed key keeps its time and nothing else.
        #expect(keys[0].keyCode == StudioTelemetry.Key.unrecordedKeyCode && keys[0].characters.isEmpty && keys[0].time == 1)
        #expect(keys[1].characters == "s" && keys[1].keyCode == 1)
    }

    @Test func aStudioRecordingKeepsItsKeysForTheStudioToShowLater() {
        // Keys written down while the bar showed none: the project shows none to begin with, and the keys are there.
        let keys = [
            StudioTelemetry.Key(time: 1, keyCode: 1, modifiers: NSEvent.ModifierFlags.command.rawValue, characters: "s", keyCharacters: "s", isRepeat: false),
            StudioTelemetry.Key(time: 2, keyCode: 4, modifiers: 0, characters: "h", keyCharacters: "h", isRepeat: false),
        ]
        var project = StudioProject()
        project.showsKeys = false
        #expect(StudioRenderer.captions(for: keys, mode: .all).map(\.text) == ["⌘S", "h"])
        #expect(StudioRenderer.captions(for: keys, mode: .shortcuts).map(\.text) == ["⌘S"])
        // Turned on in Studio afterwards, they show; the renderer draws none while it is off.
        let telemetry = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2, keys: keys, keystrokeMode: .all)
        let size = CGSize(width: 320, height: 200)
        func captions(_ project: StudioProject) -> Int {
            // The renderer holds the captions it draws: none while keys are not shown.
            let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 4, recordingSize: size, background: nil)
            return renderer.captions.count
        }
        #expect(captions(project) == 0)
        project.showsKeys = true
        #expect(captions(project) == 2)
        project.keystrokeMode = .shortcuts
        #expect(captions(project) == 1)
    }

    @Test func typingNowPlacesZoomsAndHidesTheCursorEvenWithKeysNotShown() {
        // Keys written down with the bar's keystrokes off still count for the zooms and the cursor.
        let presses = (0..<6).map {
            StudioTelemetry.Key(time: 3 + Double($0) * 0.2, keyCode: 4, modifiers: 0, characters: "h", keyCharacters: "h", isRepeat: false)
        }
        let telemetry = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 2, samples: [.init(time: 0, x: 800, y: 500, cursor: 0)], keys: presses, keystrokeMode: .all
        )
        #expect(AutoZoom.zooms(for: telemetry, duration: 8).count == 1)
    }
}
