import CoreGraphics
import Foundation
import Testing
@testable import OMSOCR

struct TextAssemblerTests {
    private func line(_ text: String, x: CGFloat = 0, y: CGFloat = 0, characterWidth: CGFloat = 10, wraps: Bool? = nil) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: CGFloat(text.count) * characterWidth, height: 20), confidence: 1, wrapsToNextLine: wraps)
    }

    @Test func punctuationInLatinContextBecomesHalfWidth() {
        #expect(TextAssembler.asProse("Version 0.1.0 （build 42）") == "Version 0.1.0 (build 42)")
        #expect(TextAssembler.asProse("Last file：设计稿.png") == "Last file:设计稿.png")
    }

    @Test func punctuationNextToChineseStaysFullWidth() {
        #expect(TextAssembler.asProse("上次更新：2026 年") == "上次更新：2026 年")
        #expect(TextAssembler.asProse("（默认已开启）") == "（默认已开启）")
        #expect(TextAssembler.asProse("请附上 commit hash。") == "请附上 commit hash。")
        #expect(TextAssembler.asProse("请把 build 日志发到 #dev 频道，附上 commit hash。") == "请把 build 日志发到 #dev 频道，附上 commit hash。")
    }

    @Test func halfWidthPunctuationBetweenChineseBecomesFullWidth() {
        #expect(TextAssembler.asProse("开会,讨论方案") == "开会，讨论方案")
    }

    @Test func spacesBetweenChineseCharactersGoButKoreanKeepsItsSpaces() {
        #expect(TextAssembler.asProse("打开 设置") == "打开设置")
        #expect(TextAssembler.asProse("저장 버튼") == "저장 버튼")
    }

    @Test func recognizesCodeAndProse() {
        #expect(TextAssembler.isCodeLike("func thumbnail（for url: URL）-> CGImage？｛"))
        #expect(TextAssembler.isCodeLike("    branches: [main]"))
        #expect(TextAssembler.isCodeLike("}"))
        #expect(TextAssembler.isCodeLike("// 计算缩略图的最大边长"))
        #expect(!TextAssembler.isCodeLike("Version 0.1.0 (build 42)"))
        #expect(!TextAssembler.isCodeLike("Small text at 24 px: 0123456789"))
        #expect(!TextAssembler.isCodeLike("请把 build 日志发到 #dev 频道"))
    }

    @Test func codePunctuationGoesBackToASCIIButNotInsideChineseComments() {
        #expect(TextAssembler.asCode("guard let source = make（url，nil） else ｛") == "guard let source = make(url,nil) else {")
        #expect(TextAssembler.asCode("// 计算，然后返回") == "// 计算，然后返回")
        // A full-width period is no misread one: in a literal it is what the code matches.
        #expect(TextAssembler.asCode("text = text.replace(\"．\", \".\")") == "text = text.replace(\"．\", \".\")")
    }

    @Test func indentationIsRebuiltAndSnappedToFour() {
        let lines = [
            line("func run() {", x: 0),
            line("guard ready else {", x: 41),
            line("return", x: 79),
            line("}", x: 40),
            line("}", x: 1),
        ]
        #expect(TextAssembler.indentation(lines) == [0, 4, 8, 4, 0])
    }

    @Test func twoSpaceIndentationStaysTwo() {
        let lines = [line("jobs:", x: 0), line("test:", x: 20), line("runs-on: macos", x: 40), line("- run: swift", x: 60)]
        #expect(TextAssembler.indentation(lines) == [0, 2, 4, 6])
    }

    @Test func aCodeListingKeepsItsIndentation() {
        let text = TextAssembler.assemble([
            line("func run（） ｛", x: 0, y: 0),
            line("return nil", x: 40, y: 30),
            line("｝", x: 0, y: 60),
        ])
        #expect(text == "func run() {\n    return nil\n}")
    }

    private func boxed(_ text: String, x: CGFloat = 0, y: CGFloat, width: CGFloat) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: 20), confidence: 1)
    }

    @Test func aFullLineThatDoesNotEndASentenceWraps() {
        let lines = [
            boxed("截图完成后，卡片会出现在屏幕的左下", y: 0, width: 400),
            boxed("角，可以直接拖到其他应用里。", y: 26, width: 260),
            boxed("下一段从这里开始。", y: 52, width: 180),
        ]
        #expect(TextAssembler.inferredWraps(lines) == [true, false, false])
        #expect(TextAssembler.assemble(lines, options: .init(joinsWrappedLines: true))
            == "截图完成后，卡片会出现在屏幕的左下角，可以直接拖到其他应用里。\n下一段从这里开始。")
    }

    @Test func shortLinesIndentsAndParagraphGapsDoNotWrap() {
        let lines = [
            boxed("Title", y: 0, width: 80),
            boxed("A body line that reaches the right edge of the", y: 26, width: 400),
            boxed("paragraph and goes on here.", y: 52, width: 230),
            boxed("Indented next paragraph starts", x: 40, y: 78, width: 360),
            boxed("Far below after a gap of a blank line and more", y: 140, width: 400),
            boxed("text", y: 166, width: 40),
        ]
        #expect(TextAssembler.inferredWraps(lines) == [false, true, false, false, true, false])
    }

    @Test func wrappedLinesJoinWithoutSpacesInChineseAndWithSpacesInEnglish() {
        #expect(TextAssembler.joinWrapped(["截图完成后，卡片会", "出现在屏幕左下角。"], wraps: [true, false]) == "截图完成后，卡片会出现在屏幕左下角。")
        #expect(TextAssembler.joinWrapped(["Press Copy to put the", "capture on the clip-", "board."], wraps: [true, true, false]) == "Press Copy to put the capture on the clipboard.")
        #expect(TextAssembler.joinWrapped(["Title", "Body"], wraps: [false, false]) == "Title\nBody")
    }

    @Test func codeSplitIntoPiecesOnOneRowIsOneLine() {
        // 10 px per character: "let options:" ends at 220, its continuation starts one space later.
        let lines = [
            line("func make() {", x: 100, y: 0),
            line("let options:", x: 140, y: 30),
            line("[String: Any] = [:]", x: 270, y: 30),
            line("return options", x: 140, y: 60),
            line("}", x: 100, y: 90),
        ]
        let assembly = TextAssembler.assembly(lines)
        #expect(assembly.text == "func make() {\n    let options: [String: Any] = [:]\n    return options\n}")
        let text = assembly.text as NSString
        #expect(text.substring(with: assembly.lineRanges[2]) == "[String: Any] = [:]")
    }

    @Test func theFieldsOfARowAreOneLineASpaceApart() {
        // A terminal's listing as Vision returns it: a piece for each field or two, whatever the gap between them.
        let lines = [
            line("drwxr-xr-x", x: 0, y: 0), line("12 morgan", x: 130, y: 0), line("staff", x: 250, y: 0), line("384 Nov 12 09:41 Assets", x: 340, y: 0),
            line("-rw-r--r--", x: 0, y: 30), line("1 morgan", x: 140, y: 30), line("staff", x: 250, y: 30), line("2167 Nov 12 09:38 Package.swift", x: 330, y: 30),
        ]
        #expect(TextAssembler.assemble(lines) == """
        drwxr-xr-x 12 morgan staff 384 Nov 12 09:41 Assets
        -rw-r--r-- 1 morgan staff 2167 Nov 12 09:38 Package.swift
        """)
    }

    @Test func aLabelAndItsValueAcrossTheWindowAreOneLine() {
        let lines = [
            line("Wi-Fi", x: 0, y: 0), line("Connected", x: 800, y: 0),
            line("蓝牙耳机", x: 0, y: 60), line("已连接", x: 830, y: 60),
            line("Display", x: 0, y: 120), line("Built-in Liquid Retina XDR", x: 640, y: 120),
        ]
        #expect(TextAssembler.assemble(lines) == "Wi-Fi Connected\n蓝牙耳机 已连接\nDisplay Built-in Liquid Retina XDR")
    }

    @Test func aLabelAndAValueThatBothReadAsTextAreOneLine() {
        // One row of Settings captured alone: four words either side of the window, and no row near it apart at the
        // same place, as the rows of two blocks of text are.
        let row = [line("Allow accessories to connect", x: 0, y: 0), line("Ask for New Accessories", x: 620, y: 0)]
        #expect(row.allSatisfy { TextAssembler.isRunningText($0.text) })
        #expect(TextAssembler.assemble(ReadingOrder.sorted(row)) == "Allow accessories to connect Ask for New Accessories")
        // Under another row of its pane, whose value is a word.
        let pane = [line("Wi-Fi", x: 0, y: 0), line("Connected", x: 760, y: 0), line("Allow accessories to connect", x: 0, y: 60), line("Ask for New Accessories", x: 620, y: 60)]
        #expect(TextAssembler.assemble(ReadingOrder.sorted(pane)) == "Wi-Fi Connected\nAllow accessories to connect Ask for New Accessories")
    }

    @Test func twoColumnsOfAFewLinesAreNotJoinedRowByRow() {
        // Four lines are too few for `ReadingOrder` to look for columns, so they come row by row: each column's line is
        // still a line of its own.
        let english = [
            line("The harbor wakes before the town does.", x: 0, y: 0), line("Inland the road climbs through orchards", x: 480, y: 0),
            line("Gulls argue over the first catch while", x: 0, y: 30), line("planted in rows as straight as rulers.", x: 480, y: 30),
        ]
        let chinese = [
            line("清晨的港口比小镇醒得更早。海鸥为", x: 0, y: 0, characterWidth: 20), line("往内陆走，公路穿过一片果园，果树", x: 400, y: 0, characterWidth: 20),
            line("第一网鱼争个不停，渡船的水手在码", x: 0, y: 30, characterWidth: 20), line("一行一行排得像尺子一样直。采摘的", x: 400, y: 30, characterWidth: 20),
        ]
        for lines in [english, chinese] {
            let text = TextAssembler.assemble(ReadingOrder.sorted(lines))
            #expect(text.components(separatedBy: "\n").sorted() == lines.map(\.text).sorted())
        }
        // One line that Vision returned in two pieces a space apart is one line still.
        let split = [line("Quick Access keeps every capture", x: 0, y: 0), line("one click away from the menu bar", x: 330, y: 0), line("so you can copy or annotate it.", x: 0, y: 30)]
        #expect(TextAssembler.assemble(ReadingOrder.sorted(split)) == "Quick Access keeps every capture one click away from the menu bar\nso you can copy or annotate it.")
    }

    @Test func captionsUnderARowOfPicturesStayLinesOfTheirOwn() {
        // Two rows of three pictures: the captions of a row share a baseline, with a picture's height between the rows.
        let captions = ["Harbor at dawn", "果园小路", "Lighthouse", "Cider press", "海关码头", "Ferry crew"]
        let lines = captions.enumerated().map { index, caption in line(caption, x: CGFloat(index % 3) * 380, y: CGFloat(index / 3) * 300) }
        #expect(TextAssembler.assemble(lines) == captions.joined(separator: "\n"))
        // A page of text beside them is no line above or below them.
        let page = (0..<12).map { line("A line of the page beside the pictures", x: 1200, y: CGFloat($0) * 30) }
        #expect(TextAssembler.assemble(lines + page).hasPrefix(captions.joined(separator: "\n") + "\n"))
    }

    @Test func aRowCapturedAloneIsOneLine() {
        let lines = [line("-rw-r--r--"), line("1 morgan", x: 140), line("staff", x: 250), line("1069 Sep 19 11:50 LICENSE", x: 330)]
        #expect(TextAssembler.assemble(lines) == "-rw-r--r-- 1 morgan staff 1069 Sep 19 11:50 LICENSE")
    }

    @Test func aTableRowAFormulaAndVerticalTextAreNotJoinedToTheirRow() {
        let label = line("Figure 2"), below = line("A note under them", y: 30)
        var row = line("North 1,240", x: 200)
        row.isTableRow = true
        #expect(TextAssembler.assemble([label, row, below]) == "Figure 2\nNorth 1,240\nA note under them")
        var formula = line("$$E = mc^2$$", x: 200)
        formula.math = .display
        #expect(TextAssembler.assemble([label, formula, below]) == "Figure 2\n$$E = mc^2$$\nA note under them")
        let vertical = OCRLine(text: "春风吹过", box: CGRect(x: 200, y: -30, width: 20, height: 80), confidence: 1, direction: .topToBottom)
        #expect(TextAssembler.assemble([label, vertical, below]) == "Figure 2\n春风吹过\nA note under them")
    }

    @Test func fieldsJoinedOnARowKeepRangesOfTheirOwn() {
        // The OCR panel selects a line's text when its box is clicked and marks the boxes a selection touches, by
        // these ranges: a field joined to its row is still selected alone.
        let lines = [line("Wi-Fi", x: 0, y: 0), line("Connected", x: 800, y: 0), line("Bluetooth", x: 0, y: 60), line("On", x: 870, y: 60)]
        for options in [TextAssembler.Options(), TextAssembler.Options(joinsWrappedLines: true)] {
            let assembly = TextAssembler.assembly(lines, options: options)
            #expect(assembly.text == "Wi-Fi Connected\nBluetooth On")
            #expect(assembly.lineRanges.map { (assembly.text as NSString).substring(with: $0) } == lines.map(\.text))
        }
    }
}
