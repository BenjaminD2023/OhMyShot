import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import OMSOCR

/// List items, alignment, the readable floor, and translations that run on rather than shrink.
struct TranslationLayoutTests {
    private func line(_ text: String, x: CGFloat = 20, y: CGFloat, width: CGFloat = 400, height: CGFloat = 20) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: height), confidence: 1)
    }

    /// A white bitmap of `size`, with `marks` (top-left rects) filled black.
    private func withPixels<T>(_ size: CGSize, marks: [CGRect], _ body: (Pixels) throws -> T) throws -> T {
        let context = try #require(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        for mark in marks { context.fill(CGRect(x: mark.minX, y: size.height - mark.maxY, width: mark.width, height: mark.height)) }
        let data = try #require(context.data)
        return try body(Pixels(base: data.assumingMemoryBound(to: UInt8.self), width: Int(size.width), height: Int(size.height), bytesPerRow: context.bytesPerRow))
    }

    // MARK: List items

    @Test func aBulletReadAsTextIsTakenOff() {
        #expect(Bullets.strippingMark(from: "• Copy the capture") == "Copy the capture")
        #expect(Bullets.strippingMark(from: "·复制截图") == "复制截图")
        #expect(Bullets.strippingMark(from: "▪  Save it") == "Save it")
        #expect(Bullets.strippingMark(from: "·5 GB") == nil, "A dot before a figure is not a bullet")
        #expect(Bullets.strippingMark(from: "•") == nil)
        #expect(Bullets.strippingMark(from: "Copy • Save") == nil)
    }

    /// A dot just left of a line, centered on its middle, is a bullet; a period on the baseline of a column to the
    /// left is not, nor is an icon as tall as the line.
    @Test func aBulletDrawnLeftOfALineIsSeen() throws {
        let box = CGRect(x: 100, y: 40, width: 200, height: 20)
        // The line's first letter, 2 px into its box.
        let letter = CGRect(x: 102, y: 44, width: 8, height: 14)
        try withPixels(CGSize(width: 400, height: 100), marks: [CGRect(x: 82, y: 47, width: 6, height: 6), letter]) { pixels in
            #expect(Bullets.pixelBullet(leftOf: box, in: pixels) == CGRect(x: 82, y: 47, width: 6, height: 6))
        }
        try withPixels(CGSize(width: 400, height: 100), marks: [CGRect(x: 70, y: 55, width: 3, height: 3), letter]) { pixels in
            #expect(Bullets.pixelBullet(leftOf: box, in: pixels) == nil, "a period on the baseline")
        }
        try withPixels(CGSize(width: 400, height: 100), marks: [CGRect(x: 76, y: 41, width: 18, height: 18), letter]) { pixels in
            #expect(Bullets.pixelBullet(leftOf: box, in: pixels) == nil, "an icon")
        }
    }

    /// A bulleted line starts a paragraph of its own however the line before it ends, and its text carries on into
    /// the lines indented under it, past the bullet.
    @Test func listItemsStartParagraphsAndCarryOnUnderTheirText() {
        let lines = [
            line("Quick Access keeps every capture one click away and", y: 0),
            line("• Copy puts the capture on the clipboard so you can", y: 26),
            line("paste it into any app you like", x: 40, y: 52, width: 300),
            line("• Save writes it to the folder you chose in Settings", y: 78),
        ]
        #expect(TextAssembler.inferredWraps(lines) == [false, true, false, false])
        let units = TranslationUnits.group(lines)
        #expect(units.map(\.lines) == [[0], [1, 2], [3]])
        #expect(units.map(\.bulleted) == [false, true, true])
        #expect(units[1].text == "Copy puts the capture on the clipboard so you can paste it into any app you like")
        // Copied, the bullets come back in front of the items.
        let outcome = Translator.Outcome(target: Locale.Language(identifier: "zh-Hans"), translations: [1: "拷贝会把截图放到剪贴板"])
        let copied = Translator.text(of: units, outcome).text
        #expect(copied.contains("\n•  拷贝会把截图放到剪贴板\n•  Save writes"))
    }

    /// A bullet seen only in the pixels splits items that would otherwise read as one paragraph.
    @Test func aBulletSeenInThePixelsStartsAnItem() throws {
        let lines = [
            line("Copy puts the capture on the clipboard so you can paste", x: 40, y: 0),
            line("Save writes it to the folder you chose in Settings", x: 40, y: 26),
        ]
        let items = try withPixels(CGSize(width: 500, height: 60), marks: [CGRect(x: 24, y: 33, width: 6, height: 6), CGRect(x: 42, y: 30, width: 8, height: 14)]) { pixels in
            Bullets.items(lines, in: pixels)
        }
        #expect(items == [false, true])
        #expect(TextAssembler.inferredWraps(lines, items: items) == [false, false])
        #expect(TextAssembler.inferredWraps(lines, items: [false, false]) == [true, false])
    }

    // MARK: Alignment

    @Test func linesAreAlignedAsTheirBlockAgrees() {
        // A dialog's message, centered.
        let centered = [CGRect(x: 150, y: 0, width: 300, height: 20), CGRect(x: 100, y: 26, width: 400, height: 20), CGRect(x: 180, y: 52, width: 240, height: 20)]
        #expect(TranslationOverlay.alignments(centered, sizes: [16, 16, 16]) == [.center, .center, .center])
        // A paragraph: one left edge, ragged right.
        let paragraph = [CGRect(x: 20, y: 0, width: 400, height: 20), CGRect(x: 20, y: 26, width: 380, height: 20), CGRect(x: 20, y: 52, width: 120, height: 20)]
        #expect(TranslationOverlay.alignments(paragraph, sizes: [16, 16, 16]) == [.left, .left, .left])
        // Figures set flush right.
        let figures = [CGRect(x: 300, y: 0, width: 100, height: 20), CGRect(x: 340, y: 26, width: 60, height: 20), CGRect(x: 320, y: 52, width: 80, height: 20)]
        #expect(TranslationOverlay.alignments(figures, sizes: [16, 16, 16]) == [.right, .right, .right])
        // A line on its own.
        #expect(TranslationOverlay.alignments([CGRect(x: 200, y: 0, width: 100, height: 20)], sizes: [16]) == [.left])
    }

    // MARK: Size

    @Test func theFloorIsReadableUnlessThePageIsSmallPrintThroughout() {
        let en = Locale.Language(identifier: "en"), hans = Locale.Language(identifier: "zh-Hans")
        // At 2×, 12 pt is 24 px; 13 pt is 26 px.
        #expect(TranslationOverlay.readableFloor(for: en, scale: 2, sizes: [28, 30, 32, 26]) == 24)
        #expect(TranslationOverlay.readableFloor(for: hans, scale: 2, sizes: [28, 30, 32, 26]) == 26)
        // Four fifths of the lines below the floor: a page of small print keeps only the share of the original.
        #expect(TranslationOverlay.readableFloor(for: en, scale: 2, sizes: [20, 20, 20, 20, 30]) == nil)
    }

    @Test func aTranslationIsNeverShrunkBelowTheFloor() {
        let en = Locale.Language(identifier: "en")
        let box = CGRect(x: 0, y: 0, width: 100, height: 20)
        let member = [OCRLine(text: "Capture", box: box, confidence: 1)]
        let long = "Take a picture of the screen and keep it"
        let free = TranslationOverlay.layout(long, box: box, room: 100, members: member, size: 16, language: en, color: CGColor(gray: 0, alpha: 1))
        #expect(free.scale == TranslationOverlay.minimumScale)
        let floored = TranslationOverlay.layout(long, box: box, room: 100, members: member, size: 16, language: en, color: CGColor(gray: 0, alpha: 1), minimumScale: 0.9)
        #expect(floored.scale == 0.9 && floored.truncated)
    }

    // MARK: Running on

    /// Each line's width, the space a line breaks at left out.
    private func widths(_ layout: TranslationOverlay.Layout) -> [CGFloat] {
        layout.lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth($0)) }
    }

    /// A paragraph translated into English runs on to the right, no further than it needs, before it shrinks; one
    /// translated into Chinese keeps its column and shrinks.
    @Test func aParagraphOfWordsRunsOnBeforeItShrinks() {
        let members = (0..<3).map { OCRLine(text: "line", box: CGRect(x: 0, y: CGFloat($0) * 26, width: 200, height: 20), confidence: 1) }
        let box = members.dropFirst().reduce(members[0].box) { $0.union($1.box) }
        let text = "Quick Access keeps every capture one click away, so you can copy it, annotate it, or drag it anywhere."
        let black = CGColor(gray: 0, alpha: 1)
        let wide = TranslationOverlay.layout(text, box: box, room: 600, members: members, size: 16, language: Locale.Language(identifier: "en"), color: black, widens: true)
        #expect(wide.scale == 1 && !wide.truncated)
        #expect(widths(wide).max()! > 200 && widths(wide).max()! < 600)
        let kept = TranslationOverlay.layout(text, box: box, room: 600, members: members, size: 16, language: Locale.Language(identifier: "en"), color: black)
        #expect(widths(kept).allSatisfy { $0 <= 200 } && kept.scale < 1)
    }

    /// With no room beside it, a paragraph of words grows into the blank rows under it, from its top, before it shrinks.
    @Test func aParagraphOfWordsGrowsDownIntoBlankRows() {
        let members = (0..<2).map { OCRLine(text: "line", box: CGRect(x: 0, y: CGFloat($0) * 26, width: 200, height: 20), confidence: 1) }
        let box = members[0].box.union(members[1].box)
        let text = "Quick Access keeps every capture one click away, so you can copy it, annotate it, or drag it anywhere you like."
        let black = CGColor(gray: 0, alpha: 1)
        let grown = TranslationOverlay.layout(text, box: box, room: 200, members: members, size: 16, language: Locale.Language(identifier: "en"), color: black, widens: true, below: 100)
        #expect(grown.scale == 1 && !grown.truncated && grown.lines.count > 2)
        #expect(widths(grown).allSatisfy { $0 <= 200 })
        // From the box's top: the first baseline within the first line's slot.
        #expect(grown.origins[0].y < box.minY + 26)
    }

    @Test func theBlankRowsUnderABoxStopAtInkOrTheNextLine() throws {
        let box = CGRect(x: 20, y: 20, width: 200, height: 20)
        // Ink 60 px under the box's top edge.
        try withPixels(CGSize(width: 400, height: 200), marks: [CGRect(x: 100, y: 80, width: 30, height: 10)]) { pixels in
            let blank = TranslationOverlay.blankBelow(box, lineHeight: 20, width: 200, beside: [], of: (255, 255, 255), in: pixels)
            // From the box's bottom (40) to the ink (80), less a third of a line.
            #expect(abs(blank - (80 - 40 - 20.0 / 3)) <= 1)
            // A line below comes first.
            let stopped = TranslationOverlay.blankBelow(box, lineHeight: 20, width: 200, beside: [CGRect(x: 20, y: 52, width: 100, height: 20)], of: (255, 255, 255), in: pixels)
            #expect(abs(stopped - (52 - 40 - 20.0 / 3)) <= 1)
        }
    }
}
