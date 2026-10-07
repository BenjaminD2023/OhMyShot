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

    @Test func wrappedLinesJoinWithoutSpacesInChineseAndWithSpacesInEnglish() {
        #expect(TextAssembler.joinWrapped(["截图完成后，卡片会", "出现在屏幕左下角。"], wraps: [true, false]) == "截图完成后，卡片会出现在屏幕左下角。")
        #expect(TextAssembler.joinWrapped(["Press Copy to put the", "capture on the clip-", "board."], wraps: [true, true, false]) == "Press Copy to put the capture on the clipboard.")
        #expect(TextAssembler.joinWrapped(["Title", "Body"], wraps: [false, false]) == "Title\nBody")
    }
}
