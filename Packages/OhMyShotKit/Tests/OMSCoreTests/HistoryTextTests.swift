import Foundation
import Testing
@testable import OMSCore

struct HistoryTextTests {
    private func makeStore() -> HistoryStore {
        HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryTextTests-\(UUID().uuidString)"))
    }

    private func screenshot(in store: HistoryStore, _ byte: UInt8 = 1) throws -> HistoryItem {
        try store.add(data: Data([byte]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
    }

    private func read(_ text: String, of item: HistoryItem, in store: HistoryStore) throws {
        try store.setText(text, of: item, readFrom: #require(store.stamp(of: item)))
    }

    @Test func textBelongsToThePictureItWasReadFrom() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try screenshot(in: store)
        #expect(store.text(of: item) == nil)
        #expect(store.needingText(store.items()).map(\.id) == [item.id])
        try read("Hello 你好", of: item, in: store)
        #expect(store.text(of: item) == "Hello 你好")
        #expect(store.needingText(store.items()).isEmpty)
        // Kept beside the capture, and never listed as a record.
        #expect(store.items().count == 1)
    }

    @Test func textReadBeforeThePictureChangedIsReadAgain() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try screenshot(in: store)
        let stamp = try #require(store.stamp(of: item))
        // Marked up (a redaction, say) after the reading began: what was read is not the picture any more.
        let marked = try store.replaceImage(of: item, with: Data([9, 9]), pixelWidth: 1, pixelHeight: 1, annotations: Data())
        try store.setText("secret", of: item, readFrom: stamp)
        #expect(store.text(of: marked) == nil)
        #expect(store.needingText(store.items()).map(\.id) == [item.id])
    }

    @Test func markingUpOrPuttingBackAsTakenNeedsTheTextReadAgain() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try screenshot(in: store)
        try read("as taken", of: item, in: store)
        let marked = try store.replaceImage(of: item, with: Data([9, 9]), pixelWidth: 1, pixelHeight: 1, annotations: Data())
        #expect(store.text(of: marked) == nil)
        try read("with marks", of: marked, in: store)
        #expect(store.text(of: marked) == "with marks")
        let restored = try store.restoreOriginal(of: marked)
        // The original comes back with its older date: still not the picture the text was read from.
        #expect(store.text(of: restored) == nil)
    }

    @Test func flatteningKeepsTheText() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try screenshot(in: store)
        let marked = try store.replaceImage(of: item, with: Data([9, 9]), pixelWidth: 1, pixelHeight: 1, annotations: Data())
        try read("with marks", of: marked, in: store)
        store.flatten(marked)
        #expect(store.text(of: marked) == "with marks")
    }

    @Test func deletingOrTrashingTakesTheTextWithIt() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let deleted = try screenshot(in: store, 1), trashed = try screenshot(in: store, 2)
        try read("one", of: deleted, in: store)
        try read("two", of: trashed, in: store)
        store.delete(deleted)
        store.moveToTrash(trashed)
        for item in [deleted, trashed] {
            #expect(!FileManager.default.fileExists(atPath: store.textURL(for: item).path(percentEncoded: false)))
        }
    }

    @Test func recordingsHaveNoTextToRead() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        _ = try store.add(data: Data([1]), fileExtension: "mp4", kind: .recording, pixelWidth: 1, pixelHeight: 1, appName: nil, duration: 3)
        #expect(store.needingText(store.items()).isEmpty)
    }

    @Test func onceAPackIsThereOnlyChineseAndJapaneseReadWithoutItAreReadAgain() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let chinese = try screenshot(in: store, 1), japanese = try screenshot(in: store, 2), english = try screenshot(in: store, 3)
        try read("打开设置", of: chinese, in: store)
        try read("保存したい", of: japanese, in: store)
        try read("Open Settings 首", of: english, in: store)
        // Without a pack, nothing is waiting.
        #expect(store.needingText(store.items()).isEmpty)
        let waiting = Set(store.needingText(store.items(), reading: "ppocr-v6-small/1").map(\.id))
        #expect(waiting == [chinese.id, japanese.id])
        // The text it reads stays what was found.
        #expect(store.text(of: chinese) == "打开设置")
        // Han or kana count side by side: one alone is Vision's reading of a formula's symbol or an icon.
        #expect(!HistoryText.mayReadBetter("For a quadratic L（z）=臺a「Ax\n7<2/入max（A）."))
        #expect(HistoryText.mayReadBetter("Open 设置 now") && HistoryText.mayReadBetter("设 置"))
        #expect(!HistoryText.mayReadBetter("设\n置"))
    }

    @Test func textReadWithThePackIsReadAgainOnlyByAnotherVersionOfIt() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try screenshot(in: store)
        try store.setText("打开设置", of: item, readFrom: #require(store.stamp(of: item)), reading: "ppocr-v6-small/1")
        #expect(store.needingText(store.items(), reading: "ppocr-v6-small/1").isEmpty)
        // The pack removed: what it read is kept.
        #expect(store.needingText(store.items()).isEmpty)
        #expect(store.needingText(store.items(), reading: "ppocr-v6-small/2").map(\.id) == [item.id])
    }

    @Test func textKeptBeforeReadingsWereNamedReadsAsVisionAlone() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try screenshot(in: store)
        let stamp = try #require(store.stamp(of: item))
        let old = #"{"version":1,"stamp":{"size":\#(stamp.size),"modified":\#(stamp.modified)},"text":"打开设置"}"#
        try Data(old.utf8).write(to: store.textURL(for: item))
        #expect(store.text(of: item) == "打开设置")
        #expect(store.needingText(store.items(), reading: "ppocr-v6-small/1").map(\.id) == [item.id])
    }
}

struct HistorySearchTests {
    private func entry(_ text: String, app: String? = nil) -> HistorySearch.Entry {
        var folding = HistorySearch.Folding()
        return HistorySearch.Entry(text: text, appName: app, folding: &folding)
    }

    private func finds(_ query: String, in text: String, app: String? = nil) -> Bool {
        HistorySearch.match(HistorySearch.terms(in: query), in: entry(text, app: app)) != nil
    }

    @Test func spacesLineBreaksAndPunctuationDoNotCount() {
        #expect(finds("设置通用", in: "设置 › 通用 › 软件更新"))
        #expect(finds("设置通用", in: "设置，通用"))
        #expect(finds("软件更新", in: "软件\n更新"))
        #expect(finds("用户名morax", in: "用户名：morax"))
        #expect(finds("hello world", in: "say helloworld"))
    }

    @Test func caseWidthAndLatinDiacriticsDoNotCount() {
        #expect(finds("hello", in: "ＨＥＬＬＯ"))
        #expect(finds("HELLO", in: "hello"))
        #expect(finds("cafe", in: "Café"))
        #expect(finds("ｶﾀｶﾅ", in: "カタカナ"))
    }

    @Test func traditionalChineseIsFoundBySimplified() {
        #expect(finds("电脑设定", in: "電腦設定與網路連線"))
        #expect(finds("電腦", in: "电脑"))
    }

    @Test func kanaKeepTheirVoicingMarks() {
        #expect(!finds("か", in: "が"))
        #expect(finds("が", in: "がっこう"))
    }

    @Test func everyWordMustBeFoundInTheTextOrTheAppsName() {
        #expect(finds("safari 登录", in: "请登录", app: "Safari"))
        #expect(!finds("safari 注册", in: "请登录", app: "Safari"))
        let byApp = HistorySearch.match(HistorySearch.terms(in: "safari"), in: entry("", app: "Safari"))
        #expect(byApp == HistorySearch.Match(excerpt: nil))
    }

    @Test func aQueryOfNothingToLookForHasNoTerms() {
        #expect(HistorySearch.terms(in: "  ").isEmpty)
        #expect(HistorySearch.terms(in: "，。!?").isEmpty)
        #expect(HistorySearch.match([], in: entry("anything")) == nil)
    }

    @Test func theExcerptIsTheLineAroundWhatWasFound() throws {
        let match = try #require(HistorySearch.match(HistorySearch.terms(in: "brown"), in: entry("first line\nThe quick brown fox jumps\nlast")))
        #expect(match.excerpt == HistorySearch.Excerpt(continuesBefore: false, before: "The quick ", found: "brown", after: " fox jumps"))
    }

    @Test func theExcerptStartsShortlyBeforeWhatWasFound() throws {
        let text = "This line has many words before the word that is wanted here"
        let match = try #require(HistorySearch.match(HistorySearch.terms(in: "wanted"), in: entry(text)))
        let excerpt = try #require(match.excerpt)
        #expect(excerpt.continuesBefore)
        #expect(excerpt.before.count <= HistorySearch.before)
        #expect(excerpt.found == "wanted")
        #expect(excerpt.after == " here")
    }

    @Test func chineseBeforeWhatWasFoundTakesTwiceTheRoom() throws {
        let text = "这一行在要找的词前面有很多很多的中文字符然后才是目标词语"
        let match = try #require(HistorySearch.match(HistorySearch.terms(in: "目标"), in: entry(text)))
        let excerpt = try #require(match.excerpt)
        #expect(excerpt.continuesBefore)
        #expect(excerpt.before.count == HistorySearch.before / 2)
        #expect(excerpt.found == "目标")
    }

    @Test func whatWasFoundOverALineBreakIsShownOnOneLine() throws {
        let match = try #require(HistorySearch.match(HistorySearch.terms(in: "软件更新"), in: entry("检查软件\n更新")))
        #expect(match.excerpt?.found == "软件 更新")
        #expect(match.excerpt?.before == "检查")
    }

    @Test func searchingAHistoryOfLongTextsIsQuick() {
        var folding = HistorySearch.Folding()
        let page = (0..<400).map { "第\($0)行 The quick brown fox jumps over the lazy dog 敏捷的棕色狐狸跳过了懒狗" }.joined(separator: "\n")
        let entries = (0..<300).map { HistorySearch.Entry(text: page + " zebra\($0)", appName: "Safari", folding: &folding) }
        let terms = HistorySearch.terms(in: "懒狗 lazy zebra299")
        let started = ContinuousClock.now
        let found = entries.filter { HistorySearch.match(terms, in: $0) != nil }
        let elapsed = ContinuousClock.now - started
        #expect(found.count == 1)
        // About 7 MB of text: typing must not stall the window (measured in Debug).
        #expect(elapsed < .milliseconds(500), "searching took \(elapsed)")
    }
}

/// The reader's plumbing, with a shell script standing in for the text reader.
@Suite(.serialized)
@MainActor
struct HistoryTextReaderTests {
    private func makeStore() -> HistoryStore {
        HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryTextReaderTests-\(UUID().uuidString)"))
    }

    /// A stand-in reader answering "read <id>" for each picture, or, with `answering`, for that many and then
    /// exiting; every start appends a line to `starts`.
    private func fakeReader(in directory: URL, answering limit: Int? = nil, pause: Double = 0) throws -> (helper: URL, starts: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let helper = directory.appending(path: "fake-reader.sh"), starts = directory.appending(path: "starts")
        let stop = limit.map { "[ \"$n\" -ge \($0) ] && exit 0" } ?? ""
        let script = """
        #!/bin/sh
        echo started >> '\(starts.path(percentEncoded: false))'
        n=0
        while IFS= read -r line; do
          \(stop)
          \(pause > 0 ? "sleep \(pause)" : "")
          id=$(printf '%s' "$line" | sed 's/.*"id":"\\([^"]*\\)".*/\\1/')
          printf '{"id":"%s","text":"read %s"}\\n' "$id" "$id"
          n=$((n + 1))
        done
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path(percentEncoded: false))
        return (helper, starts)
    }

    private func settled(_ reader: HistoryTextReader) async {
        for _ in 0..<200 {
            // Not yet started counts as not settled: finding what is waiting runs before the reader does.
            if !reader.starting, reader.reading == 0, ActiveResources.shared.snapshot[.helperProcess] == nil { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func starts(_ url: URL) -> Int {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    @Test func everyScreenshotWaitingIsReadInOneRunThatEnds() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let one = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        let two = try store.add(data: Data([2]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        _ = try store.add(data: Data([3]), fileExtension: "mp4", kind: .recording, pixelWidth: 1, pixelHeight: 1, appName: nil, duration: 1)
        let (helper, startsFile) = try fakeReader(in: store.directory.appending(path: "bin"))
        let reader = HistoryTextReader(store: store, helper: helper)
        var told: [UUID] = []
        reader.onRead = { told.append($0) }
        reader.readNow()
        try? await Task.sleep(for: .milliseconds(50))
        await settled(reader)
        #expect(store.text(of: one) == "read \(one.id.uuidString)")
        #expect(store.text(of: two) == "read \(two.id.uuidString)")
        #expect(Set(told) == [one.id, two.id])
        #expect(ActiveResources.shared.snapshot[.helperProcess] == nil)
        // Nothing left waiting: asking again starts nothing.
        reader.readNow()
        try? await Task.sleep(for: .milliseconds(200))
        await settled(reader)
        #expect(starts(startsFile) == 1)
    }

    @Test func aReaderThatStopsBeforeTakingItsInputDoesNotEndTheApp() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        // More than the pipe holds (64 KB), so writing it outlives a reader that is gone.
        for byte in 0..<700 {
            _ = try store.add(data: Data([UInt8(byte % 256)]), name: "A long name for a capture in the history", fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        }
        let (helper, _) = try fakeReader(in: store.directory.appending(path: "bin"), answering: 0)
        let reader = HistoryTextReader(store: store, helper: helper)
        reader.readNow()
        try? await Task.sleep(for: .milliseconds(100))
        await settled(reader)
        #expect(store.needingText(store.items()).count == 700)
    }

    @Test func readingNowStopsAReadingInTheBackgroundAndGoesOnAtOnce() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let items = try (1...6).map { try store.add(data: Data([UInt8($0)]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil) }
        let (helper, startsFile) = try fakeReader(in: store.directory.appending(path: "bin"), pause: 0.15)
        let reader = HistoryTextReader(store: store, helper: helper)
        reader.read(priority: .background)
        try? await Task.sleep(for: .milliseconds(400))
        // History opens.
        reader.readNow()
        await settled(reader)
        for _ in 0..<80 where items.contains(where: { store.text(of: $0) == nil }) {
            try? await Task.sleep(for: .milliseconds(50))
            await settled(reader)
        }
        #expect(starts(startsFile) == 2)
        #expect(items.allSatisfy { store.text(of: $0) != nil })
    }

    @Test func whatTheReaderLeftUnreadIsNotTriedAgainUntilTheAppRunsAgain() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let items = try (1...3).map { try store.add(data: Data([UInt8($0)]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil) }
        let (helper, startsFile) = try fakeReader(in: store.directory.appending(path: "bin"), answering: 1)
        let reader = HistoryTextReader(store: store, helper: helper)
        reader.readNow()
        try? await Task.sleep(for: .milliseconds(50))
        await settled(reader)
        #expect(items.filter { store.text(of: $0) != nil }.count == 1)
        reader.readNow()
        try? await Task.sleep(for: .milliseconds(200))
        await settled(reader)
        #expect(starts(startsFile) == 1)
        // A new reader (the app's next run) tries them again.
        let next = HistoryTextReader(store: store, helper: helper)
        next.readNow()
        try? await Task.sleep(for: .milliseconds(50))
        await settled(next)
        #expect(starts(startsFile) == 2)
        #expect(items.filter { store.text(of: $0) != nil }.count == 2)
    }
}
