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
            copy: { _ in succeeds }, save: { _, _ in succeeds ? URL(filePath: "/tmp/saved.png") : nil },
            saveAs: { _ in succeeds ? URL(filePath: "/tmp/saved-as.png") : nil },
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
        #expect(controller.isEmpty)
    }

    @Test func saveAllClosesSavedCardsAndKeepsFailures() async throws {
        var actions = actions(succeeds: true)
        let successful = try item(), failed = try item()
        actions.save = { item, asks in
            #expect(!asks)
            return item.id == successful.id ? URL(filePath: "/tmp/saved.png") : nil
        }
        let controller = QuickAccessController(actions: actions)
        controller.add(successful)
        controller.add(failed)
        controller.saveAll()
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.itemIDs == [failed.id])
        controller.dismissAll()
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
}
