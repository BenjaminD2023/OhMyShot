import AppKit
import Foundation
import Testing
@testable import OMSUI

/// Copy Text puts a picture's text on the clipboard, unless something was copied after it began.
@MainActor
struct TextCopierTests {
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("TextCopierTests-\(UUID().uuidString)"))
    private let picture = URL(filePath: "/tmp/copy-text.png")

    @Test func theTextGoesToTheClipboardAndIsCounted() async {
        let copier = TextCopier(pasteboard: pasteboard) { _ in "Hello,\nworld" }
        #expect(await copier.copyText(ofPictureAt: picture) == .copied(characters: 12))
        #expect(pasteboard.string(forType: .string) == "Hello,\nworld")
    }

    @Test(arguments: [nil, "", " \n "] as [String?])
    func aPictureWithoutTextLeavesTheClipboardAsItWas(text: String?) async {
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let copier = TextCopier(pasteboard: pasteboard) { _ in text }
        #expect(await copier.copyText(ofPictureAt: picture) == .noText)
        #expect(pasteboard.string(forType: .string) == "before")
    }

    @Test func whatWasCopiedWhileThePictureWasReadIsNotReplaced() async throws {
        var resume: CheckedContinuation<String?, Never>?
        let copier = TextCopier(pasteboard: pasteboard) { _ in await withCheckedContinuation { resume = $0 } }
        let copy = Task { await copier.copyText(ofPictureAt: picture) }
        for _ in 0..<20 { await Task.yield() }
        pasteboard.clearContents()
        pasteboard.setString("copied meanwhile", forType: .string)
        try #require(resume).resume(returning: "late")
        #expect(await copy.value == .superseded)
        #expect(pasteboard.string(forType: .string) == "copied meanwhile")
    }

    /// Two readings at once: the newer copies, and the older says nothing, whichever ends first.
    @Test(arguments: [false, true])
    func theNewerCopyTextIsTheOneThatCopies(olderEndsFirst: Bool) async throws {
        let older = URL(filePath: "/tmp/older.png"), newer = URL(filePath: "/tmp/newer.png")
        var resumes: [URL: CheckedContinuation<String?, Never>] = [:]
        let copier = TextCopier(pasteboard: pasteboard) { url in await withCheckedContinuation { resumes[url] = $0 } }
        let first = Task { await copier.copyText(ofPictureAt: older) }
        for _ in 0..<20 { await Task.yield() }
        let second = Task { await copier.copyText(ofPictureAt: newer) }
        for _ in 0..<20 { await Task.yield() }
        if olderEndsFirst {
            try #require(resumes[older]).resume(returning: "older")
            #expect(await first.value == .superseded)
            try #require(resumes[newer]).resume(returning: "newer")
            #expect(await second.value == .copied(characters: 5))
        } else {
            try #require(resumes[newer]).resume(returning: "newer")
            #expect(await second.value == .copied(characters: 5))
            try #require(resumes[older]).resume(returning: "older")
            #expect(await first.value == .superseded)
        }
        #expect(pasteboard.string(forType: .string) == "newer")
    }
}
