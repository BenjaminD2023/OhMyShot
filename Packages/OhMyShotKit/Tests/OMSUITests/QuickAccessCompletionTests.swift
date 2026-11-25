import AppKit
import CoreGraphics
import Foundation
import OMSCore
import Testing
@testable import OMSUI

@MainActor
@Suite(.serialized)
struct QuickAccessCompletionTests {
    private func item() throws -> QuickAccessItem {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return QuickAccessItem(
            id: UUID(), fileURL: URL(filePath: "/tmp/completion.png"), thumbnail: try #require(context.makeImage()),
            pixelWidth: 1, pixelHeight: 1, displayID: 0
        )
    }

    private func actions(succeeds: Bool) -> QuickAccessController.Actions {
        var actions = QuickAccessController.Actions(
            copy: { _ in succeeds }, save: { _, _ in succeeds ? .saved(URL(filePath: "/tmp/saved.png")) : .cancelled },
            saveAs: { _ in succeeds ? .saved(URL(filePath: "/tmp/saved-as.png")) : .cancelled },
            open: { _ in }, annotate: { _ in }, reveal: { _ in }, recognizeText: { _ in },
            pin: { _ in succeeds }, moveToTrash: { _ in }, closed: { _ in }
        )
        actions.print = { _ in succeeds }
        return actions
    }

    @Test(arguments: [CardCommand.copy, .save, .saveAs, .pin, .print])
    func dismissesOnlyAfterSuccess(command: CardCommand) async throws {
        for succeeds in [false, true] {
            var actions = actions(succeeds: succeeds)
            var closed: [QuickAccessItem] = []
            actions.closed = { closed.append($0) }
            let controller = QuickAccessController(actions: actions)
            let capture = try item()
            controller.add(capture)
            controller.perform(command, on: capture, keyed: false)
            for _ in 0..<20 { await Task.yield() }
            if succeeds, command == .copy {
                #expect(controller.item(capture.id) != nil)
                #expect(closed.isEmpty)
                try await Task.sleep(for: .seconds(1.1))
            }
            #expect(controller.isEmpty == succeeds)
            #expect(closed.count == (succeeds ? 1 : 0))
            if succeeds, command == .save || command == .saveAs {
                #expect(closed.first?.savedURL != nil)
            }
            controller.dismissAll()
        }
    }

    @Test func copyLatestWaitsForClipboardBeforeClosing() async throws {
        var actions = actions(succeeds: true)
        var resume: CheckedContinuation<Bool, Never>?
        actions.copy = { _ in await withCheckedContinuation { resume = $0 } }
        let controller = QuickAccessController(actions: actions)
        let capture = try item()
        controller.add(capture)
        controller.copyLatest()
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.item(capture.id) != nil)
        let continuation = try #require(resume)
        continuation.resume(returning: true)
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.item(capture.id) != nil)
        try await Task.sleep(for: .seconds(1.1))
        #expect(controller.isEmpty)
    }

    @Test(arguments: [false, true])
    func copyConfirmsSuccessBeforeClosing(keyed: Bool) async throws {
        var actions = actions(succeeds: true)
        var resume: CheckedContinuation<Bool, Never>?
        var copies = 0
        actions.copy = { _ in
            copies += 1
            return await withCheckedContinuation { resume = $0 }
        }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        let card = try #require(controller.debugPanel?.contentView?.subviews.compactMap { $0 as? CaptureCardView }.first)
        card.setHovering(!keyed)
        let originalTitle = card.copyButton.title
        controller.perform(.copy, on: capture, keyed: keyed)
        for _ in 0..<20 { await Task.yield() }
        #expect(card.copyButton.title == originalTitle)
        let continuation = try #require(resume)
        continuation.resume(returning: true)
        for _ in 0..<20 { await Task.yield() }
        #expect(card.copyButton.title == String(localized: "Copied", bundle: .module))
        #expect(card.copyButton.symbolName == "checkmark")
        #expect(controller.item(capture.id) != nil)
        controller.perform(.copy, on: capture, keyed: keyed)
        try await Task.sleep(for: .milliseconds(400))
        #expect(copies == 1)
        #expect(controller.item(capture.id) != nil)
        try await Task.sleep(for: .milliseconds(700))
        #expect(controller.isEmpty)
    }

    /// Copy with Option (⌥⌘C, or Copy clicked with Option) says "Copied" as Copy does, and the card stays, to be
    /// copied again.
    @Test(arguments: [false, true])
    func copyWithOptionConfirmsAndKeepsTheCard(keyed: Bool) async throws {
        var actions = actions(succeeds: true)
        var copies = 0, closed = 0
        actions.copy = { _ in
            copies += 1
            return true
        }
        actions.closed = { _ in closed += 1 }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        let card = try #require(controller.debugPanel?.contentView?.subviews.compactMap { $0 as? CaptureCardView }.first)
        card.setHovering(!keyed)
        controller.perform(.copyAndKeep, on: capture, keyed: keyed)
        for _ in 0..<20 { await Task.yield() }
        #expect(copies == 1)
        #expect(card.copyButton.title == String(localized: "Copied", bundle: .module))
        try await Task.sleep(for: .seconds(1.1))
        #expect(controller.item(capture.id) != nil)
        #expect(closed == 0)
        controller.perform(.copyAndKeep, on: capture, keyed: keyed)
        for _ in 0..<20 { await Task.yield() }
        #expect(copies == 2)
    }

    @Test func failedCopyDoesNotConfirmAndCanBeRetried() async throws {
        var actions = actions(succeeds: false)
        var succeeds = false
        actions.copy = { _ in succeeds }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        let card = try #require(controller.debugPanel?.contentView?.subviews.compactMap { $0 as? CaptureCardView }.first)
        let originalTitle = card.copyButton.title
        controller.copyLatest()
        for _ in 0..<20 { await Task.yield() }
        #expect(card.copyButton.title == originalTitle)
        #expect(controller.item(capture.id) != nil)
        succeeds = true
        controller.copyLatest()
        for _ in 0..<20 { await Task.yield() }
        #expect(card.copyButton.symbolName == "checkmark")
        try await Task.sleep(for: .seconds(1.1))
        #expect(controller.isEmpty)
    }

    @Test(arguments: [false, true])
    func oldCopyConfirmationDoesNotCloseRestoredCard(trashed: Bool) async throws {
        let controller = QuickAccessController(actions: actions(succeeds: true))
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        controller.copyLatest()
        for _ in 0..<20 { await Task.yield() }
        if trashed {
            controller.perform(.moveToTrash, on: capture, keyed: false)
            #expect(controller.undoTrash(capture.id))
        } else {
            controller.dismiss(capture.id)
            controller.add(capture)
        }
        try await Task.sleep(for: .seconds(1.1))
        #expect(controller.item(capture.id) != nil)
    }

    @Test func saveAllClosesSavedCardsAndKeepsFailures() async throws {
        var actions = actions(succeeds: true)
        let successful = try item(), failed = try item()
        actions.save = { item, asks in
            #expect(!asks)
            return item.id == successful.id ? .saved(URL(filePath: "/tmp/saved.png")) : .failed(Self.diskFull)
        }
        let controller = QuickAccessController(actions: actions)
        controller.add(successful)
        controller.add(failed)
        controller.saveAll()
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.itemIDs == [failed.id])
        controller.dismissAll()
    }

    @Test func saveAllUsesCurrentStateAfterAnEarlierSaveWaits() async throws {
        let first = try item(), savedElsewhere = try item(), removed = try item(), trashing = try item()
        let (startedEvents, announceStarted) = AsyncStream<Void>.makeStream()
        let (closedEvents, announceClosed) = AsyncStream<UUID>.makeStream()
        let startedReader = AsyncEventReader(startedEvents)
        let closedReader = AsyncEventReader(closedEvents)
        var resumeFirstSave: CheckedContinuation<SaveOutcome, Never>?
        var savedIDs: [UUID] = []
        var configured = actions(succeeds: true)
        configured.closed = { announceClosed.yield($0.id) }
        configured.save = { item, _ in
            savedIDs.append(item.id)
            if item.id == first.id {
                return await withCheckedContinuation { continuation in
                    resumeFirstSave = continuation
                    announceStarted.yield(())
                }
            }
            return .saved(item.fileURL)
        }
        let controller = QuickAccessController(actions: configured)
        controller.maximumCards = 4
        defer {
            if let continuation = resumeFirstSave {
                resumeFirstSave = nil
                continuation.resume(returning: .cancelled)
            }
            controller.undoTrash(trashing.id)
            controller.dismissAll()
            announceStarted.finish()
            announceClosed.finish()
        }
        [first, savedElsewhere, removed, trashing].forEach { controller.add($0) }
        controller.saveAll()
        guard let _ = await waitForEvent(from: startedReader) else {
            #expect(Bool(false), "Timed out waiting for Save All to start")
            return
        }

        controller.markSaved(savedElsewhere.id, at: URL(filePath: "/tmp/history-export.png"))
        controller.remove(removed.id)
        controller.perform(.moveToTrash, on: trashing, keyed: false)
        let continuation = try #require(resumeFirstSave)
        resumeFirstSave = nil
        continuation.resume(returning: .saved(URL(filePath: "/tmp/first-export.png")))
        guard let firstClosed = await waitForEvent(from: closedReader), let nextClosed = await waitForEvent(from: closedReader) else {
            #expect(Bool(false), "Timed out waiting for Save All cards to close")
            return
        }

        #expect(firstClosed == first.id)
        #expect(nextClosed == savedElsewhere.id)
        #expect(savedIDs == [first.id])
        #expect(controller.item(savedElsewhere.id) == nil)
        #expect(controller.item(removed.id) == nil)
        #expect(controller.item(trashing.id) != nil)
    }

    private static let diskFull = ExportFailure(cause: .diskFull, summary: "Couldn’t save: the disk is full", detail: "The disk is full.")

    private func card(in controller: QuickAccessController) throws -> CaptureCardView {
        try #require(controller.debugPanel?.contentView?.subviews.compactMap { $0 as? CaptureCardView }.first)
    }

    @Test(arguments: [CardCommand.save, .saveAs])
    func failedSaveSaysWhyAndHoldsTheCardUntilASaveWorks(command: CardCommand) async throws {
        var actions = actions(succeeds: false)
        var outcome = SaveOutcome.failed(Self.diskFull)
        actions.save = { _, _ in outcome }
        actions.saveAs = { _ in outcome }
        actions.preferences = { QuickAccessPreferences(closeAfter: 3) }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        controller.perform(command, on: capture, keyed: false)
        for _ in 0..<20 { await Task.yield() }
        let card = try card(in: controller)
        #expect(card.failure == Self.diskFull)
        #expect(card.accessibilityValue() as? String == Self.diskFull.summary)
        #expect(card.saveButton.toolTip == Self.diskFull.detail)
        // Long past its time, the card is still held.
        controller.closeDueCards(at: ProcessInfo.processInfo.systemUptime + 3600)
        #expect(controller.item(capture.id) != nil)

        outcome = .saved(URL(filePath: "/tmp/saved.png"))
        controller.perform(command, on: capture, keyed: false)
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.isEmpty)
    }

    @Test func aCancelledSaveIsNoFailure() async throws {
        var actions = actions(succeeds: false)
        actions.preferences = { QuickAccessPreferences(closeAfter: 3) }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        controller.perform(.save, on: capture, keyed: false)
        for _ in 0..<20 { await Task.yield() }
        #expect(try card(in: controller).failure == nil)
        controller.closeDueCards(at: ProcessInfo.processInfo.systemUptime + 3600)
        #expect(controller.isEmpty)
    }

    private static let cannotPrepare = ExportFailure(
        step: .converting, cause: .diskFull, summary: "Couldn’t prepare the picture: the disk is full", detail: "The disk is full."
    )

    @Test func aCopyToHandOverThatCannotBeMadeLeavesNothingAndSaysWhy() throws {
        var actions = actions(succeeds: true)
        var handOver = Result<URL, ExportFailure>.failure(Self.cannotPrepare)
        actions.fileToHandOver = { _ in handOver }
        actions.preferences = { QuickAccessPreferences(closeAfter: 3) }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        let card = try card(in: controller)
        let fileToHandOver = try #require(card.fileToHandOver)
        // Not the capture's own file in its place: nothing at all.
        #expect(fileToHandOver() == nil)
        #expect(card.failure == Self.cannotPrepare)
        controller.closeDueCards(at: ProcessInfo.processInfo.systemUptime + 3600)
        #expect(controller.item(capture.id) != nil)
        // Made after all: the card no longer says it, and closes in its time.
        let converted = URL(filePath: "/tmp/converted.jpg")
        handOver = .success(converted)
        #expect(fileToHandOver() == converted)
        #expect(card.failure == nil)
        controller.closeDueCards(at: ProcessInfo.processInfo.systemUptime + 3600)
        #expect(controller.isEmpty)
    }

    @Test func aCopyHandedOverLeavesAFailedSaveSaid() throws {
        let controller = QuickAccessController(actions: actions(succeeds: true))
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        controller.showFailure(Self.diskFull, for: capture.id)
        let card = try card(in: controller)
        #expect(card.fileToHandOver?() == capture.fileURL)
        #expect(card.failure == Self.diskFull)
    }

    /// A copy to hand over that can't be made while the card says a copy couldn't be saved is said by the pointer, and the
    /// save's failure stays on the card and holds it, through a later hand-over that works (which saves nothing).
    @Test func aFailedHandOverNeverTakesTheCardFromAFailedSave() throws {
        var actions = actions(succeeds: true)
        actions.preferences = { QuickAccessPreferences(closeAfter: 3) }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        #expect(controller.showFailure(Self.diskFull, for: capture.id))
        #expect(!controller.showFailure(Self.cannotPrepare, for: capture.id))
        let card = try card(in: controller)
        #expect(card.failure == Self.diskFull)
        #expect(card.fileToHandOver?() == capture.fileURL)
        controller.clearHandOverFailure(for: capture.id)
        #expect(card.failure == Self.diskFull)
        controller.closeDueCards(at: ProcessInfo.processInfo.systemUptime + 3600)
        #expect(controller.item(capture.id) != nil)
    }

    /// A drag, Share…, or Send by Email whose copy can't be made while the card says a save failed says why by the pointer,
    /// rather than nothing at all.
    @Test func aFailedHandOverUnderAFailedSaveIsSaidByThePointer() throws {
        var actions = actions(succeeds: true)
        actions.fileToHandOver = { _ in .failure(Self.cannotPrepare) }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        var said: [String] = []
        controller.showHandOverFailure = { said.append($0) }
        let capture = try item()
        controller.add(capture)
        #expect(controller.showFailure(Self.diskFull, for: capture.id))
        let card = try card(in: controller)
        #expect(card.fileToHandOver?() == nil)
        #expect(said == [Self.cannotPrepare.summary])
        #expect(card.failure == Self.diskFull)
    }

    /// An upload whose copy is made after all clears the card's earlier failure to make one.
    @Test func aCopyMadeForAnUploadClearsAFailureToMakeOne() throws {
        let controller = QuickAccessController(actions: actions(succeeds: true))
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        #expect(controller.showFailure(Self.cannotPrepare, for: capture.id))
        controller.clearHandOverFailure(for: capture.id)
        #expect(try card(in: controller).failure == nil)
    }

    @Test func aFailureIsShownOnlyOnACardOnScreen() throws {
        let controller = QuickAccessController(actions: actions(succeeds: true))
        defer { controller.dismissAll() }
        let capture = try item()
        #expect(!controller.showFailure(Self.diskFull, for: capture.id))
        controller.add(capture)
        #expect(controller.showFailure(Self.diskFull, for: capture.id))
        controller.markSaved(capture.id, at: URL(filePath: "/tmp/saved.png"))
        #expect(try card(in: controller).failure == nil)
    }

    /// A capture saved from Capture History (or the editor) while its card is up is not saved again when the card closes by
    /// itself with Save and Close: the card goes with the copy saved there, and none of its own.
    @Test func saveAndCloseSavesNoSecondCopyOfACaptureSavedElsewhere() async throws {
        var actions = actions(succeeds: true)
        var saves = 0
        actions.save = { _, _ in
            saves += 1
            return .saved(URL(filePath: "/tmp/saved.png"))
        }
        actions.preferences = { QuickAccessPreferences(closeAfter: 3, closeAction: .saveAndClose) }
        var closed: [QuickAccessItem] = []
        actions.closed = { closed.append($0) }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item(), export = URL(filePath: "/tmp/history-export.png")
        controller.add(capture)
        controller.markSaved(capture.id, at: export)
        controller.closeDueCards(at: ProcessInfo.processInfo.systemUptime + 3600)
        for _ in 0..<20 { await Task.yield() }
        #expect(saves == 0)
        #expect(closed.map(\.id) == [capture.id])
        #expect(closed.first?.savedURL == export)
        #expect(closed.first?.ownSavedURL == nil)
    }

    /// Moved to the Trash and brought back, a card whose copy could not be saved still says so and is still held.
    @Test func aCardThatFailedToSaveIsStillHeldAfterUndoingTheTrash() async throws {
        var actions = actions(succeeds: false)
        actions.save = { _, _ in .failed(Self.diskFull) }
        actions.preferences = { QuickAccessPreferences(closeAfter: 3) }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        controller.perform(.save, on: capture, keyed: false)
        for _ in 0..<20 { await Task.yield() }
        controller.perform(.moveToTrash, on: capture, keyed: false)
        #expect(controller.undoTrash(capture.id))
        controller.closeDueCards(at: ProcessInfo.processInfo.systemUptime + 3600)
        #expect(controller.item(capture.id) != nil)
        #expect(try card(in: controller).failure == Self.diskFull)
    }

    /// A card that failed to save and then went to the Trash leaves nothing of its failure behind.
    @Test func aCardSentToTheTrashTakesItsFailureWithIt() throws {
        let controller = QuickAccessController(actions: actions(succeeds: true))
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        #expect(controller.showFailure(Self.diskFull, for: capture.id))
        controller.perform(.moveToTrash, on: capture, keyed: false)
        controller.finishTrashingNow()
        #expect(controller.isEmpty)
        #expect(controller.failure(for: capture.id) == nil)
    }

    @Test func trashFailureLeavesTheCardAvailableForRetry() throws {
        var actions = actions(succeeds: true)
        var attempts = 0
        actions.moveToTrash = { _ in
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileWriteNoPermission) }
        }
        let controller = QuickAccessController(actions: actions), capture = try item()
        var notices: [String] = []
        controller.showTrashFailure = { notices.append($0) }
        controller.insertIntoStack(capture)
        controller.perform(.moveToTrash, on: capture, keyed: false)
        controller.finishTrashingNow()
        #expect(controller.itemIDs == [capture.id])
        #expect(notices.count == 1)
        controller.perform(.moveToTrash, on: capture, keyed: false)
        controller.finishTrashingNow()
        #expect(controller.isEmpty)
        #expect(attempts == 2)
    }

    @Test func anEditorOpenedDuringTrashUndoProtectsTheCapture() throws {
        var actions = actions(succeeds: true)
        var editing = false
        actions.isBeingEdited = { _ in editing }
        var attempts = 0
        actions.moveToTrash = { _ in attempts += 1 }
        let controller = QuickAccessController(actions: actions), capture = try item()
        var notices: [String] = []
        controller.showTrashFailure = { notices.append($0) }
        controller.insertIntoStack(capture)
        controller.perform(.moveToTrash, on: capture, keyed: false)
        editing = true
        controller.finishTrashingNow()
        controller.perform(.moveToTrash, on: capture, keyed: false)
        #expect(!controller.undoTrash())
        #expect(controller.itemIDs == [capture.id])
        #expect(attempts == 0 && notices.count == 2)
    }

    @Test func copyLinkNeedsALinkAndEditingKeepsTheCard() throws {
        var actions = actions(succeeds: true)
        var hasLink = false
        actions.sharing.hasLink = { _ in hasLink }
        let controller = QuickAccessController(actions: actions)
        let capture = try item()
        controller.add(capture)
        controller.perform(.copyLink, on: capture, keyed: false)
        #expect(!controller.isEmpty)
        controller.perform(.annotate, on: capture, keyed: false)
        #expect(!controller.isEmpty)
        hasLink = true
        controller.perform(.copyLink, on: capture, keyed: false)
        #expect(controller.isEmpty)
    }

    /// Copy clicked sends Copy to the card's controller, and with Option held, Copy that keeps the card.
    @Test func copyClickedWithOptionKeepsTheCard() throws {
        let controller = QuickAccessController(actions: actions(succeeds: true))
        defer { controller.dismissAll() }
        controller.add(try item())
        let card = try #require(controller.debugPanel?.contentView?.subviews.compactMap { $0 as? CaptureCardView }.first)
        var sent: [CardCommand] = []
        card.onCommand = { sent.append($0) }
        let button = card.copyButton
        #expect(button.sendAction(button.action, to: button.target))
        #expect(sent == [.copy])
        #expect(CaptureCardView.copyCommand(with: .option) == .copyAndKeep)
        #expect(CaptureCardView.copyCommand(with: [.option, .shift]) == .copyAndKeep)
        #expect(CaptureCardView.copyCommand(with: .command) == .copy)
    }

    /// ⌥⌘C leaves the keyboard on the card, to be copied again or used further; ⌘C gives it back to the app in front.
    @Test(arguments: [(CardCommand.copyAndKeep, true), (.copy, false)])
    func copyWithOptionKeepsTheKeyboard(command: CardCommand, keepsKeyboard: Bool) throws {
        let controller = QuickAccessController(actions: actions(succeeds: true))
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        let card = try #require(controller.debugPanel?.contentView?.subviews.compactMap { $0 as? CaptureCardView }.first)
        controller.focusLatest()
        #expect(card.isSelected)
        controller.perform(command, on: capture, keyed: true)
        #expect(card.isSelected == keepsKeyboard)
    }

    @Test func keepsCardOpenAfterActionsWhenClosesAfterActionIsOff() async throws {
        var actions = actions(succeeds: true)
        actions.preferences = { QuickAccessPreferences(closesAfterAction: false) }
        actions.sharing.hasLink = { _ in true }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        let card = try #require(controller.debugPanel?.contentView?.subviews.compactMap { $0 as? CaptureCardView }.first)

        controller.perform(.copy, on: capture, keyed: false)
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.item(capture.id) != nil)
        #expect(card.copyButton.title == String(localized: "Copied", bundle: .module))

        controller.perform(.save, on: capture, keyed: false)
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.item(capture.id)?.savedURL != nil)
        #expect(card.saveButton.title == String(localized: "Saved", bundle: .module))

        controller.perform(.pin, on: capture, keyed: false)
        controller.perform(.copyLink, on: capture, keyed: false)
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.item(capture.id) != nil)
    }

    @Test func multiCardScreenshotMenuOffersCollagePDFAndClearRevealLabels() throws {
        var actions = actions(succeeds: true)
        var combinedCount = 0
        var pdfCount = 0
        actions.combineIntoCollage = { combinedCount = $0.count }
        actions.exportAsPDF = { pdfCount = $0.count }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }

        let first = try item()
        controller.add(first)
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let firstCard = try #require(controller.debugPanel?.contentView?.subviews.compactMap { $0 as? CaptureCardView }.first)
        let singleTitles = try #require(firstCard.menu(for: click)).items.map(\.title)
        #expect(singleTitles.contains("Show Original in Finder"))
        #expect(!singleTitles.contains("Combine All into Collage…"))
        #expect(!singleTitles.contains("Export All as PDF…"))

        controller.markSaved(first.id, at: URL(filePath: "/tmp/saved.png"))
        let savedTitles = try #require(firstCard.menu(for: click)).items.map(\.title)
        #expect(savedTitles.contains("Show in Finder"))

        let second = try item()
        controller.add(second)
        let multiMenu = try #require(firstCard.menu(for: click))
        let multiTitles = multiMenu.items.map(\.title)
        #expect(multiTitles.contains("Combine All into Collage…"))
        #expect(multiTitles.contains("Export All as PDF…"))
        if let collageItem = multiMenu.items.first(where: { $0.title == "Combine All into Collage…" }) {
            _ = collageItem.target?.perform(collageItem.action, with: collageItem)
        }
        if let pdfItem = multiMenu.items.first(where: { $0.title == "Export All as PDF…" }) {
            _ = pdfItem.target?.perform(pdfItem.action, with: pdfItem)
        }
        #expect(combinedCount == 2)
        #expect(pdfCount == 2)
    }

    @Test func preferencesChangedUpdatesCountdownAndCornerLive() throws {
        var prefs = QuickAccessPreferences(corner: .bottomLeft, size: .medium, closeAfter: 10)
        var actions = actions(succeeds: true)
        actions.preferences = { prefs }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        let card = try #require(controller.debugPanel?.contentView?.subviews.compactMap { $0 as? CaptureCardView }.first)
        #expect(card.isCountdownRingVisible)

        prefs = QuickAccessPreferences(corner: .topRight, size: .large, closeAfter: 0)
        controller.preferencesChanged()
        #expect(!card.isCountdownRingVisible)
    }

    @Test func countdownRingFreezesOnHoverAndResumesWithoutJumpingBackward() throws {
        var now: TimeInterval = 100
        var actions = actions(succeeds: true)
        actions.preferences = { QuickAccessPreferences(corner: .bottomLeft, size: .medium, closeAfter: 10) }
        let controller = QuickAccessController(actions: actions)
        controller.clock = { now }
        defer { controller.dismissAll() }

        let capture = try item()
        controller.add(capture)
        let card = try #require(controller.debugPanel?.contentView?.subviews.compactMap { $0 as? CaptureCardView }.first)
        #expect(card.isCountdownRingVisible)
        #expect(!card.isCountdownRingPaused)

        // Advance 7 seconds out of 10 (30% remaining) and hover to freeze the ring in place.
        now = 107
        card.setHovering(true)
        #expect(card.isCountdownRingVisible)
        #expect(card.isCountdownRingPaused)
        #expect(abs(card.countdownRingFraction - 0.3) < 0.02)

        // Leave hover after 5 seconds: grace extends remaining time, yet visual ring never jumps backward.
        now = 112
        card.setHovering(false)
        #expect(card.isCountdownRingVisible)
        #expect(!card.isCountdownRingPaused)
        if case .running(_, _, let startFraction) = card.countdownDisplay {
            let start = try #require(startFraction)
            #expect(start <= 0.31)
        } else {
            Issue.record("Expected running countdown display after hover exit")
        }
    }

    @Test func clickingSavedRevealsInFinderWithoutDismissingCard() throws {
        var actions = actions(succeeds: true)
        var revealed: [UUID] = []
        var saveCalls = 0
        actions.reveal = { revealed.append($0.id) }
        actions.save = { _, _ in
            saveCalls += 1
            return .saved(URL(filePath: "/tmp/should-not-save-again.png"))
        }
        actions.preferences = { QuickAccessPreferences(closesAfterAction: true) }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }

        let capture = try item()
        controller.add(capture)
        controller.markSaved(capture.id, at: URL(filePath: "/tmp/already-saved.png"))
        controller.perform(.save, on: capture, keyed: false)

        #expect(revealed == [capture.id])
        #expect(saveCalls == 0)
        #expect(controller.item(capture.id) != nil)
    }

    @Test func recentlyClosedPrunesDeletedFilesAndClearsMissingSavedCopy() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "QuickAccessFreshness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let aliveURL = dir.appending(path: "alive.png")
        let deletedURL = dir.appending(path: "deleted.png")
        let missingSavedURL = dir.appending(path: "gone-saved.png")
        try Data([1, 2, 3]).write(to: aliveURL)
        try Data([4, 5, 6]).write(to: deletedURL)

        let base = try item()
        let alive = QuickAccessItem(
            id: UUID(), kind: .screenshot, fileURL: aliveURL, thumbnail: base.thumbnail,
            pixelWidth: 1, pixelHeight: 1, displayID: 0, savedURL: missingSavedURL
        )
        let deleted = QuickAccessItem(
            id: UUID(), kind: .screenshot, fileURL: deletedURL, thumbnail: base.thumbnail,
            pixelWidth: 1, pixelHeight: 1, displayID: 0
        )

        let controller = QuickAccessController(actions: actions(succeeds: true))
        defer { controller.dismissAll() }
        controller.add(alive)
        controller.add(deleted)
        controller.dismiss(alive.id)
        controller.dismiss(deleted.id)
        #expect(controller.isEmpty)

        // Delete the newest closed file from disk; restoring must skip it and restore the surviving card.
        try FileManager.default.removeItem(at: deletedURL)
        #expect(controller.hasRecentlyClosed)
        controller.restoreRecentlyClosed()
        #expect(controller.itemIDs == [alive.id])
        #expect(controller.item(alive.id)?.savedURL == nil)

        // Once the remaining file is also gone from disk, hasRecentlyClosed reports false and restore does nothing.
        controller.dismiss(alive.id)
        try FileManager.default.removeItem(at: aliveURL)
        #expect(!controller.hasRecentlyClosed)
        controller.restoreRecentlyClosed()
        #expect(controller.isEmpty)
    }

    @Test func translateMenuItemAppearsOnScreenshotsAndNotRecordings() throws {
        let controller = QuickAccessController(actions: actions(succeeds: true))
        defer { controller.dismissAll() }
        var translated: [UUID] = []
        controller.onTranslate = { translated.append($0.id) }

        let screenshot = try item()
        let recording = QuickAccessItem(
            id: UUID(), kind: .recording, fileURL: URL(filePath: "/tmp/clip.mp4"),
            thumbnail: screenshot.thumbnail, pixelWidth: 100, pixelHeight: 100, displayID: 0, duration: 5
        )
        controller.add(screenshot)
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let shotCard = try #require(controller.debugPanel?.contentView?.subviews.compactMap { $0 as? CaptureCardView }.first)
        let shotMenu = try #require(shotCard.menu(for: click))
        let translateItem = try #require(shotMenu.items.first { $0.title == "Translate…" })
        _ = translateItem.target?.perform(translateItem.action, with: translateItem)
        #expect(translated == [screenshot.id])

        controller.dismissAll()
        controller.add(recording)
        let recCard = try #require(
            controller.debugPanel?.contentView?.subviews.compactMap { $0 as? CaptureCardView }.first { $0.item.id == recording.id }
        )
        let recMenu = try #require(recCard.menu(for: click))
        #expect(!recMenu.items.contains { $0.title == "Translate…" })
    }
}
