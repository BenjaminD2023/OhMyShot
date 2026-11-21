import AppKit
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
}
