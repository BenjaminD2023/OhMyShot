import AppKit
import Foundation
import OMSCore
import Testing
@testable import OMSUI

/// Selecting captures in Capture History, as in Finder, and what asks before captures leave it. Nothing is shown.
@MainActor
struct HistorySelectionTests {
    private func model(count: Int, trashed: @escaping (HistoryItem) -> Void = { _ in }) throws -> (HistoryModel, [HistoryItem]) {
        let suite = "OMSUITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistorySelectionTests-\(UUID().uuidString)"))
        let actions = HistoryActions(
            restore: { _ in }, copy: { _ in }, save: { _ in }, open: { _ in }, annotate: { _ in }, reveal: { _ in },
            recognizeText: { _ in }, pin: { _ in }, moveToTrash: trashed
        )
        let model = HistoryModel(store: store, settings: SettingsStore(defaults: defaults), actions: actions, expiredCount: { _ in 0 })
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

    @Test func oneSelectedCaptureGoesWithoutAsking() throws {
        var trashed: [UUID] = []
        let (model, items) = try model(count: 2) { trashed.append($0.id) }
        model.click(items[0].id, modifiers: [])
        model.trashSelection()
        #expect(model.trashRequest == nil)
        #expect(trashed == [items[0].id])
    }
}
