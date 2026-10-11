import AppKit
import Foundation
import OMSCore
import Testing
@testable import OMSStudio

@MainActor
struct StudioEditingTests {
    private static func key(_ time: Double, _ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) -> StudioTelemetry.Key {
        .init(time: time, keyCode: keyCode, modifiers: modifiers.rawValue, characters: characters, keyCharacters: characters, isRepeat: false)
    }

    @Test func shortcutsOnlyShowsNoTyping() {
        let keys = [Self.key(1, "h", keyCode: 4), Self.key(1.1, "i", keyCode: 34), Self.key(1.3, "s", keyCode: 1, modifiers: .command)]
        #expect(StudioRenderer.captions(for: keys, mode: .shortcuts).map(\.text) == ["⌘S"])
        #expect(StudioRenderer.captions(for: keys, mode: .all).map(\.text) == ["h", "hi", "⌘S"])
    }

    @Test func typingKeptOnlyAsPressesShowsNothingButStillZooms() {
        let presses = (0..<6).map { StudioTelemetry.Key.unrecorded(time: 3 + Double($0) * 0.2, isRepeat: false) }
        #expect(StudioRenderer.captions(for: presses, mode: .all).isEmpty)
        let telemetry = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 2, samples: [.init(time: 0, x: 800, y: 500, cursor: 0)], keys: presses,
            keystrokeMode: .shortcuts
        )
        #expect(AutoZoom.zooms(for: telemetry, duration: 8).count == 1)
    }

    @Test func aProjectSavedBeforeASettingTakesItsDefault() throws {
        // A project as the first version saved it: no keystroke mode, no automatic-zoom setting.
        let old = #"{"background":{"gradient":{"_0":"sky"}},"padding":0.1,"cornerRadius":12,"shadow":0.6,"aspect":"auto","cursor":{"size":1.5,"smoothing":0.5,"hidesWhenIdle":true,"showsClicks":true},"zooms":[],"cuts":[],"showsKeys":true}"#
        let project = try JSONDecoder().decode(StudioProject.self, from: Data(old.utf8))
        #expect(project.padding == 0.1 && project.shadow == 0.6)
        #expect(project.keystrokeMode == .all && project.automaticZooms)
        var changed = project
        changed.keystrokeMode = .shortcuts
        changed.automaticZooms = false
        #expect(try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(changed)) == changed)
    }

    @Test func theCursorPressesWhereThePointerDid() {
        // A pointer sweeping right at 600 pt/s, smoothed as much as it goes, clicking at 2 s.
        let samples = stride(from: 0.0, through: 4, by: 1.0 / 60).map { StudioTelemetry.Sample(time: $0, x: 100 + 600 * $0, y: 400, cursor: 0) }
        let telemetry = StudioTelemetry(width: 3000, height: 1000, pixelsPerPoint: 2, samples: samples, clicks: [.init(time: 2, x: 1300, y: 400, button: .primary)])
        var project = StudioProject()
        project.cursor.smoothing = 1
        let track = StudioTrack(telemetry: telemetry, project: project, duration: 4)
        // Well before the click it trails the pointer; at the click it is on it, and on it just after.
        #expect(1300 - 600 * 0.5 - track.frame(at: 1.5).cursorX > 20)
        #expect(abs(track.frame(at: 2).cursorX - 1300) < 2)
        #expect(abs(track.frame(at: 2.01).cursorX - (100 + 600 * 2.01)) < 4)
    }

    private func document() throws -> StudioDocument {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-\(UUID().uuidString)")
        let telemetry = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)])
        return StudioDocument(
            source: folder.appending(path: "none.mp4"), telemetry: telemetry, project: StudioProject(), duration: 4,
            recordingSize: CGSize(width: 320, height: 200), folder: folder, hasBeenExported: false, background: { _, _ in nil }
        )
    }

    @Test func everyChangeCanBeTakenBackAndADragAsOne() throws {
        let document = try document()
        defer { try? FileManager.default.removeItem(at: document.folder) }
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManagerProvider = { undo }

        undo.beginUndoGrouping()
        document.addZoom()
        undo.endUndoGrouping()
        #expect(document.project.zooms.count == 1)
        #expect(undo.undoActionName == "Add Zoom")

        // A slider dragged through three values is one change.
        undo.beginUndoGrouping()
        document.beginContinuousChange()
        for shadow in [0.2, 0.3, 0.4] { document.project.shadow = shadow }
        document.endContinuousChange()
        undo.endUndoGrouping()

        undo.undo()
        #expect(document.project.shadow == StudioProject().shadow)
        #expect(document.project.zooms.count == 1)
        undo.undo()
        #expect(document.project.zooms.isEmpty)
        undo.redo()
        #expect(document.project.zooms.count == 1)
    }

    @Test func automaticZoomsAreASettingThatHoldsWithNothingToFollow() throws {
        let document = try document()
        defer { try? FileManager.default.removeItem(at: document.folder) }
        // Nothing was clicked: the setting stays on, and places nothing.
        document.setAutomaticZooms(true)
        #expect(document.project.automaticZooms && document.project.zooms.isEmpty && document.automaticZooms.isEmpty)
        document.setAutomaticZooms(false)
        #expect(!document.project.automaticZooms)
    }
}
