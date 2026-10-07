import CoreGraphics
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
}
