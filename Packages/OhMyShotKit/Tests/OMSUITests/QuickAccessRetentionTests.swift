import CoreGraphics
import Foundation
import OMSCore
import Testing
@testable import OMSUI

@MainActor
struct QuickAccessRetentionTests {
    private func fixture(
        configure: (inout QuickAccessController.Actions) -> Void = { _ in },
        _ run: (QuickAccessController, () throws -> QuickAccessItem) async throws -> Void
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
            copy: { _ in false }, save: { _, _ in nil }, saveAs: { _ in nil },
            open: { _ in }, annotate: { _ in }, reveal: { _ in }, recognizeText: { _ in },
            pin: { _ in false }, moveToTrash: { _ in }, closed: { item in
                #expect(throws: Never.self) { try FileManager.default.removeItem(at: item.fileURL) }
            }
        )
        configure(&actions)
        try await run(QuickAccessController(actions: actions, history: history)) {
            let entry = try history.add(data: Data([0]), name: UUID().uuidString, fileExtension: "png", kind: .screenshot,
                                        pixelWidth: 1, pixelHeight: 1, appName: nil)
            return QuickAccessItem(entry, fileURL: history.fileURL(for: entry), thumbnail: thumbnail, displayID: 0)
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
            actions.moveToTrash = { trashedCopy = $0.savedURL }
        }) { cards, make in
            let old = try make(), newer = try make()
            let folder = old.fileURL.deletingLastPathComponent(), export = folder.appending(path: "edited.png")
            cards.maximumCards = 1
            cards.insertIntoStack(old)
            cards.markSaved(old.id, at: folder.appending(path: "previous.png"))
            cards.insertIntoStack(newer)
            cards.markSaved(old.id, at: export)
            cards.insertIntoStack(try #require(cards.takeRecentlyClosed()))
            let restored = try #require(cards.item(old.id))
            cards.perform(.reveal, on: restored, keyed: false)
            cards.perform(.moveToTrash, on: restored, keyed: false)
            cards.finishTrashingNow()
            #expect(revealed == export)
            #expect(trashedCopy == export)
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
}
