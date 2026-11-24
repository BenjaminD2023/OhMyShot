import AppKit
import Foundation
import OMSCore
import Testing
@testable import OMSUI

/// Selecting captures in Capture History, as in Finder, and what asks before captures leave it. Nothing is shown.
@MainActor
struct HistorySelectionTests {
    private func model(
        count: Int, editing: Set<String> = [], trashed: @escaping (HistoryItem) throws -> Void = { _ in },
        handOver: ((HistoryItem) -> URL?)? = nil, handOverAll: (([HistoryItem]) async -> [URL]?)? = nil
    ) throws -> (HistoryModel, [HistoryItem]) {
        let suite = "OMSUITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistorySelectionTests-\(UUID().uuidString)"))
        var actions = HistoryActions(
            restore: { _ in }, copy: { _ in }, save: { _ in }, open: { _ in }, annotate: { _ in }, reveal: { _ in },
            recognizeText: { _ in }, pin: { _ in }, moveToTrash: trashed
        )
        actions.isBeingEdited = { editing.contains($0.fileName) }
        actions.fileToHandOver = handOver
        actions.filesToHandOver = handOverAll
        let model = HistoryModel(store: store, settings: SettingsStore(defaults: defaults), actions: actions)
        let items = (0..<count).map { HistoryItem(kind: .screenshot, pixelWidth: 10, pixelHeight: 10, appName: nil, fileName: "\($0).png") }
        model.items = items
        return (model, items)
    }

    @Test func aClickSelectsOneAndCommandClickAddsOrTakesAway() throws {
        let (model, items) = try model(count: 4)
        model.click(items[1].id, modifiers: [])
        #expect(model.selection == [items[1].id])
        model.click(items[3].id, modifiers: .command)
        #expect(model.selection == [items[1].id, items[3].id])
        model.click(items[1].id, modifiers: .command)
        #expect(model.selection == [items[3].id])
        #expect(model.focusedItem?.id == items[3].id)
    }

    @Test func shiftClickSelectsTheRunFromTheLastClick() throws {
        let (model, items) = try model(count: 5)
        model.click(items[3].id, modifiers: [])
        model.click(items[1].id, modifiers: .shift)
        #expect(model.selection == Set(items[1...3].map(\.id)))
        // The anchor stays: a second ⇧-click runs from the same capture.
        model.click(items[4].id, modifiers: .shift)
        #expect(model.selection == Set(items[3...4].map(\.id)))
    }

    @Test func selectAllTakesEveryCaptureShown() throws {
        let (model, items) = try model(count: 3)
        model.selectAll()
        #expect(model.selectedItems.map(\.id) == items.map(\.id))
    }

    /// One capture goes at once, as in Finder; several, or everything the window shows, only once confirmed.
    @Test func severalCapturesAskBeforeTheyGo() throws {
        var trashed: [UUID] = []
        let (model, items) = try model(count: 3) { trashed.append($0.id) }
        model.click(items[0].id, modifiers: [])
        model.click(items[1].id, modifiers: .command)
        model.trashSelection()
        #expect(trashed.isEmpty)
        let request = try #require(model.trashRequest)
        #expect(request.items.map(\.id) == [items[0].id, items[1].id])
        #expect(!request.isEverything)
        model.moveToTrash(request.items)
        #expect(trashed == [items[0].id, items[1].id])
    }

    @Test func theToolbarsTrashTakesWhatIsShown() throws {
        let (model, items) = try model(count: 3)
        model.trashShown()
        #expect(model.trashRequest?.isEverything == true)
        #expect(model.trashRequest?.items.count == items.count)
    }

    @Test func capturesThatCouldNotMoveToTheTrashStaySelected() throws {
        let (model, items) = try model(count: 2) { item in
            if item.fileName == "1.png" { throw CocoaError(.fileWriteNoPermission) }
        }
        model.selectAll()
        model.moveToTrash(items)
        #expect(model.trashFailure != nil)
        #expect(model.selection == [items[1].id])
    }

    @Test func aCaptureOpenInTheEditorCannotBeTrashedFromHistory() throws {
        var attempted = false
        let (model, items) = try model(count: 1, editing: ["0.png"]) { _ in attempted = true }
        model.selectAll()
        model.moveToTrash(items)
        #expect(!attempted)
        #expect(model.selection == [items[0].id])
        #expect(model.trashFailure != nil)
    }

    /// Combine into Collage and Export as PDF take the selection in the grid's order, whatever order it was clicked in;
    /// a card's menu outside the selection takes that card alone; a recording among them turns both off.
    @Test func collageAndPDFTakeTheSelectionInTheGridsOrder() throws {
        let (model, items) = try model(count: 4)
        model.click(items[3].id, modifiers: [])
        model.click(items[0].id, modifiers: .command)
        model.click(items[2].id, modifiers: .command)
        #expect(model.collageItems(from: nil).map(\.id) == [items[0].id, items[2].id, items[3].id])
        #expect(model.pdfItems(from: items[2]).map(\.id) == [items[0].id, items[2].id, items[3].id])
        // A card outside the selection: that card alone, too few for a collage.
        #expect(model.collageItems(from: items[1]).isEmpty)
        #expect(model.pdfItems(from: items[1]).map(\.id) == [items[1].id])

        let recording = HistoryItem(kind: .recording, pixelWidth: 10, pixelHeight: 10, appName: nil, fileName: "r.mov")
        model.items = items + [recording]
        model.selectAll()
        #expect(model.collageItems(from: nil).isEmpty)
        #expect(model.pdfItems(from: nil).isEmpty)
    }

    @Test func oneSelectedCaptureGoesWithoutAsking() throws {
        var trashed: [UUID] = []
        let (model, items) = try model(count: 2) { trashed.append($0.id) }
        model.click(items[0].id, modifiers: [])
        model.trashSelection()
        #expect(model.trashRequest == nil)
        #expect(trashed == [items[0].id])
    }

    /// A drag from a selected card, or its Share…, takes every selected capture in the grid's order, each as the copy
    /// Settings ask for; a card outside the selection goes alone and leaves the selection as it is.
    @Test func aSelectedCardHandsOverTheWholeSelection() throws {
        var asked: [String] = []
        let (model, items) = try model(count: 4, handOver: { item in
            asked.append(item.fileName)
            return URL(filePath: "/converted/\(item.fileName)")
        })
        model.click(items[3].id, modifiers: [])
        model.click(items[0].id, modifiers: .command)
        model.click(items[2].id, modifiers: .command)
        let files = model.filesToHandOver(from: items[2].id)
        #expect(files.map(\.id) == [items[0].id, items[2].id, items[3].id])
        #expect(files.map(\.url.path) == ["/converted/0.png", "/converted/2.png", "/converted/3.png"])

        asked = []
        #expect(model.filesToHandOver(from: items[1].id).map(\.url.path) == ["/converted/1.png"])
        #expect(asked == ["1.png"])
        #expect(model.selection == [items[0].id, items[2].id, items[3].id])
    }

    /// One copy that can't be made sends none of the selection, rather than the rest without it, and is asked for no
    /// further, so the reason is said once.
    @Test func oneCopyThatCannotBeMadeSendsNoneOfTheSelection() throws {
        var asked: [String] = []
        let (model, items) = try model(count: 3, handOver: { item in
            asked.append(item.fileName)
            return item.fileName == "1.png" ? nil : URL(filePath: "/converted/\(item.fileName)")
        })
        model.selectAll()
        #expect(model.filesToHandOver(from: items[2].id).isEmpty)
        #expect(asked == ["0.png", "1.png"])
    }

    /// Share… takes what a drag would, its copies made together off the main actor rather than one by one on it; none
    /// when one of them can't be made.
    @Test func shareMakesTheSelectionsCopiesTogetherOffTheWindow() async throws {
        var oneByOne = 0
        var together: [[String]] = []
        var fails = false
        let (model, items) = try model(
            count: 3,
            handOver: { item in
                oneByOne += 1
                return URL(filePath: "/converted/\(item.fileName)")
            },
            handOverAll: { items in
                together.append(items.map(\.fileName))
                return fails ? nil : items.map { URL(filePath: "/converted/\($0.fileName)") }
            }
        )
        model.click(items[2].id, modifiers: [])
        model.click(items[0].id, modifiers: .command)
        #expect(await model.filesToShare(from: items[2].id).map(\.path) == ["/converted/0.png", "/converted/2.png"])
        #expect(await model.filesToShare(from: items[1].id).map(\.path) == ["/converted/1.png"])
        #expect(together == [["0.png", "2.png"], ["1.png"]])
        #expect(oneByOne == 0)
        fails = true
        #expect(await model.filesToShare(from: items[0].id).isEmpty)
    }
}
