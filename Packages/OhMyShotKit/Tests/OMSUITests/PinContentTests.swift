import AppKit
import Testing
@testable import OMSUI

struct PinColorTests {
    @Test func hexColorsParseAndPrintBack() throws {
        let color = try #require(PinColor.parse("#3366FF"))
        #expect(color.hex == "#3366FF")
        #expect(color.rgb == "rgb(51, 102, 255)")
        #expect(try #require(PinColor.parse("  #36f\n")).hex == "#3366FF")
        let translucent = try #require(PinColor.parse("#3366FF80"))
        #expect(translucent.hex == "#3366FF80")
        #expect(translucent.rgb == "rgba(51, 102, 255, 0.5)")
        #expect(try #require(PinColor.parse("#36f8")).hex == "#3366FF88")
    }

    @Test func rgbFunctionsParse() throws {
        #expect(try #require(PinColor.parse("rgb(51, 102, 255)")).hex == "#3366FF")
        #expect(try #require(PinColor.parse("RGB(51 102 255)")).hex == "#3366FF")
        #expect(try #require(PinColor.parse("rgba(51, 102, 255, 0.25)")).rgb == "rgba(51, 102, 255, 0.25)")
        #expect(try #require(PinColor.parse("rgb(51 102 255 / 50%)")).hex == "#3366FF80")
    }

    @Test func onlyAWholeColorIsAColor() {
        for text in ["3366FF", "123456", "#3366F", "#GG66FF", "rgb(300, 0, 0)", "rgb(1, 2)", "The color is #3366FF", "#3366FF and more", ""] {
            #expect(PinColor.parse(text) == nil, "\(text)")
        }
    }

    @Test func aColorFromElsewhereKeepsItselfAndReadsInSRGB() throws {
        let p3 = try #require(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [1, 0, 0, 1]))
        let color = try #require(PinColor(p3))
        #expect(color.original.colorSpace?.name == CGColorSpace.displayP3)
        // Display P3's red lies outside sRGB: the hex is the clamped value.
        #expect(color.hex == "#FF0000")
        // A gray from a grayscale space stays gray in sRGB, and opaque.
        let gray = try #require(PinColor(CGColor(gray: 0.5, alpha: 1)))
        #expect(gray.red == gray.green && gray.green == gray.blue && gray.alpha == 1)
        #expect(gray.hex.count == 7)
    }
}

@MainActor
struct PinTextTests {
    @Test func aShortLineIsAsWideAsItself() {
        let size = PinText.cardSize(for: "npm run dev")
        #expect(size.width < 160 && size.width >= PinText.minWidth)
        #expect(size.height < 44)
    }

    @Test func aParagraphWrapsAtTheCap() {
        let paragraph = String(repeating: "Quick Access keeps every capture one click away. ", count: 8)
        let size = PinText.cardSize(for: paragraph)
        #expect(size.width == PinText.maxWidth)
        #expect(size.height > 60)
    }

    @Test func longTextIsCutAtTheLineCap() {
        let long = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let lineHeight = NSLayoutManager().defaultLineHeight(for: PinText.font(for: long))
        let size = PinText.cardSize(for: long)
        #expect(size.height <= ceil(lineHeight * CGFloat(PinText.maxLines)) + 2 * PinText.padding.height)
    }

    @Test func theCardHoldsItsLinesAtItsOwnWidth() {
        // Drawn at the card's own width, the text breaks where it did when measured at the widest card.
        for text in [
            "func pinned() {\n    let shortcut = \"⌃⌥⌘7\"\n    print(\"Capture Area and Pin: \\(shortcut)\")\n}",
            "截图完成后，卡片会出现在屏幕左下角，可以直接拖到其他应用里。Quick Access keeps every capture one click away.",
        ] {
            let size = PinText.textSize(for: text)
            let drawn = PinText.attributed(text).boundingRect(with: CGSize(width: size.width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
            #expect(ceil(drawn.height) == size.height, "\(text.prefix(12))")
        }
    }

    @Test func aHugeTextIsCutBeforeItIsLaidOut() {
        let log = (1...5000).map { "log line \($0) with some words in it" }.joined(separator: "\n")
        let shown = PinText.displayed(log)
        #expect(shown.split(separator: "\n").count == PinText.maxLines + 1)
        #expect(shown.count <= PinText.maxCharacters)
        let wide = String(repeating: "x", count: 50_000)
        #expect(PinText.displayed(wide).count == PinText.maxCharacters)
    }

    @Test func codeIsReadConservatively() {
        #expect(PinText.isCodeLike("func a() {\n    return 1\n    // done\n}"))
        #expect(PinText.isCodeLike("```\nls -la\n```"))
        #expect(!PinText.isCodeLike("A sentence, with (parentheses) and = signs; still prose."))
        #expect(!PinText.isCodeLike("One line\n  indented once"))
    }

    @Test func trailingBlankLinesAreNotShown() {
        #expect(PinText.displayed("hello\n\n  \n") == "hello")
    }
}
