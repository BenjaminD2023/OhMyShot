import AppKit
import CoreGraphics
import Foundation
import OMSCore
import Testing
@testable import OMSUI

@MainActor
@Suite(.serialized)
struct QuickAccessRetentionTests {
    enum Tracking: Equatable, Sendable {
        case visible
        case recentlyClosed
        case untracked
    }

    private struct ItemFactory {
        let history: HistoryStore
        let thumbnail: CGImage

        func callAsFunction() throws -> QuickAccessItem {
            let entry = try history.add(data: Data([0]), name: UUID().uuidString, fileExtension: "png", kind: .screenshot,
                                        pixelWidth: 1, pixelHeight: 1, appName: nil)
            return QuickAccessItem(entry, fileURL: history.fileURL(for: entry), thumbnail: thumbnail, displayID: 0)
        }
    }

    private func fixture(
        configure: (inout QuickAccessController.Actions) -> Void = { _ in },
        _ run: (QuickAccessController, ItemFactory) async throws -> Void
    ) async throws {
        try await fixtureWithHistory(configure: configure) { cards, _, make in
            try await run(cards, make)
        }
    }

    private func fixtureWithHistory(
        configure: (inout QuickAccessController.Actions) -> Void = { _ in },
        _ run: (QuickAccessController, HistoryStore, ItemFactory) async throws -> Void
    ) async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let thumbnail = try #require(context.makeImage())
        let history = HistoryStore(directory: folder)
        var actions = QuickAccessController.Actions(
            copy: { _ in false }, save: { _, _ in .cancelled }, saveAs: { _ in .cancelled },
            open: { _ in }, annotate: { _ in }, reveal: { _ in }, recognizeText: { _ in },
            pin: { _ in false }, moveToTrash: { _ in }, closed: { item in
                #expect(throws: Never.self) { try FileManager.default.removeItem(at: item.fileURL) }
            }
        )
        configure(&actions)
        try await run(QuickAccessController(actions: actions, history: history), history, ItemFactory(history: history, thumbnail: thumbnail))
    }

    private func staleExportScenario(tracking: Tracking, rewritesCurrentDestination: Bool) async throws {
        let newerContents = Data([2])
        let olderContents = Data([1])
        let failure = ExportFailure(cause: .diskFull, summary: "A later save failed", detail: "The disk is full.")
        try await fixtureWithHistory(configure: { actions in
            actions.closed = { _ in }
        }) { cards, history, make in
            defer { cards.dismissAll() }
            let capture = try make()
            let folder = capture.fileURL.deletingLastPathComponent()
            let newerSource = folder.appending(path: "newer-source.png")
            let olderSource = folder.appending(path: "older-source.png")
            let currentDestination = folder.appending(path: "current-export.png")
            try newerContents.write(to: newerSource)
            try olderContents.write(to: olderSource)
            cards.add(capture)

            let newerExport = await AtomicFileCopy.save(newerSource, as: currentDestination)
            #expect(newerExport.url == currentDestination)
            cards.markSaved(capture.id, at: currentDestination)
            if tracking == .visible {
                #expect(cards.showFailure(failure, for: capture.id))
            }
            if tracking != .visible {
                cards.dismiss(capture.id)
                if tracking == .untracked { _ = cards.takeRecentlyClosed() }
            }

            let olderDestination: URL
            if rewritesCurrentDestination {
                let alias = folder.appending(path: "folder-alias")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
                olderDestination = alias.appending(path: currentDestination.lastPathComponent)
            } else {
                olderDestination = folder.appending(path: "older-export.png")
            }
            let olderExport = await AtomicFileCopy.save(olderSource, as: olderDestination)
            #expect(olderExport.url == olderDestination)
            cards.markSaved(capture.id, at: olderDestination, isCurrent: false)

            #expect(try Data(contentsOf: olderDestination) == olderContents)
            if !rewritesCurrentDestination {
                #expect(try Data(contentsOf: currentDestination) == newerContents)
            }
            if tracking == .recentlyClosed {
                cards.restoreRecentlyClosed()
            } else if tracking == .untracked {
                cards.restore(try #require(history.item(id: capture.id)), on: 0)
            }

            let restored = try #require(cards.item(capture.id))
            #expect(restored.savedURL == (rewritesCurrentDestination ? nil : currentDestination))
            if tracking == .visible { #expect(cards.failure(for: capture.id) == failure) }
        }
    }

    @Test(arguments: [false, true])
    func displacedCardRestoresUntilExplicitlyClosed(byHeight: Bool) async throws {
        try await fixture { cards, make in
            let first = try make(), second = try make()
            cards.maximumCards = byHeight ? 2 : 1
            cards.insertIntoStack(first)
            cards.insertIntoStack(second)
            if byHeight { cards.fitStack(to: 1, size: .medium) }
            #expect(cards.itemIDs == [second.id])
            #expect(cards.heldCaptureIDs(for: .never) == [first.id, second.id])
            #expect(cards.canRestoreRecentlyClosed)

            cards.insertIntoStack(try #require(cards.takeRecentlyClosed()))
            #expect(cards.item(first.id) != nil)
            cards.dismiss(first.id)
            #expect(!cards.heldCaptureIDs(for: .never).contains(first.id))
            #expect(!FileManager.default.fileExists(atPath: first.fileURL.path))
            #expect(cards.takeRecentlyClosed()?.id == (byHeight ? nil : second.id))
        }
    }

    @Test func overflowAndTerminationReleaseDisplacedCardsButNotVisibleOnes() async throws {
        try await fixture { cards, make in
            cards.maximumCards = 1
            let items = try (0..<22).map { _ in try make() }
            items.forEach(cards.insertIntoStack)
            #expect(cards.heldCaptureIDs(for: .never) == Set(items.dropFirst().map(\.id)))
            #expect(!FileManager.default.fileExists(atPath: items[0].fileURL.path))
            cards.finishTrashingNow()
            #expect(cards.heldCaptureIDs(for: .never) == [items[21].id])
            #expect(!cards.canRestoreRecentlyClosed)
            #expect(items.dropLast().allSatisfy { !FileManager.default.fileExists(atPath: $0.fileURL.path) })
            #expect(FileManager.default.fileExists(atPath: items[21].fileURL.path))
        }
    }

    @Test func readdingOrRemovingADisplacedCardForgetsItsRestoreHold() async throws {
        try await fixture { cards, make in
            cards.maximumCards = 1
            let first = try make(), second = try make()
            cards.insertIntoStack(first)
            cards.insertIntoStack(second)
            cards.insertIntoStack(first)
            cards.remove(second.id)
            cards.dismissAll()
            #expect(cards.heldCaptureIDs(for: .never).isEmpty)
            #expect(!cards.canRestoreRecentlyClosed)
            #expect(!FileManager.default.fileExists(atPath: first.fileURL.path))
            #expect(FileManager.default.fileExists(atPath: second.fileURL.path))
        }
    }

    @Test func failedTrashKeepsItsCardPastTheAutoCloseDeadline() async throws {
        var closed: [UUID] = []
        try await fixture(configure: { actions in
            actions.preferences = { QuickAccessPreferences(closeAfter: 3, closeAction: .close) }
            actions.moveToTrash = { _ in throw CocoaError(.fileWriteNoPermission) }
            actions.closed = { closed.append($0.id) }
        }) { cards, make in
            let failed = try make(), other = try make()
            cards.insertIntoStack(failed)
            cards.insertIntoStack(other)
            cards.showTrashFailure = { _ in }
            cards.perform(.moveToTrash, on: failed, keyed: false)
            cards.finishTrashingNow()
            cards.closeDueCards(at: .greatestFiniteMagnitude)
            #expect(closed == [other.id])
            #expect(cards.itemIDs == [failed.id])
        }
    }

    @Test func restoredCardUsesTheExportSavedWhileDisplacedForRevealAndTrash() async throws {
        var revealed: URL?, trashedCopy: URL?
        try await fixture(configure: { actions in
            actions.reveal = { revealed = $0.savedURL ?? $0.fileURL }
            actions.moveToTrash = { trashedCopy = $0.ownSavedURL }
        }) { cards, make in
            let old = try make(), newer = try make()
            let folder = old.fileURL.deletingLastPathComponent(), export = folder.appending(path: "edited.png")
            cards.maximumCards = 1
            cards.insertIntoStack(old)
            cards.markSaved(old.id, at: folder.appending(path: "previous.png"))
            cards.insertIntoStack(newer)
            cards.markSaved(old.id, at: export, byCard: true)
            cards.insertIntoStack(try #require(cards.takeRecentlyClosed()))
            let restored = try #require(cards.item(old.id))
            cards.perform(.reveal, on: restored, keyed: false)
            cards.perform(.moveToTrash, on: restored, keyed: false)
            cards.finishTrashingNow()
            #expect(revealed == export)
            #expect(trashedCopy == export)
        }
    }

    /// A copy saved from Capture History (or the editor) is the person's: the card shows it saved and its Save shows it in
    /// Finder, but its Move to Trash takes only a copy the card saved itself, if it saved one, never that export.
    @Test(arguments: [false, true])
    func trashLeavesACopySavedFromHistory(cardSavedFirst: Bool) async throws {
        var revealed: URL?, trashed: QuickAccessItem?
        try await fixture(configure: { actions in
            actions.save = { item, _ in .saved(item.fileURL.deletingLastPathComponent().appending(path: "card.png")) }
            actions.reveal = { revealed = $0.savedURL ?? $0.fileURL }
            actions.moveToTrash = { trashed = $0 }
            actions.closed = { _ in }
        }) { cards, make in
            let capture = try make()
            let folder = capture.fileURL.deletingLastPathComponent(), export = folder.appending(path: "history.png")
            cards.insertIntoStack(capture)
            if cardSavedFirst {
                cards.perform(.save, on: capture, keyed: false)
                for _ in 0..<20 { await Task.yield() }
                #expect(cards.item(capture.id) == nil)
                cards.insertIntoStack(try #require(cards.takeRecentlyClosed()))
            }
            cards.markSaved(capture.id, at: export)
            let card = try #require(cards.item(capture.id))
            cards.perform(.reveal, on: card, keyed: false)
            cards.perform(.moveToTrash, on: card, keyed: false)
            cards.finishTrashingNow()
            #expect(revealed == export)
            #expect(trashed?.id == capture.id)
            #expect(trashed?.ownSavedURL == (cardSavedFirst ? folder.appending(path: "card.png") : nil))
        }
    }

    @Test func timedHistoryExpiresADisplacedCaptureThatNeverWouldKeep() async throws {
        try await fixture { cards, make in
            let seed = try make()
            let store = HistoryStore(directory: seed.fileURL.deletingLastPathComponent())
            store.delete(try #require(store.item(forFileAt: seed.fileURL)))
            let now = Date.now, old = now.addingTimeInterval(-2 * 86_400)
            let entries = try ["displaced", "visible"].map { name in
                try store.add(data: Data([0]), name: name, fileExtension: "png", kind: .screenshot,
                              pixelWidth: 1, pixelHeight: 1, appName: nil, date: old)
            }
            cards.maximumCards = 1
            for entry in entries {
                cards.insertIntoStack(QuickAccessItem(entry, fileURL: store.fileURL(for: entry), thumbnail: seed.thumbnail, displayID: 0))
            }
            #expect(store.removeExpired(retention: .never, keeping: cards.heldCaptureIDs(for: .never), now: now) == 0)
            #expect(store.removeExpired(retention: .oneDay, keeping: cards.heldCaptureIDs(for: .oneDay), now: now) == 1)
            #expect(store.items().map(\.id) == [entries[1].id])
            #expect(!cards.canRestoreRecentlyClosed)
        }
    }

    @Test func reusedHistoryFilenameCannotRestoreThePreviousCapture() async throws {
        var released: [UUID] = []
        try await fixture(configure: { $0.closed = { released.append($0.id) } }) { cards, make in
            let first = try make(), other = try make()
            let store = HistoryStore(directory: first.fileURL.deletingLastPathComponent())
            let entry = try #require(store.item(forFileAt: first.fileURL))
            cards.maximumCards = 1
            cards.insertIntoStack(first)
            cards.insertIntoStack(other)
            #expect(cards.canRestoreRecentlyClosed)
            store.delete(entry)
            let new = try store.add(data: Data([1]), name: first.fileURL.deletingPathExtension().lastPathComponent, fileExtension: "png",
                                    kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
            #expect(new.id != entry.id)
            #expect(store.fileURL(for: new) == first.fileURL)
            #expect(!cards.canRestoreRecentlyClosed)
            #expect(cards.takeRecentlyClosed() == nil)
            #expect(released == [entry.id])
            #expect(store.item(id: new.id) != nil)
        }
    }

    @Test(arguments: [false, true])
    func editedRecentlyClosedCardNeverRestoresItsOldPixels(restoreDuringDecode: Bool) async throws {
        try await fixture(configure: { $0.closed = { _ in } }) { cards, make in
            let first = try make(), other = try make()
            let store = HistoryStore(directory: first.fileURL.deletingLastPathComponent())
            let entry = try #require(store.item(forFileAt: first.fileURL))
            cards.maximumCards = 1
            cards.insertIntoStack(first)
            if restoreDuringDecode { cards.insertIntoStack(other) } else { cards.dismiss(first.id) }
            var release: CheckedContinuation<CGImage?, Never>?
            let (began, beganDecoding) = AsyncStream<Void>.makeStream()
            let oldUpdate = try #require(cards.pictureChanged(entry, savedCopyIsStale: true) {
                await withCheckedContinuation { continuation in
                    release = continuation
                    beganDecoding.finish()
                }
            })
            for await _ in began {}
            let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            let redacted = try #require(context.makeImage())
            let png = try ImageExporter.encoded(redacted, as: .png)
            let changed = try store.replaceImage(of: entry, with: png, pixelWidth: 4, pixelHeight: 4, annotations: Data())
            let update = try #require(cards.pictureChanged(changed, savedCopyIsStale: true) {
                await HistoryStore.cardThumbnail(of: png, maxPixels: QuickAccessItem.thumbnailPixels)
            })
            if restoreDuringDecode {
                let pending = try #require(cards.takeRecentlyClosed())
                #expect(pending.thumbnail !== first.thumbnail)
                cards.insertIntoStack(pending)
            }
            let saved = first.fileURL.deletingLastPathComponent().appending(path: "redacted.png")
            cards.markSaved(entry.id, at: saved)
            await update.value
            release?.resume(returning: first.thumbnail)
            await oldUpdate.value
            let current = try #require(restoreDuringDecode ? cards.item(entry.id) : cards.takeRecentlyClosed())
            #expect(current.thumbnail.width == 4 && current.thumbnail.height == 4)
            #expect(current.pixelWidth == 4 && current.pixelHeight == 4)
            #expect(current.savedURL == saved)
        }
    }

    @Test(arguments: [Tracking.visible, .recentlyClosed, .untracked])
    func contentEditsInvalidateSavedCopiesForEveryTrackingState(tracking: Tracking) async throws {
        var saved: [UUID] = []
        let (closedEvents, announceClosed) = AsyncStream<UUID>.makeStream()
        let closedReader = AsyncEventReader(closedEvents)
        var waitingForClose = false
        try await fixtureWithHistory(configure: { actions in
            actions.closed = { if waitingForClose { announceClosed.yield($0.id) } }
            actions.preferences = { QuickAccessPreferences(closeAfter: 3, closeAction: .saveAndClose) }
            actions.save = { item, _ in
                saved.append(item.id)
                return .saved(item.fileURL.deletingLastPathComponent().appending(path: "updated.png"))
            }
        }) { cards, history, make in
            defer { cards.dismissAll() }
            let capture = try make()
            let export = capture.fileURL.deletingLastPathComponent().appending(path: "original.png")
            cards.add(capture)
            cards.markSaved(capture.id, at: export, byCard: true)
            if tracking != .visible {
                cards.dismiss(capture.id)
                if tracking == .untracked { _ = cards.takeRecentlyClosed() }
            }

            let entry = try #require(history.item(id: capture.id))
            let update = cards.pictureChanged(entry, savedCopyIsStale: true) { nil }
            switch update {
            case .some(let update):
                #expect(tracking != .untracked)
                await update.value
            case .none:
                #expect(tracking == .untracked)
            }
            if tracking == .recentlyClosed {
                cards.restoreRecentlyClosed()
            } else if tracking == .untracked {
                cards.restore(entry, on: 0)
            }
            let restored = try #require(cards.item(capture.id))
            #expect(restored.savedURL == nil)
            #expect(restored.ownSavedURL == export)

            waitingForClose = true
            cards.closeDueCards(at: .greatestFiniteMagnitude)
            let closedID = await waitForEvent(from: closedReader)
            #expect(closedID == capture.id)
            #expect(saved == [capture.id])
            announceClosed.finish()
        }
    }

    @Test(arguments: [Tracking.visible, .recentlyClosed, .untracked])
    func replacingOwnedExportFromHistoryRelinquishesTrashOwnership(tracking: Tracking) async throws {
        var trashedOwnURL: URL?
        try await fixtureWithHistory(configure: { actions in
            actions.closed = { _ in }
            actions.moveToTrash = { item in
                trashedOwnURL = item.ownSavedURL
                if let ownSavedURL = item.ownSavedURL { try FileManager.default.removeItem(at: ownSavedURL) }
            }
        }) { cards, history, make in
            defer { cards.dismissAll() }
            let capture = try make()
            let folder = capture.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder.appending(path: "nested"), withIntermediateDirectories: false)
            let owned = URL(filePath: folder.path + "/nested/../replacement.png")
            let replacement = folder.appending(path: "replacement.png")
            try Data([1]).write(to: replacement)
            cards.add(capture)
            cards.markSaved(capture.id, at: owned, byCard: true)
            if tracking != .visible {
                cards.dismiss(capture.id)
                if tracking == .untracked { _ = cards.takeRecentlyClosed() }
            }
            cards.markSaved(capture.id, at: replacement)
            if tracking == .recentlyClosed {
                cards.restoreRecentlyClosed()
            } else if tracking == .untracked {
                cards.restore(try #require(history.item(id: capture.id)), on: 0)
            }

            let restored = try #require(cards.item(capture.id))
            #expect(restored.savedURL == replacement)
            #expect(restored.ownSavedURL == nil)
            cards.perform(.moveToTrash, on: restored, keyed: false)
            cards.finishTrashingNow()
            #expect(trashedOwnURL == nil)
            #expect(FileManager.default.fileExists(atPath: replacement.path))
        }
    }

    @Test(arguments: [false, true])
    func staleExternalExportKeepsCaptureUnsavedAndOnlyReleasesMatchingOwnership(replacesSameFile: Bool) async throws {
        var trashedOwnURL: URL?
        try await fixtureWithHistory(configure: { actions in
            actions.closed = { _ in }
            actions.moveToTrash = { item in
                trashedOwnURL = item.ownSavedURL
                if let ownSavedURL = item.ownSavedURL { try FileManager.default.removeItem(at: ownSavedURL) }
            }
        }) { cards, history, make in
            defer { cards.dismissAll() }
            let capture = try make()
            let folder = capture.fileURL.deletingLastPathComponent()
            let owned = folder.appending(path: "owned.png")
            try Data([1]).write(to: owned)
            var automatic = capture
            automatic.savedURL = owned
            automatic.ownSavedURL = owned
            cards.add(automatic)

            let failure = ExportFailure(cause: .diskFull, summary: "An earlier save failed", detail: "The disk is full.")
            #expect(cards.showFailure(failure, for: capture.id))

            let external: URL
            if replacesSameFile {
                let alias = folder.appending(path: "folder-alias")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
                external = alias.appending(path: owned.lastPathComponent)
            } else {
                external = folder.appending(path: "external.png")
            }

            let (startedEvents, announceStarted) = AsyncStream<Void>.makeStream()
            let startedReader = AsyncEventReader(startedEvents)
            let gate = AsyncSaveOutcomeGate()
            let exportTask = Task {
                announceStarted.yield(())
                let outcome = await gate.wait()
                if let destination = outcome.url {
                    cards.markSaved(capture.id, at: destination, isCurrent: false)
                }
            }
            guard await waitForEvent(from: startedReader) != nil else {
                await gate.complete(.cancelled)
                _ = await exportTask.value
                #expect(Bool(false), "The external export did not start")
                announceStarted.finish()
                return
            }

            let entry = try #require(history.item(id: capture.id))
            let edit = cards.pictureChanged(entry, savedCopyIsStale: true) { nil }
            await edit?.value
            #expect(cards.item(capture.id)?.savedURL == nil)
            #expect(cards.item(capture.id)?.ownSavedURL == owned)

            try Data([2]).write(to: external)
            await gate.complete(.saved(external))
            await exportTask.value
            announceStarted.finish()

            let card = try #require(cards.item(capture.id))
            #expect(card.savedURL == nil)
            #expect(card.ownSavedURL == (replacesSameFile ? nil : owned))
            #expect(cards.failure(for: capture.id) == failure)
            cards.perform(.moveToTrash, on: card, keyed: false)
            cards.finishTrashingNow()
            #expect(trashedOwnURL == (replacesSameFile ? nil : owned))
            #expect(FileManager.default.fileExists(atPath: external.path))
            #expect(FileManager.default.fileExists(atPath: owned.path) == replacesSameFile)
        }
    }

    @Test(arguments: [Tracking.visible, .recentlyClosed, .untracked])
    func staleExportOverwritingCurrentSavedCopyInvalidatesIt(tracking: Tracking) async throws {
        try await staleExportScenario(tracking: tracking, rewritesCurrentDestination: true)
    }

    @Test(arguments: [Tracking.visible, .recentlyClosed, .untracked])
    func staleExportAtDistinctPathPreservesCurrentSavedCopy(tracking: Tracking) async throws {
        try await staleExportScenario(tracking: tracking, rewritesCurrentDestination: false)
    }

    @Test func staleSamePathOverwriteSaveAndCloseExportsLatestHistoryBytes() async throws {
        let latestContents = Data([5, 6, 7])
        let (closedEvents, announceClosed) = AsyncStream<UUID>.makeStream()
        let closedReader = AsyncEventReader(closedEvents)
        var saves = 0
        var saveSource: URL?
        var sourceContents: Data?
        var finalExport: URL?
        var closedItem: QuickAccessItem?
        try await fixtureWithHistory(configure: { actions in
            actions.closed = { item in
                closedItem = item
                announceClosed.yield(item.id)
            }
            actions.preferences = { QuickAccessPreferences(closeAfter: 86_400, closeAction: .saveAndClose) }
            actions.save = { item, _ in
                saves += 1
                saveSource = item.fileURL
                sourceContents = try? Data(contentsOf: item.fileURL)
                let destination = item.fileURL.deletingLastPathComponent().appending(path: "save-and-close-latest.png")
                finalExport = destination
                return await AtomicFileCopy.save(item.fileURL, as: destination)
            }
        }) { cards, history, make in
            defer {
                cards.dismissAll()
                announceClosed.finish()
            }
            let capture = try make()
            cards.add(capture)
            let olderContents = try Data(contentsOf: capture.fileURL)
            let olderSource = capture.fileURL.deletingLastPathComponent().appending(path: "older-export-snapshot.png")
            try FileManager.default.copyItem(at: capture.fileURL, to: olderSource)

            let original = try #require(history.item(id: capture.id))
            let latest = try history.replacePicture(of: original, with: latestContents, pixelWidth: 1, pixelHeight: 1)
            if let update = cards.pictureChanged(latest, savedCopyIsStale: true, thumbnail: { make.thumbnail }) {
                await update.value
            }
            #expect(cards.item(capture.id)?.savedURL == nil)

            let folder = capture.fileURL.deletingLastPathComponent()
            let currentDestination = folder.appending(path: "current-export.png")
            let currentExport = await AtomicFileCopy.save(capture.fileURL, as: currentDestination)
            #expect(currentExport.url == currentDestination)
            #expect(try Data(contentsOf: currentDestination) == latestContents)
            cards.markSaved(capture.id, at: currentDestination)
            #expect(cards.item(capture.id)?.savedURL == currentDestination)

            let alias = folder.appending(path: "export-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
            let staleDestination = alias.appending(path: currentDestination.lastPathComponent)
            let staleExport = await AtomicFileCopy.save(olderSource, as: staleDestination)
            #expect(staleExport.url == staleDestination)
            #expect(try Data(contentsOf: staleDestination) == olderContents)
            cards.markSaved(capture.id, at: staleDestination, isCurrent: false)
            #expect(cards.item(capture.id)?.savedURL == nil)
            #expect(try Data(contentsOf: capture.fileURL) == latestContents)

            let card = try #require(
                cards.debugPanel?.contentView?.subviews.compactMap { $0 as? CaptureCardView }
                    .first(where: { $0.item.id == capture.id })
            )
            card.setHovering(false)
            cards.closeDueCards(at: .greatestFiniteMagnitude)
            let closedID = await waitForEvent(from: closedReader)
            #expect(closedID == capture.id)
            #expect(cards.item(capture.id) == nil)
            #expect(saves == 1)
            #expect(saveSource == capture.fileURL)
            #expect(sourceContents == latestContents)

            let finalExport = try #require(finalExport)
            #expect(try Data(contentsOf: finalExport) == latestContents)
            let closed = try #require(closedItem)
            #expect(closed.savedURL == finalExport)
            #expect(closed.ownSavedURL == finalExport)
            let persisted = try #require(history.item(id: capture.id))
            #expect(try Data(contentsOf: history.fileURL(for: persisted)) == latestContents)
        }
    }

    @Test func historyExportWithoutCardSeedsSavedStateOnRestore() async throws {
        var saves = 0
        let (closedEvents, announceClosed) = AsyncStream<UUID>.makeStream()
        let closedReader = AsyncEventReader(closedEvents)
        try await fixtureWithHistory(configure: { actions in
            actions.closed = { announceClosed.yield($0.id) }
            actions.preferences = { QuickAccessPreferences(closeAfter: 3, closeAction: .saveAndClose) }
            actions.save = { item, _ in
                saves += 1
                return .saved(item.fileURL)
            }
        }) { cards, history, make in
            defer { cards.dismissAll() }
            let capture = try make()
            let export = capture.fileURL.deletingLastPathComponent().appending(path: "history-export.png")
            cards.markSaved(capture.id, at: export)
            let entry = try #require(history.item(id: capture.id))
            cards.restore(entry, on: 0)
            #expect(cards.item(capture.id)?.savedURL == export)

            cards.closeDueCards(at: .greatestFiniteMagnitude)
            let closedID = await waitForEvent(from: closedReader)
            #expect(closedID == capture.id)
            #expect(cards.item(capture.id) == nil)
            #expect(saves == 0)
            announceClosed.finish()
        }
    }

    @Test func externalSaveBeforeFirstCardInsertionSeedsSavedState() async throws {
        try await fixtureWithHistory(configure: { $0.closed = { _ in } }) { cards, _, make in
            defer { cards.dismissAll() }
            let capture = try make()
            let external = capture.fileURL.deletingLastPathComponent().appending(path: "studio-export.mp4")
            cards.markSaved(capture.id, at: external)
            #expect(cards.item(capture.id) == nil)

            cards.add(capture)
            #expect(cards.item(capture.id)?.savedURL == external)
            #expect(cards.item(capture.id)?.ownSavedURL == nil)
        }
    }

    @Test(arguments: [false, true])
    func externalSaveBeforeCardInsertionPreservesOwnedExport(replacesSameFile: Bool) async throws {
        var trashedOwnURL: URL?
        try await fixtureWithHistory(configure: { actions in
            actions.closed = { _ in }
            actions.moveToTrash = { trashedOwnURL = $0.ownSavedURL }
        }) { cards, _, make in
            defer { cards.dismissAll() }
            let capture = try make()
            let folder = capture.fileURL.deletingLastPathComponent()
            let owned = folder.appending(path: "automatic-export.mp4")
            let external: URL
            if replacesSameFile {
                let alias = folder.appending(path: "folder-alias")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
                external = alias.appending(path: owned.lastPathComponent)
            } else {
                external = folder.appending(path: "studio-export.mp4")
            }
            try Data([2]).write(to: owned)
            if !replacesSameFile { try Data([3]).write(to: external) }

            cards.markSaved(capture.id, at: external)
            var automatic = capture
            automatic.savedURL = owned
            automatic.ownSavedURL = owned
            cards.add(automatic)

            let card = try #require(cards.item(capture.id))
            #expect(card.savedURL == external)
            #expect(card.ownSavedURL == (replacesSameFile ? nil : owned))
            cards.perform(.moveToTrash, on: card, keyed: false)
            cards.finishTrashingNow()
            #expect(trashedOwnURL == (replacesSameFile ? nil : owned))
            #expect(FileManager.default.fileExists(atPath: external.path))
        }
    }

    @Test func initialCardExportSurvivesRecentlyClosedEviction() async throws {
        try await fixtureWithHistory(configure: { $0.closed = { _ in } }) { cards, history, make in
            defer { cards.dismissAll() }
            var initial = try make()
            let export = initial.fileURL.deletingLastPathComponent().appending(path: "initial-export.png")
            initial.savedURL = export
            initial.ownSavedURL = export
            cards.maximumCards = 1
            cards.insertIntoStack(initial)
            for _ in 0..<22 { cards.insertIntoStack(try make()) }
            #expect(cards.item(initial.id) == nil)

            let entry = try #require(history.item(id: initial.id))
            cards.restore(entry, on: 0)
            #expect(cards.item(initial.id)?.savedURL == export)
            #expect(cards.item(initial.id)?.ownSavedURL == export)
        }
    }

    @Test(arguments: [false, true])
    func removalAndTrashClearSessionSavedMetadata(trash: Bool) async throws {
        try await fixtureWithHistory(configure: { actions in
            actions.closed = { _ in }
            actions.moveToTrash = { _ in }
        }) { cards, history, make in
            defer { cards.dismissAll() }
            let capture = try make()
            let export = capture.fileURL.deletingLastPathComponent().appending(path: "export.png")
            cards.markSaved(capture.id, at: export)
            let entry = try #require(history.item(id: capture.id))
            if trash {
                cards.restore(entry, on: 0)
                cards.perform(.moveToTrash, on: try #require(cards.item(capture.id)), keyed: false)
                cards.finishTrashingNow()
            } else {
                cards.remove(capture.id)
            }
            cards.restore(entry, on: 0)
            #expect(cards.item(capture.id)?.savedURL == nil)
        }
    }

    /// A copy that an edit put out of date while the capture had no card stays out of date, and a copy saved as a card
    /// comes for it again (a recording's first Studio movie, saved after it was made) is the one the card shows and owns.
    @Test func aCopySavedAsTheCardComesWinsOverAnOutOfDateOne() async throws {
        try await fixtureWithHistory(configure: { $0.closed = { _ in } }) { cards, history, make in
            var capture = try make()
            let folder = capture.fileURL.deletingLastPathComponent()
            let old = folder.appending(path: "old.png"), fresh = folder.appending(path: "fresh.png")
            capture.savedURL = old
            capture.ownSavedURL = old
            cards.insertIntoStack(capture)
            cards.dismiss(capture.id)
            _ = cards.takeRecentlyClosed()
            #expect(cards.pictureChanged(try #require(history.item(id: capture.id)), savedCopyIsStale: true) { nil } == nil)
            capture.savedURL = fresh
            capture.ownSavedURL = fresh
            cards.insertIntoStack(capture)
            let card = try #require(cards.item(capture.id))
            #expect(card.savedURL == fresh)
            #expect(card.ownSavedURL == fresh)
        }
    }

    /// The card's own file, saved over from the editor or Capture History under its name in another letter case, is the
    /// same file on a disk that ignores case: it is theirs now, and the card's Trash leaves it.
    @Test func aSaveOverTheCardsFileInAnotherLetterCaseEndsItsClaim() async throws {
        var trashed: QuickAccessItem?
        try await fixture(configure: { actions in
            actions.closed = { _ in }
            actions.moveToTrash = { trashed = $0 }
        }) { cards, make in
            let capture = try make()
            let folder = capture.fileURL.deletingLastPathComponent()
            guard try folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == false else { return }
            let owned = folder.appending(path: "Card.png"), replaced = folder.appending(path: "card.png")
            try Data([1]).write(to: owned)
            cards.insertIntoStack(capture)
            cards.markSaved(capture.id, at: owned, byCard: true)
            cards.markSaved(capture.id, at: replaced)
            let card = try #require(cards.item(capture.id))
            #expect(card.savedURL == replaced)
            #expect(card.ownSavedURL == nil)
            cards.perform(.moveToTrash, on: card, keyed: false)
            cards.finishTrashingNow()
            #expect(trashed?.id == capture.id)
            #expect(trashed?.ownSavedURL == nil)
        }
    }
}
