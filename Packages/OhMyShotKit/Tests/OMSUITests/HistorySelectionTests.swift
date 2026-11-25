import AppKit
import CoreGraphics
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

    @Test func oneSelectedCaptureStagesUndoableTrashWithoutAsking() throws {
        var trashed: [UUID] = []
        let (model, items) = try model(count: 2) { trashed.append($0.id) }
        defer { model.release() }
        model.click(items[0].id, modifiers: [])
        model.trashSelection()
        #expect(model.trashRequest == nil)
        #expect(model.pendingTrash?.item.id == items[0].id)
        #expect(model.visibleItems.map(\.id) == [items[1].id])
        #expect(trashed.isEmpty)
        model.commitPendingTrash()
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

    @Test func shiftArrowExtendsAndContractsSelectionFromAnchor() throws {
        let (model, items) = try model(count: 6)
        defer { model.release() }
        model.click(items[2].id, modifiers: [])
        model.moveSelection(by: 1, extending: true)
        #expect(model.selection == Set(items[2...3].map(\.id)))
        #expect(model.focus == items[3].id)

        model.moveSelection(by: 1, extending: true)
        #expect(model.selection == Set(items[2...4].map(\.id)))
        #expect(model.focus == items[4].id)

        // Stepping back shrinks the range toward the anchor.
        model.moveSelection(by: -1, extending: true)
        #expect(model.selection == Set(items[2...3].map(\.id)))
        #expect(model.focus == items[3].id)

        // Crossing past the anchor extends in the opposite direction from the same anchor.
        model.moveSelection(by: -2, extending: true)
        #expect(model.selection == Set(items[1...2].map(\.id)))
        #expect(model.focus == items[1].id)

        // A plain arrow collapses the selection and moves the anchor.
        model.moveSelection(by: 1, extending: false)
        #expect(model.selection == [items[2].id])
        #expect(model.focus == items[2].id)
    }

    @Test func requestTrashConfirmsMultipleTargetsAndStagesSingleTargetWithUndo() throws {
        var trashed: [UUID] = []
        let (model, items) = try model(count: 3) { trashed.append($0.id) }
        defer { model.release() }

        model.requestTrash([items[0], items[1]])
        #expect(trashed.isEmpty)
        #expect(model.trashRequest?.items.map(\.id) == [items[0].id, items[1].id])
        #expect(model.trashRequest?.isEverything == false)

        model.trashRequest = nil
        model.requestTrash([items[2]])
        #expect(model.trashRequest == nil)
        #expect(model.pendingTrash?.item.id == items[2].id)
        #expect(trashed.isEmpty)
        model.commitPendingTrash()
        #expect(trashed == [items[2].id])
    }

    @Test func copyUpdatesFeedbackAndRoutesSingleVsMultiSelection() throws {
        let suite = "OMSUITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryCopyTests-\(UUID().uuidString)"))
        var copiedSingle: [UUID] = []
        var copiedMulti: [[UUID]] = []
        var actions = HistoryActions(
            restore: { _ in }, copy: { copiedSingle.append($0.id) }, save: { _ in }, open: { _ in }, annotate: { _ in },
            reveal: { _ in }, recognizeText: { _ in }, pin: { _ in }, moveToTrash: { _ in }
        )
        actions.copyFiles = { copiedMulti.append($0.map(\.id)) }
        let model = HistoryModel(store: store, settings: SettingsStore(defaults: defaults), actions: actions)
        defer { model.release() }
        let items = (0..<3).map { HistoryItem(kind: .screenshot, pixelWidth: 10, pixelHeight: 10, appName: nil, fileName: "\($0).png") }
        model.items = items

        model.copy([items[0]])
        #expect(copiedSingle == [items[0].id])
        #expect(copiedMulti.isEmpty)
        #expect(model.copyFeedback?.count == 1)
        #expect(model.copyFeedback?.itemIDs == [items[0].id])

        model.copy([items[0], items[2]])
        #expect(copiedMulti == [[items[0].id, items[2].id]])
        #expect(model.copyFeedback?.count == 2)
        #expect(model.copyFeedback?.itemIDs == [items[0].id, items[2].id])
    }

    @Test func collageModelReordersReversesAndRemembersOptions() throws {
        func picture(width: Int, height: Int) throws -> CollageRenderer.Picture {
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            return CollageRenderer.Picture(image: try #require(context.makeImage()), size: CGSize(width: width, height: height))
        }
        let suite = "OMSUITests-Collage-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let pictures = [try picture(width: 100, height: 100), try picture(width: 200, height: 100), try picture(width: 300, height: 100)]
        let first = CollageModel(pictures: pictures, scale: 2, defaults: defaults)
        #expect(first.entries.map(\.picture.size.width) == [100, 200, 300])

        // Reorder and reverse update entries and bump revision.
        let initialRevision = first.orderRevision
        first.moveEntry(at: 0, by: 1)
        #expect(first.entries.map(\.picture.size.width) == [200, 100, 300])
        #expect(first.orderRevision == initialRevision + 1)

        first.reverseOrder()
        #expect(first.entries.map(\.picture.size.width) == [300, 100, 200])

        // Persist custom options, grid columns, and custom background color.
        let custom = CollageColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1, isDisplayP3: true)
        first.arrangement = .grid
        first.gridColumns = 3
        first.fitting = .fill
        first.spacing = 12
        first.margin = 36
        first.cornerRadius = 14
        first.customColor = custom
        first.background = .custom(custom)

        let second = CollageModel(pictures: pictures, scale: 2, defaults: defaults)
        #expect(second.arrangement == .grid)
        #expect(second.gridColumns == 3)
        #expect(second.fitting == .fill)
        #expect(second.spacing == 12)
        #expect(second.margin == 36)
        #expect(second.cornerRadius == 14)
        #expect(second.customColor == custom)
        #expect(second.background == .custom(custom))
    }

    @Test func favoritesAppAndDateFiltersNarrowVisibleItemsAndPreserveThumbnails() throws {
        let suite = "OMSUITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryFilters-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let actions = HistoryActions(
            restore: { _ in }, copy: { _ in }, save: { _ in }, open: { _ in }, annotate: { _ in }, reveal: { _ in },
            recognizeText: { _ in }, pin: { _ in }, moveToTrash: { _ in }
        )
        let settings = SettingsStore(defaults: defaults)
        settings.historyRetention = .oneWeek
        let model = HistoryModel(store: store, settings: settings, actions: actions)
        defer { model.release() }
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let todaySafari = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 10, appName: "Safari", date: now)
        let weekXcode = try store.add(
            data: Data([2]), fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 10, appName: "Xcode",
            date: now.addingTimeInterval(-3 * 86_400)
        )
        let oldNotes = try store.add(
            data: Data([3]), fileExtension: "mp4", kind: .recording, pixelWidth: 10, pixelHeight: 10, appName: "Notes",
            date: now.addingTimeInterval(-45 * 86_400)
        )
        model.items = [todaySafari, weekXcode, oldNotes]

        #expect(model.availableApps == ["Notes", "Safari", "Xcode"])

        // Favoriting persists and keeps cached thumbnails intact.
        let ctx = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        model.thumbnails[todaySafari.id] = ctx.makeImage()
        model.toggleFavorite([todaySafari])
        #expect(model.thumbnails[todaySafari.id] != nil)
        #expect(store.item(id: todaySafari.id)?.isFavorite == true)

        model.filter = .favorites
        #expect(model.visibleItems(now: now).map(\.id) == [todaySafari.id])

        model.clearFilters()
        model.appFilter = "Xcode"
        #expect(model.visibleItems(now: now).map(\.id) == [weekXcode.id])

        model.appFilter = nil
        model.dateFilter = .today
        #expect(model.visibleItems(now: now).map(\.id) == [todaySafari.id])
        model.dateFilter = .last7Days
        #expect(model.visibleItems(now: now).map(\.id) == [todaySafari.id, weekXcode.id])
        model.dateFilter = .last30Days
        #expect(model.visibleItems(now: now).map(\.id) == [todaySafari.id, weekXcode.id])
    }

    @Test func singleItemTrashUndoRestoresAndTimerOrReleaseCommits() async throws {
        let suite = "OMSUITests-UndoTrash-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryUndoTrash-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var trashed: [UUID] = []
        let actions = HistoryActions(
            restore: { _ in }, copy: { _ in }, save: { _ in }, open: { _ in }, annotate: { _ in }, reveal: { _ in },
            recognizeText: { _ in }, pin: { _ in }, moveToTrash: {
                trashed.append($0.id)
                store.delete($0)
            }
        )
        let first = try store.add(data: Data([1]), name: "0", fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 10, appName: nil)
        let second = try store.add(data: Data([2]), name: "1", fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 10, appName: nil)
        let model = HistoryModel(
            store: store, settings: SettingsStore(defaults: defaults), actions: actions,
            trashDelay: .milliseconds(50)
        )
        model.items = [first, second]

        // Undo cancels deferred trash and restores item into visible grid and selection.
        model.stageTrash(first)
        #expect(model.pendingTrash?.item.id == first.id)
        #expect(model.visibleItems.map(\.id) == [second.id])
        #expect(model.undoPendingTrash())
        #expect(model.pendingTrash == nil)
        #expect(model.visibleItems.map(\.id) == [first.id, second.id])
        #expect(model.selection == [first.id])
        try await Task.sleep(for: .milliseconds(90))
        #expect(trashed.isEmpty)

        // Letting the timer elapse commits the trash automatically.
        model.stageTrash(first)
        for _ in 0..<150 where model.pendingTrash != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(trashed == [first.id])
        #expect(model.pendingTrash == nil)
        #expect(model.activeItems.map(\.id) == [second.id])
        model.release()

        // Releasing the window while a trash is staged commits immediately instead of dropping it.
        let longModel = HistoryModel(
            store: store, settings: SettingsStore(defaults: defaults), actions: actions,
            trashDelay: .seconds(60)
        )
        longModel.items = [second]
        longModel.stageTrash(second)
        #expect(trashed == [first.id])
        longModel.release()
        #expect(trashed == [first.id, second.id])
        #expect(longModel.pendingTrash == nil)
    }

    @Test func stagedTrashRespectsEditorGuardAndRestoresOnCommitFailure() throws {
        var editing: Set<String> = ["0.png"]
        var shouldThrow = false
        let suite = "OMSUITests-StagedGuard-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryStagedGuard-\(UUID().uuidString)"))
        var actions = HistoryActions(
            restore: { _ in }, copy: { _ in }, save: { _ in }, open: { _ in }, annotate: { _ in }, reveal: { _ in },
            recognizeText: { _ in }, pin: { _ in }, moveToTrash: { _ in
                if shouldThrow { throw CocoaError(.fileWriteNoPermission) }
            }
        )
        actions.isBeingEdited = { editing.contains($0.fileName) }
        let model = HistoryModel(store: store, settings: SettingsStore(defaults: defaults), actions: actions)
        defer { model.release() }
        let items = (0..<2).map { HistoryItem(kind: .screenshot, pixelWidth: 10, pixelHeight: 10, appName: nil, fileName: "\($0).png") }
        model.items = items

        // Staging an item open in the editor refuses immediately and sets trashFailure.
        model.stageTrash(items[0])
        #expect(model.pendingTrash == nil)
        #expect(model.trashFailure != nil)
        #expect(model.visibleItems.map(\.id) == items.map(\.id))

        // If committing a staged trash throws, the item returns to visibleItems and selection with trashFailure set.
        editing = []
        model.trashFailure = nil
        shouldThrow = true
        model.stageTrash(items[0])
        #expect(model.pendingTrash?.item.id == items[0].id)
        model.commitPendingTrash()
        #expect(model.pendingTrash == nil)
        #expect(model.trashFailure != nil)
        #expect(model.visibleItems.map(\.id) == items.map(\.id))
        #expect(model.selection == [items[0].id])
    }

    @Test func diskUsageSummaryQuickLookURLsIndexingRetryAndTranslateAction() async throws {
        let suite = "OMSUITests-DiskUsage-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryDiskUsage-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var translatedAction: [UUID] = []
        var translatedOverride: [UUID] = []
        var retried = 0
        var actions = HistoryActions(
            restore: { _ in }, copy: { _ in }, save: { _ in }, open: { _ in }, annotate: { _ in }, reveal: { _ in },
            recognizeText: { _ in }, pin: { _ in }, moveToTrash: { _ in }
        )
        actions.translate = { translatedAction.append($0.id) }
        let model = HistoryModel(store: store, settings: SettingsStore(defaults: defaults), actions: actions)
        defer { model.release() }

        let first = try store.add(data: Data(repeating: 0xAA, count: 4096), fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 10, appName: "Safari")
        let second = try store.add(data: Data(repeating: 0xBB, count: 2048), fileExtension: "mp4", kind: .recording, pixelWidth: 10, pixelHeight: 10, appName: "Notes")
        model.items = [first, second]
        await model.waitForDiskUsage()
        let bytes = try #require(model.totalDiskBytes)
        #expect(bytes >= 6144)
        #expect(model.diskUsageSummary.contains("2"))
        #expect(HistoryModel.formattedDiskUsage(count: 0, bytes: nil) == String(localized: "0 captures", bundle: .module))
        let formatted = HistoryModel.formattedDiskUsage(count: 42, bytes: 1_048_576)
        #expect(formatted.contains("42") && formatted.contains("·"))

        // Quick Look multi-item preview URLs follow the active filter in grid order.
        #expect(model.visiblePreviewURLs == [store.fileURL(for: first), store.fileURL(for: second)])
        model.filter = .screenshots
        #expect(model.visiblePreviewURLs == [store.fileURL(for: first)])
        model.filter = .all

        // Failed indexing detection & Retry callback.
        model.onRetryIndexing = { retried += 1 }
        model.refreshFailedIndexingCount()
        for _ in 0..<50 where model.failedIndexingCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.failedIndexingCount == 1)
        model.retryIndexing()
        #expect(model.failedIndexingCount == 0 && retried == 1)

        // Translate closure falls back to actions.translate and allows controller override.
        model.resolvedTranslate?(first)
        #expect(translatedAction == [first.id])
        model.onTranslate = { translatedOverride.append($0.id) }
        model.resolvedTranslate?(first)
        #expect(translatedOverride == [first.id])
    }
}
