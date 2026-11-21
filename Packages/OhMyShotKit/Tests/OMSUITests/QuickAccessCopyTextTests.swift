import AppKit
import OMSCore
import Testing
@testable import OMSUI

/// Copy Text on a Quick Access card: the card says what it copied, and stays.
@MainActor
@Suite(.serialized)
struct QuickAccessCopyTextTests {
    private func item() throws -> QuickAccessItem {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return QuickAccessItem(
            id: UUID(), fileURL: URL(filePath: "/tmp/copy-text.png"), thumbnail: try #require(context.makeImage()),
            pixelWidth: 1, pixelHeight: 1, displayID: 0
        )
    }

    private func actions() -> QuickAccessController.Actions {
        QuickAccessController.Actions(
            copy: { _ in true }, save: { _, _ in nil }, saveAs: { _ in nil },
            open: { _ in }, annotate: { _ in }, reveal: { _ in }, recognizeText: { _ in },
            pin: { _ in false }, moveToTrash: { _ in }, closed: { _ in }
        )
    }

    private func card(of controller: QuickAccessController) throws -> CaptureCardView {
        try #require(controller.debugPanel?.contentView?.subviews.compactMap { $0 as? CaptureCardView }.first)
    }

    @Test(arguments: [TextCopy.copied(characters: 42), .noText], [false, true])
    func theCardSaysWhatItCopiedAndStays(copy: TextCopy, keyed: Bool) async throws {
        var actions = actions()
        var closed = 0
        actions.closed = { _ in closed += 1 }
        actions.copyText = { _ in copy }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        let card = try card(of: controller)
        card.setHovering(!keyed)
        controller.perform(.copyText, on: capture, keyed: keyed)
        for _ in 0..<20 { await Task.yield() }
        #expect(card.notice != nil)
        #expect(card.notice == copy.message)
        try await Task.sleep(for: .seconds(1.1))
        #expect(controller.item(capture.id) != nil)
        #expect(closed == 0)
    }

    /// A reading another copy overtook says nothing.
    @Test func anOvertakenCopyTextSaysNothing() async throws {
        var actions = actions()
        actions.copyText = { _ in .superseded }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        controller.perform(.copyText, on: capture, keyed: false)
        for _ in 0..<20 { await Task.yield() }
        #expect(try card(of: controller).notice == nil)
        #expect(controller.item(capture.id) != nil)
    }

    /// Asked again before the first reading ends, the card says only what the newer one came to.
    @Test func onlyTheLastCopyTextOnACardIsSaid() async throws {
        var actions = actions()
        var resumes: [CheckedContinuation<TextCopy, Never>] = []
        actions.copyText = { _ in await withCheckedContinuation { resumes.append($0) } }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        let card = try card(of: controller)
        controller.perform(.copyText, on: capture, keyed: false)
        controller.perform(.copyText, on: capture, keyed: false)
        for _ in 0..<20 { await Task.yield() }
        try #require(resumes.count == 2)
        resumes[1].resume(returning: .noText)
        for _ in 0..<20 { await Task.yield() }
        #expect(card.notice == TextCopy.noText.message)
        resumes[0].resume(returning: .copied(characters: 3))
        for _ in 0..<20 { await Task.yield() }
        #expect(card.notice == TextCopy.noText.message)
    }

    /// A card closing by itself waits while its text is read, and goes once it has been.
    @Test func aCardIsNotClosedByItselfWhileItsTextIsRead() async throws {
        var actions = actions()
        var resume: CheckedContinuation<TextCopy, Never>?
        actions.copyText = { _ in await withCheckedContinuation { resume = $0 } }
        actions.preferences = { QuickAccessPreferences(closeAfter: 3, closeAction: .close) }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        controller.perform(.copyText, on: capture, keyed: false)
        for _ in 0..<20 { await Task.yield() }
        controller.closeDueCards(at: .greatestFiniteMagnitude)
        #expect(controller.item(capture.id) != nil)
        try #require(resume).resume(returning: .copied(characters: 1))
        for _ in 0..<20 { await Task.yield() }
        controller.closeDueCards(at: .greatestFiniteMagnitude)
        #expect(controller.item(capture.id) == nil)
    }

    /// Moved to the Trash and brought back while its text is read, a card is held again until the reading ends, and
    /// then says what it copied.
    @Test func aCardBroughtBackFromTheTrashWaitsForItsReading() async throws {
        var actions = actions()
        var resume: CheckedContinuation<TextCopy, Never>?
        actions.copyText = { _ in await withCheckedContinuation { resume = $0 } }
        actions.preferences = { QuickAccessPreferences(closeAfter: 3, closeAction: .close) }
        let controller = QuickAccessController(actions: actions)
        defer { controller.dismissAll() }
        let capture = try item()
        controller.add(capture)
        controller.perform(.copyText, on: capture, keyed: false)
        for _ in 0..<20 { await Task.yield() }
        controller.perform(.moveToTrash, on: capture, keyed: false)
        #expect(controller.undoTrash(capture.id))
        // Brought back, the card asks where the pointer is; one resting where the card stands would hold it too.
        try card(of: controller).setHovering(false)
        controller.closeDueCards(at: .greatestFiniteMagnitude)
        #expect(controller.item(capture.id) != nil)
        try #require(resume).resume(returning: .copied(characters: 1))
        for _ in 0..<20 { await Task.yield() }
        #expect(try card(of: controller).notice == TextCopy.copied(characters: 1).message)
        controller.closeDueCards(at: .greatestFiniteMagnitude)
        #expect(controller.item(capture.id) == nil)
    }
}
