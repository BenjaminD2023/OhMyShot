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
        #expect(project.cursor.hidesWhileTyping && project.cursor.size == 1.5)
        #expect(project.camera == StudioProject.Camera())
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

    @Test func typingHidesTheCursorUntilThePointerMoves() {
        // Still until 2 s, then moving right; idle hiding off, so only typing hides it.
        let samples = stride(from: 0.0, through: 3, by: 1.0 / 60).map { time in
            StudioTelemetry.Sample(time: time, x: time < 2 ? 800 : 800 + 400 * (time - 2), y: 500, cursor: 0)
        }
        func opacity(at time: Double, keys: [StudioTelemetry.Key], hides: Bool = true) -> Double {
            let telemetry = StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 2, samples: samples, keys: keys, keystrokeMode: .all)
            var project = StudioProject()
            project.cursor.hidesWhenIdle = false
            project.cursor.hidesWhileTyping = hides
            return StudioTrack(telemetry: telemetry, project: project, duration: 3).frame(at: time).cursorOpacity
        }
        let typed = [Self.key(1, "h", keyCode: 4), Self.key(1.2, "i", keyCode: 34)]
        #expect(opacity(at: 0.9, keys: typed) > 0.99)
        #expect(opacity(at: 1.3, keys: typed) < 0.01)
        #expect(opacity(at: 1.9, keys: typed) < 0.01)
        #expect(opacity(at: 2.3, keys: typed) > 0.99)
        // Presses kept only as presses are typing too; a shortcut is not; and the setting turns it off.
        #expect(opacity(at: 1.3, keys: [.unrecorded(time: 1, isRepeat: false)]) < 0.01)
        #expect(opacity(at: 1.3, keys: [Self.key(1, "s", keyCode: 1, modifiers: .command)]) > 0.99)
        #expect(opacity(at: 1.3, keys: typed, hides: false) > 0.99)
    }

    @Test func aClickBringsBackTheCursorTypingHid() {
        let samples = [StudioTelemetry.Sample(time: 0, x: 800, y: 500, cursor: 0)]
        let telemetry = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 2, samples: samples, clicks: [.init(time: 2, x: 800, y: 500, button: .primary)],
            keys: [Self.key(1, "h", keyCode: 4)], keystrokeMode: .all
        )
        var project = StudioProject()
        project.cursor.hidesWhenIdle = false
        let track = StudioTrack(telemetry: telemetry, project: project, duration: 3)
        #expect(track.frame(at: 1.5).cursorOpacity < 0.01)
        #expect(track.frame(at: 2.2).cursorOpacity > 0.99)
    }

    @Test func aCameraThatWasNotKeptIsSaidSo() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-\(UUID().uuidString)")
        func document(_ telemetry: StudioTelemetry) -> StudioDocument {
            StudioDocument(
                source: folder.appending(path: "none.mp4"), telemetry: telemetry, project: StudioProject(), duration: 4,
                recordingSize: CGSize(width: 320, height: 200), folder: folder, hasBeenExported: false, background: { _, _ in nil }
            )
        }
        var telemetry = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2)
        // No camera at all: nothing to say.
        #expect(!document(telemetry).hasCamera && !document(telemetry).cameraFailed)
        // The bubble showed, but no movie came.
        telemetry.cameraFailed = true
        #expect(document(telemetry).cameraFailed)
        // A camera written down whose movie is gone.
        telemetry.cameraFailed = nil
        telemetry.camera = .init(start: 0, bubble: StudioProject.Camera())
        #expect(!document(telemetry).hasCamera && document(telemetry).cameraFailed)
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

    @Test func aZoomPlacedByHandBetweenTwoStretchesKeepsBothAutomaticZooms() {
        // Two pairs of clicks close enough to join into one automatic zoom, and a zoom placed by hand between
        // them: turned on again, the automatic zooms go on either side of it, not away with it.
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let telemetry = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 2, samples: [.init(time: 0, x: 800, y: 500, cursor: 0)],
            clicks: [1, 1.3, 4.3, 4.6].map { .init(time: $0, x: 800, y: 500, button: .primary) }
        )
        let document = StudioDocument(
            source: folder.appending(path: "none.mp4"), telemetry: telemetry, project: StudioProject(), duration: 10,
            recordingSize: CGSize(width: 3200, height: 2000), folder: folder, hasBeenExported: false, background: { _, _ in nil }
        )
        #expect(document.automaticZooms.count == 1)
        document.setAutomaticZooms(false)
        document.project.zooms = [StudioProject.Zoom(start: 2.8, end: 3.6, scale: 2, isAutomatic: false)]
        document.setAutomaticZooms(true)
        let zooms = document.project.zooms
        #expect(zooms.count == 3, "\(zooms.map { ($0.start, $0.end, $0.isAutomatic) })")
        #expect(zooms.map(\.isAutomatic) == [true, false, true])
        #expect(abs(zooms[0].end - (1.3 + AutoZoom.hold)) < 1e-9 && abs(zooms[2].start - (4.3 - AutoZoom.leadIn)) < 1e-9)
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
