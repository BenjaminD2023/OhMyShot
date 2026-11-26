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
            width: 1600, height: 1000, pixelsPerPoint: 2, samples: [.init(time: 0, x: 800, y: 500, cursor: 0)],
            clicks: [.init(time: 2.8, x: 800, y: 500, button: .primary)], keys: presses,
            keystrokeMode: .shortcuts
        )
        let zooms = AutoZoom.zooms(for: telemetry, duration: 8)
        #expect(zooms.count == 1)
        #expect(zooms[0].scale == AutoZoom.standardScale)
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

    /// Add Zoom says when it has no room rather than doing nothing: zooms filling the 4 s clip leave none.
    @Test func addZoomSaysWhenItHasNoRoom() throws {
        let document = try document()
        defer { try? FileManager.default.removeItem(at: document.folder) }
        #expect(document.canAddZoom)
        document.addZoom()
        document.addZoom()
        #expect(document.project.zooms.count == 2)
        #expect(!document.canAddZoom)
        let before = document.project.zooms
        document.addZoom()
        #expect(document.project.zooms == before)
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

    @Test func aLoneClickIsSomethingToFollowThoughItPlacesNoZoom() {
        // One click inside the recording places no zoom, but the panel says why rather than that nothing was clicked;
        // a click on another display, outside the recording, is nothing to follow.
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func document(clickAt x: Double) -> StudioDocument {
            StudioDocument(
                source: folder.appending(path: "none.mp4"),
                telemetry: StudioTelemetry(
                    width: 1600, height: 1000, pixelsPerPoint: 2, samples: [.init(time: 0, x: 800, y: 500, cursor: 0)],
                    clicks: [.init(time: 2, x: x, y: 500, button: .primary)]
                ),
                project: StudioProject(), duration: 10, recordingSize: CGSize(width: 3200, height: 2000), folder: folder, hasBeenExported: false,
                background: { _, _ in nil }
            )
        }
        let inside = document(clickAt: 800)
        #expect(inside.automaticZooms.isEmpty && inside.hasEventsToFollow)
        let outside = document(clickAt: 2400)
        #expect(outside.automaticZooms.isEmpty && !outside.hasEventsToFollow)
    }

    @Test func resizingACutClampsToBoundsAndNeighborsAndSupportsUndo() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioCutResizeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let telemetry = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)])
        let document = StudioDocument(
            source: folder.appending(path: "none.mp4"), telemetry: telemetry,
            project: StudioProject(cuts: [1.0...2.0, 4.0...5.0]), duration: 10,
            recordingSize: CGSize(width: 320, height: 200), folder: folder, hasBeenExported: false, background: { _, _ in nil }
        )
        defer { document.releasePreview() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManagerProvider = { undo }

        // Resizing the start edge keeps the cut selected at its new lowerBound and records a named undo step.
        document.selection = .cut(1.0)
        undo.beginUndoGrouping()
        let widened = try #require(document.setCutEdge(at: 1.0, start: true, to: 0.5))
        undo.endUndoGrouping()
        #expect(widened == 0.5...2.0)
        #expect(document.project.cuts == [0.5...2.0, 4.0...5.0])
        #expect(document.selection == .cut(0.5))
        #expect(undo.undoActionName == "Resize Cut")

        // Start clamps at 0; end clamps short of the adjacent cut so cuts never overlap or merge on drag.
        undo.beginUndoGrouping()
        #expect(document.setCutEdge(at: 0.5, start: true, to: -2.0) == 0.0...2.0)
        undo.endUndoGrouping()
        #expect(document.selection == .cut(0.0))

        undo.beginUndoGrouping()
        let clampedToNeighbor = try #require(document.setCutEdge(at: 0.0, start: false, to: 4.5))
        undo.endUndoGrouping()
        #expect(abs(clampedToNeighbor.upperBound - (4.0 - StudioDocument.minimumCutGap)) < 1e-9)
        #expect(clampedToNeighbor.upperBound < 4.0)

        // Start dragged past end enforces shortestCut without moving the end; end clamps at duration.
        undo.beginUndoGrouping()
        let minWidth = try #require(document.setCutEdge(at: 4.0, start: true, to: 6.0))
        undo.endUndoGrouping()
        #expect(abs(minWidth.lowerBound - (5.0 - StudioDocument.shortestCut)) < 1e-9 && minWidth.upperBound == 5.0)

        undo.beginUndoGrouping()
        let clampedEnd = try #require(document.setCutEdge(at: minWidth.lowerBound, start: false, to: 15.0))
        undo.endUndoGrouping()
        #expect(clampedEnd.upperBound == 10.0)

        // Unknown cut returns nil.
        #expect(document.setCutEdge(at: 99.0, start: true, to: 1.0) == nil)

        // A continuous drag coalesces into a single Undo step.
        let beforeDrag = document.project.cuts
        undo.beginUndoGrouping()
        document.beginContinuousChange()
        var currentStart = minWidth.lowerBound
        for target in [4.8, 4.5, 4.2] {
            if let next = document.setCutEdge(at: currentStart, start: true, to: target) {
                currentStart = next.lowerBound
            }
        }
        document.endContinuousChange()
        undo.endUndoGrouping()
        #expect(abs(document.project.cuts[1].lowerBound - 4.2) < 1e-9)

        undo.undo()
        #expect(document.project.cuts == beforeDrag)
        undo.redo()
        #expect(abs(document.project.cuts[1].lowerBound - 4.2) < 1e-9)
    }

    @Test func hasKeysIgnoresUnrecordedPlaceholdersUnderShortcutsOnly() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioKeysTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func makeDocument(keys: [StudioTelemetry.Key], mode: KeystrokeMode?) -> StudioDocument {
            StudioDocument(
                source: folder.appending(path: "none.mp4"),
                telemetry: StudioTelemetry(
                    width: 1600, height: 1000, pixelsPerPoint: 2,
                    samples: [.init(time: 0, x: 800, y: 500, cursor: 0)],
                    keys: keys, keystrokeMode: mode
                ),
                project: StudioProject(), duration: 6,
                recordingSize: CGSize(width: 3200, height: 2000), folder: folder,
                hasBeenExported: false, background: { _, _ in nil }
            )
        }
        let unrecordedOnly = (0..<4).map { StudioTelemetry.Key.unrecorded(time: 1 + Double($0) * 0.2, isRepeat: false) }
        let docUnrecorded = makeDocument(keys: unrecordedOnly, mode: .shortcuts)
        #expect(!docUnrecorded.hasKeys)
        #expect(docUnrecorded.hasKeyPresses)

        let withShortcut = unrecordedOnly + [Self.key(2, "s", keyCode: 1, modifiers: .command)]
        let docShortcut = makeDocument(keys: withShortcut, mode: .shortcuts)
        #expect(docShortcut.hasKeys)

        let docEmpty = makeDocument(keys: [], mode: .shortcuts)
        #expect(!docEmpty.hasKeys)
    }

    @Test func resetToAutomaticAndClearAllZoomsSupportUndo() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioZoomResetTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let telemetry = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 2,
            samples: [.init(time: 0, x: 800, y: 500, cursor: 0)],
            clicks: [1.0, 1.2, 1.4].map { .init(time: $0, x: 800, y: 500, button: .primary) }
        )
        let auto = AutoZoom.zooms(for: telemetry, duration: 8)
        let document = StudioDocument(
            source: folder.appending(path: "none.mp4"), telemetry: telemetry,
            project: StudioProject(zooms: auto), duration: 8,
            recordingSize: CGSize(width: 3200, height: 2000), folder: folder,
            hasBeenExported: false, background: { _, _ in nil }
        )
        defer { document.releasePreview() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManagerProvider = { undo }

        #expect(document.matchesAutomaticZooms)

        undo.beginUndoGrouping()
        document.time = 5.0
        document.addZoom()
        undo.endUndoGrouping()
        #expect(!document.matchesAutomaticZooms)
        #expect(document.project.zooms.count == auto.count + 1)

        undo.beginUndoGrouping()
        document.resetToAutomaticZooms()
        undo.endUndoGrouping()
        #expect(document.matchesAutomaticZooms)
        let allAutomatic = document.project.zooms.allSatisfy(\.isAutomatic)
        #expect(allAutomatic)
        #expect(undo.undoActionName == "Reset to Automatic")

        undo.undo()
        #expect(document.project.zooms.count == auto.count + 1)

        undo.beginUndoGrouping()
        document.clearAllZooms()
        undo.endUndoGrouping()
        #expect(document.project.zooms.isEmpty)
        #expect(!document.project.automaticZooms)
        #expect(undo.undoActionName == "Clear All Zooms")

        undo.undo()
        #expect(document.project.zooms.count == auto.count + 1)
    }

    @Test func keepOnlyTrimsBothSidesInOneUndoableStep() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioKeepOnlyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let telemetry = StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2, samples: [.init(time: 0, x: 80, y: 50, cursor: 0)])
        let document = StudioDocument(
            source: folder.appending(path: "none.mp4"), telemetry: telemetry,
            project: StudioProject(), duration: 10,
            recordingSize: CGSize(width: 320, height: 200), folder: folder,
            hasBeenExported: false, background: { _, _ in nil }
        )
        defer { document.releasePreview() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        document.undoManagerProvider = { undo }

        document.selection = .range(2.0...7.0)
        undo.beginUndoGrouping()
        document.keepOnly(2.0...7.0)
        undo.endUndoGrouping()
        #expect(document.project.cuts == [0.0...2.0, 7.0...10.0])
        #expect(document.selection == .none)
        #expect(undo.undoActionName == "Keep Only")

        undo.undo()
        #expect(document.project.cuts.isEmpty)

        // Preserves interior cuts and handles leading/trailing boundary selections cleanly.
        document.undoManagerProvider = { nil }
        document.project.cuts = [4.0...5.0]
        document.undoManagerProvider = { undo }
        undo.beginUndoGrouping()
        document.keepOnly(2.0...7.0)
        undo.endUndoGrouping()
        #expect(document.project.cuts == [0.0...2.0, 4.0...5.0, 7.0...10.0])

        document.undoManagerProvider = { nil }
        document.project.cuts = []
        document.keepOnly(0.0...6.0)
        #expect(document.project.cuts == [6.0...10.0])

        document.project.cuts = []
        document.keepOnly(3.0...10.0)
        #expect(document.project.cuts == [0.0...3.0])

        // Full range or too-short range does not add spurious cuts.
        document.project.cuts = []
        document.selection = .range(0.0...10.0)
        document.keepOnly(0.0...10.0)
        #expect(document.project.cuts.isEmpty && document.selection == .none)

        document.keepOnly(2.0...2.01)
        #expect(document.project.cuts.isEmpty)
    }
}
