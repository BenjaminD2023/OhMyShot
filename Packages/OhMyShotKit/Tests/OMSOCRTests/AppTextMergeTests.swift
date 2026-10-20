import CoreGraphics
import Foundation
@testable import OMSOCR
import Testing

/// L0 beside L1: Vision's lines take the app's characters where the app shows text that reads alike in their place.
struct AppTextMergeTests {
    private static func line(_ text: String, y: CGFloat = 0, math: OCRLine.Math? = nil) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: 10, y: y, width: 300, height: 20), confidence: 0.5, math: math)
    }

    @Test func aMisreadLineTakesTheAppsCharacters() {
        #expect(AppTextMerge.match("for (int i = O; i < n; i++) {", in: ["for (int i = 0; i < n; i++) {"]) == "for (int i = 0; i < n; i++) {")
        #expect(AppTextMerge.match("let Iist = items.fiIter(\\.isOn)", in: ["    let list = items.filter(\\.isOn)\n"]) == "let list = items.filter(\\.isOn)")
    }

    @Test func aLineTheSelectionCutTakesOnlyThePartItShows() {
        // The app's line runs on past both edges of the picture.
        #expect(AppTextMerge.match("wor1d, and every", in: ["Hello, world, and everyone here"]) == "world, and every")
        // A paragraph wrapped over several lines: the one Vision read.
        let paragraph = "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs."
        #expect(AppTextMerge.match("Pack my box with fivc dozen", in: [paragraph]) == "Pack my box with five dozen")
    }

    @Test func textThatDoesntReadAlikeKeepsVisionsReading() {
        #expect(AppTextMerge.match("Tuesday, 10 March", in: ["Settings"]) == nil)
        // The app's whole title, where the screen shows it cut short.
        #expect(AppTextMerge.match("Quarterly Rep…xlsx", in: ["Quarterly Report for the Board 2026.xlsx"]) == nil)
        // A label of an icon the app says but the screen doesn't show.
        #expect(AppTextMerge.match("Inbox", in: ["Compose new message"]) == nil)
    }

    @Test func shortLinesMustReadTheSame() {
        #expect(AppTextMerge.match("0K", in: ["OK"]) == nil)
        #expect(AppTextMerge.match("OK", in: ["OK"]) == "OK")
        // Four to seven characters: one edit.
        #expect(AppTextMerge.match("Cance1", in: ["Cancel"]) == "Cancel")
        #expect(AppTextMerge.match("Canc31", in: ["Cancel"]) == nil)
    }

    @Test func lookAlikesCountForLittle() {
        // A line of look-alikes, which Vision reads its own way.
        let shown = ["let Il1 = [0, O, o]   // l I 1 | 0 O o\n"]
        #expect(AppTextMerge.match("//L111000", in: shown) == "// l I 1 | 0 O o")
        #expect(AppTextMerge.match("let 111 =10,0,0」", in: shown) == "let Il1 = [0, O, o]")
        #expect(AppTextMerge.match("func parseconfig（_ urL: URL） throws -> Config ｛", in: ["func parseConfig(_ url: URL) throws -> Config {\n"])
            == "func parseConfig(_ url: URL) throws -> Config {")
        // Other letters are whole edits.
        #expect(AppTextMerge.match("Tuesday", in: ["Thursday"]) == nil)
        #expect(AppTextMerge.substitution("l", "I") == 1)
        #expect(AppTextMerge.substitution("c", "C") == 1)
        #expect(AppTextMerge.substitution("a", "e") == 4)
    }

    @Test func numbersThatMovedOnKeepVisionsReading() {
        // A clock or a price that changed since the picture: the picture's number stays.
        #expect(AppTextMerge.match("10:30", in: ["10:31"]) == nil)
        #expect(AppTextMerge.match("价格 ¥128.00", in: ["价格 ¥129.00"]) == nil)
        #expect(AppTextMerge.match("Total 128 items", in: ["Total 1280 items"]) == nil)
        #expect(AppTextMerge.match("Total 1280 items", in: ["Total 128 items"]) == nil)
        // A digit Vision read as a letter of its shape, or the other way round, is the app's.
        #expect(AppTextMerge.match("1O:30", in: ["10:30"]) == "10:30")
        #expect(AppTextMerge.match("Room 4O1, fIoor 3", in: ["Room 401, floor 3"]) == "Room 401, floor 3")
        // A number past the end of the part read leaves it alone.
        #expect(AppTextMerge.match("Cancel 2", in: ["Cancel"]) == nil)
    }

    @Test func widthsAndQuotationMarksAreTheApps() {
        #expect(AppTextMerge.match("价格:100元", in: ["价格：100元"]) == "价格：100元")
        #expect(AppTextMerge.match("It's \"here\"", in: ["It’s “here”"]) == "It’s “here”")
    }

    @Test func spacesWithinAPieceAreTheApps() {
        // Vision measured one space where the editor shows two, and missed one.
        #expect(AppTextMerge.match("x = 1 //count", in: ["x  = 1 // count"]) == "x  = 1 // count")
        #expect(AppTextMerge.match("这是一段 中文", in: ["这是一段中文"]) == "这是一段中文")
    }

    @Test func piecesAreSpacedAsVisionSpacedThem() {
        // Cells of a row, each its own element.
        #expect(AppTextMerge.match("Name Size", in: ["Name", "Size"]) == "Name Size")
        #expect(AppTextMerge.match("名称 大小", in: ["名称", "大小"]) == "名称 大小")
        // A sentence a link splits into runs.
        #expect(AppTextMerge.match("点击这里继续", in: ["点击", "这里", "继续"]) == "点击这里继续")
        #expect(AppTextMerge.match("Read the docs first", in: ["Read the ", "docs", " first"]) == "Read the docs first")
    }

    @Test func mergedTakesLinesByTheirBoxes() {
        let lines = [Self.line("Plan 5torage", y: 0), Self.line("$x^2$", y: 30, math: .inline), Self.line("Unrelated", y: 60)]
        let read = [
            AppTextLine(box: lines[0].box, pieces: ["Plan Storage"], app: "Notes"),
            AppTextLine(box: lines[1].box, pieces: ["x2"], app: "Notes"),
            AppTextLine(box: lines[2].box, pieces: ["Something else entirely"], app: "Notes"),
        ]
        let merge = AppTextMerge.merged(lines, with: read)
        #expect(merge.taken == [0])
        #expect(merge.changed == 1)
        #expect(merge.lines.map(\.text) == ["Plan Storage", "$x^2$", "Unrelated"])
        #expect(merge.lines[0].confidence == 1)
        #expect(merge.lines.map(\.isExact) == [true, false, false])
        #expect(merge.lines[0].box == lines[0].box)
        // A line the app bears out unchanged is taken too.
        let same = AppTextMerge.merged([Self.line("Plan Storage")], with: [read[0]])
        #expect(same.taken == [0])
        #expect(same.changed == 0)
    }

    @Test func aScrapOfALineTheAppBearsOutGoes() {
        let line = OCRLine(text: "苹果的「实況文本」", box: CGRect(x: 19, y: 197, width: 830, height: 30), confidence: 0.5)
        let scrap = OCRLine(text: "TZHУ", box: CGRect(x: 21, y: 210, width: 66, height: 9), confidence: 0.3)
        let badge = OCRLine(text: "3", box: CGRect(x: 700, y: 200, width: 20, height: 24), confidence: 1)
        let next = OCRLine(text: "The quick brown fox", box: CGRect(x: 18, y: 230, width: 755, height: 25), confidence: 1)
        let read = [AppTextLine(box: line.box, pieces: ["苹果的「实况文本」"], app: "TextEdit")]
        let merge = AppTextMerge.merged([line, scrap, badge, next], with: read)
        #expect(merge.lines.map(\.text) == ["苹果的「实况文本」", "3", "The quick brown fox"])
        #expect(merge.taken == [0])
        #expect(merge.dropped == 1)
        // Without the app, nothing goes.
        #expect(AppTextMerge.merged([line, scrap], with: []).lines.count == 2)
    }

    @Test func theCardNamesTheAppWhenMostOfTheTextIsItsOwn() {
        let lines = [Self.line("Plan 5torage", y: 0), Self.line("Pro", y: 30)]
        let read = [AppTextLine(box: lines[0].box, pieces: ["Plan Storage"], app: "Notes")]
        #expect(AppTextMerge.merged(lines, with: read).source == "Notes")
        let mostlyVision = [Self.line("Plan", y: 0), Self.line("A much longer line Vision read alone", y: 30)]
        #expect(AppTextMerge.merged(mostlyVision, with: [AppTextLine(box: mostlyVision[0].box, pieces: ["Plan"], app: "Notes")]).source == nil)
    }

    @Test func theAnalysisIsAssembledAgain() {
        let lines = [Self.line("Plan 5torage", y: 0), Self.line("Pro 1 TB", y: 30)]
        let analysis = TextAnalysis(result: OCRResult(lines: lines, text: "Plan 5torage\nPro 1 TB", duration: .zero), tables: [], codes: [])
        let (merged, merge) = analysis.withAppText([AppTextLine(box: lines[0].box, pieces: ["Plan Storage"], app: "Notes")], assembly: .init())
        #expect(merge.taken == [0])
        #expect(merged.result.text == "Plan Storage\nPro 1 TB")
    }

    @Test func theAppsCharactersAreAssembledAsTheyAre() {
        // A space inside Chinese goes from Vision's reading; the app's stays, as do its marks among code.
        let prose = OCRLine(text: "这是 一段中文", box: CGRect(x: 0, y: 0, width: 300, height: 20), confidence: 1)
        #expect(TextAssembler.assemble([prose]) == "这是一段中文")
        var exact = prose
        exact.isExact = true
        #expect(TextAssembler.assemble([exact]) == "这是 一段中文")
        let code = [
            OCRLine(text: "func load() {", box: CGRect(x: 0, y: 0, width: 300, height: 20), confidence: 1),
            OCRLine(text: "let s = \"编号：A0。\"", box: CGRect(x: 40, y: 24, width: 300, height: 20), confidence: 1, isExact: true),
            OCRLine(text: "}", box: CGRect(x: 0, y: 48, width: 20, height: 20), confidence: 1),
        ]
        #expect(TextAssembler.assemble(code).contains("let s = \"编号：A0。\""))
    }
}
