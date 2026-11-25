import AppKit
import CoreGraphics
import Foundation
import OMSCore
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

    @Test func hslOKLCHAndDisplayP3ParseAndFormatAllColorFormats() throws {
        let hsl = try #require(PinColor.parse("hsl(225, 100%, 60%)"))
        #expect(hsl.hex == "#3366FF")
        #expect(hsl.hsl == "hsl(225, 100%, 60%)")
        let hsla = try #require(PinColor.parse("hsla(120deg, 100%, 50%, 0.5)"))
        #expect(hsla.hex == "#00FF0080")
        #expect(hsla.hsl == "hsla(120, 100%, 50%, 0.5)")
        let turnHSL = try #require(PinColor.parse("hsl(0.5turn 100% 50%)"))
        #expect(turnHSL.hex == "#00FFFF")

        // Round-trip OKLCH through ScreenColor -> PinColor.parse.
        let red = try #require(PinColor.parse("#FF0000"))
        let parsedOKLCH = try #require(PinColor.parse(red.oklch))
        #expect(abs(parsedOKLCH.red - 1) < 0.02 && parsedOKLCH.green < 0.03 && parsedOKLCH.blue < 0.03)
        let translucentOKLCH = try #require(PinColor.parse("oklch(62.8% 0.258 29.2 / 50%)"))
        #expect(abs(translucentOKLCH.alpha - 0.5) < 0.01)
        #expect(translucentOKLCH.oklch.hasSuffix("/ 0.5)"))

        // Display P3 preserves its native Display P3 CGColor and alpha.
        let p3 = try #require(PinColor.parse("color(display-p3 1 0 0)"))
        #expect(p3.original.colorSpace?.name == CGColorSpace.displayP3)
        #expect(p3.displayP3 == "color(display-p3 1 0 0)")
        let translucentP3 = try #require(PinColor.parse("color(display-p3 0.25 0.5 0.75 / 0.5)"))
        #expect(translucentP3.original.colorSpace?.name == CGColorSpace.displayP3)
        #expect(translucentP3.displayP3 == "color(display-p3 0.25 0.5 0.75 / 0.5)")

        // Every ColorFormat maps to its matching formatted string.
        for format in ColorFormat.allCases {
            #expect(!red.string(in: format).isEmpty)
        }
        #expect(red.string(in: .hex) == red.hex)
        #expect(red.string(in: .rgb) == red.rgb)
        #expect(red.string(in: .hsl) == red.hsl)
        #expect(red.string(in: .oklch) == red.oklch)
        #expect(red.string(in: .displayP3) == red.displayP3)
    }

    @Test func onlyAWholeColorIsAColor() {
        for text in [
            "3366FF", "123456", "#3366F", "#GG66FF", "rgb(300, 0, 0)", "rgb(1, 2)",
            "hsl(120, 100%, 150%)", "hsl(120, 50, 50%)", "oklch(1.5 0.2 30)",
            "color(srgb 1 0 0)", "color(display-p3 1 0)", "The color is #3366FF", "#3366FF and more", "",
        ] {
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

    @Test func scrollableAttributedLinksOnlyHTTPAndHTTPS() {
        let text = "Docs: https://example.com/guide and javascript:alert(1)"
        let attributed = PinText.scrollableAttributed(text)
        var urls: [URL] = []
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let url = value as? URL { urls.append(url) }
        }
        #expect(urls.map(\.absoluteString) == ["https://example.com/guide"])
    }
}
