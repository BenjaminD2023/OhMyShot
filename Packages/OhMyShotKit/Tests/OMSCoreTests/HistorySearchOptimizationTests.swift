import Foundation
import Testing
@testable import OMSCore

struct HistorySearchOptimizationTests {
    @Test func foldedASCIILookupKeepsCanonicalSearchMembership() {
        let texts = [
            "Café naïve ZEBRA", "Cafe\u{301} nai\u{308}ve zebra", "ＣＡＦＥ ｚｅｂｒａ", "Straße Kelvin",
            "Ωμέγα 敏捷的狐狸 軟體更新", "カタカナ がっこう", "👩🏽‍💻 file_name-299", "z e b r a",
            "Arabic العربية and Latin cafe", "한글 cafe", "A\u{30A}ngstro\u{308}m", "\u{212B}ngström",
        ]
        let queries = ["cafe", "naive", "zebra", "ZEBRA", "kelvin", "strasse", "Ωμέγα", "软件更新", "が", "か", "filename299", "angstrom", "safari cafe"]
        var folding = HistorySearch.Folding()
        for text in texts {
            let entry = HistorySearch.Entry(text: text, appName: "Safári", folding: &folding)
            for query in queries {
                let terms = HistorySearch.terms(in: query)
                let reference = !terms.isEmpty && terms.allSatisfy { entry.key.range(of: $0) != nil || entry.appKey.contains($0) }
                #expect((HistorySearch.match(terms, in: entry) != nil) == reference, "\(query) in \(text)")
            }
        }
    }

    @Test func membershipLookupCanDeferTheExcerptWithoutChangingTheMatches() {
        var folding = HistorySearch.Folding()
        let entry = HistorySearch.Entry(text: "First line\nThe quick brown fox", appName: "Safari", folding: &folding)
        let terms = HistorySearch.terms(in: "safari brown fox")
        #expect(HistorySearch.match(terms, in: entry)?.excerpt?.found == "brown")
        #expect(HistorySearch.match(terms, in: entry, includingExcerpt: false) == .init(excerpt: nil))
        #expect(HistorySearch.match(HistorySearch.terms(in: "brown missing"), in: entry) == nil)
    }

    @Test func asynchronousDirectoryLoadingKeepsTheSynchronousOrderingAndStopsWhenCancelled() async throws {
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryBrowseTests-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        for _ in 0..<3 {
            _ = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        }
        #expect(await store.loadItems() == store.items())
        let gate = DirectoryGate()
        let task = Task {
            await gate.wait()
            return await store.loadItems()
        }
        task.cancel()
        await gate.open()
        #expect(await task.value.isEmpty)
    }
}

private actor DirectoryGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
