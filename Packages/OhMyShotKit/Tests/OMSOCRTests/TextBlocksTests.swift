import AppKit
import CoreGraphics
import Testing
@testable import OMSOCR

struct TextBlocksTests {
    /// Lines of text 20 tall, as boxes: `y` is the top of the first, `pitch` the distance between tops.
    private func lines(x: CGFloat = 100, widths: [CGFloat], y: CGFloat, pitch: CGFloat = 24, height: CGFloat = 20) -> [CGRect] {
        widths.enumerated().map { CGRect(x: x, y: y + CGFloat($0.offset) * pitch, width: $0.element, height: height) }
    }

    @Test func theLinesOfAParagraphAreOneBlock() {
        let blocks = TextBlocks.group(lines(widths: [600, 590, 300], y: 100))
        #expect(blocks == [CGRect(x: 100, y: 100, width: 600, height: 68)])
    }

    @Test func paragraphsSetApartAreBlocksOfTheirOwn() {
        let boxes = lines(widths: [600, 590, 300], y: 100) + lines(widths: [600, 580, 410], y: 208)
        #expect(TextBlocks.group(boxes) == [
            CGRect(x: 100, y: 100, width: 600, height: 68),
            CGRect(x: 100, y: 208, width: 600, height: 68),
        ])
    }

    @Test func aCodeLinesPiecesAreOneLineAndTheListingOneBlock() {
        // Each row is detected in two pieces, 1.5 line heights apart, the second row indented.
        let boxes = [
            CGRect(x: 100, y: 100, width: 300, height: 20), CGRect(x: 430, y: 100, width: 90, height: 20),
            CGRect(x: 140, y: 122, width: 100, height: 20), CGRect(x: 270, y: 122, width: 60, height: 20),
            CGRect(x: 140, y: 144, width: 280, height: 20),
            CGRect(x: 100, y: 188, width: 40, height: 20),
        ]
        // The last row, a short line a little further down than the rows above are apart, stands alone as a label.
        #expect(TextBlocks.group(boxes) == [CGRect(x: 100, y: 100, width: 420, height: 64)])
        #expect(TextBlocks.lines(of: boxes).count == 4)
    }

    @Test func aTableOfFourRowsAndThreeColumnsIsOneBlock() {
        // Cells 60 wide in columns 200 apart, rows 44 apart: far too wide a gap to be one line, too loose
        // for running text, but even.
        var cells: [CGRect] = []
        for row in 0..<4 { for column in 0..<3 { cells.append(CGRect(x: 100 + CGFloat(column) * 200, y: 100 + CGFloat(row) * 44, width: 60, height: 20)) } }
        #expect(TextBlocks.group(cells) == [CGRect(x: 100, y: 100, width: 460, height: 152)])
    }

    @Test func aTableWithTightRowsIsOneBlockToo() {
        var cells: [CGRect] = []
        for row in 0..<4 { for column in 0..<3 { cells.append(CGRect(x: 100 + CGFloat(column) * 160, y: 100 + CGFloat(row) * 26, width: 60, height: 20)) } }
        #expect(TextBlocks.group(cells) == [CGRect(x: 100, y: 100, width: 380, height: 98)])
    }

    @Test func columnsOfRunningTextBesideEachOtherAreTwoBlocks() {
        let left = lines(x: 100, widths: [300, 290, 300, 180], y: 100)
        let right = lines(x: 460, widths: [300, 300, 270, 290], y: 100)
        #expect(TextBlocks.group(left + right) == [
            CGRect(x: 100, y: 100, width: 300, height: 92),
            CGRect(x: 460, y: 100, width: 300, height: 92),
        ])
    }

    @Test func evenlySpacedItemsAreOneListAndUnevenOnesAreNot() {
        let list = (0..<4).map { CGRect(x: 100, y: 100 + CGFloat($0) * 50, width: 220, height: 20) }
        #expect(TextBlocks.group(list) == [CGRect(x: 100, y: 100, width: 220, height: 170)])
        // Gaps of 30, 90, and 30: no rhythm, each item stands alone.
        let uneven = [100, 150, 260, 310].map { CGRect(x: 100, y: CGFloat($0), width: 220, height: 20) }
        #expect(TextBlocks.group(uneven).count == 4)
    }

    @Test func aLoneLineBetweenTwoParagraphsBridgesNeither() {
        // Three lines, a gap of 30 (a line and a half), one line, the same gap, three lines: the gaps are even,
        // but they are the space between paragraphs, not the rhythm of a list.
        let first = lines(widths: [600, 590, 300], y: 100)
        let lone = CGRect(x: 100, y: 198, width: 400, height: 20)
        let second = lines(widths: [600, 580, 410], y: 248)
        #expect(TextBlocks.group(first + [lone] + second) == [
            CGRect(x: 100, y: 100, width: 600, height: 68),
            lone,
            CGRect(x: 100, y: 248, width: 600, height: 68),
        ])
    }

    @Test func gapsThatDifferABitStillBridgeNoParagraphs() {
        // Gaps of 40 and 30: within a quarter of one another, so even, and still paragraph gaps.
        let first = lines(widths: [600, 590, 300], y: 100)
        let lone = CGRect(x: 100, y: 208, width: 400, height: 20)
        let second = lines(widths: [600, 580, 410], y: 258)
        #expect(TextBlocks.group(first + [lone] + second).count == 3)
    }

    @Test func aListAfterAParagraphIsItsOwnBlock() {
        // Single-line items evenly spaced under a paragraph: the first item does not join the paragraph.
        let paragraph = lines(widths: [600, 590, 300], y: 100)
        let list = (0..<3).map { CGRect(x: 100, y: 198 + CGFloat($0) * 50, width: 220, height: 20) }
        #expect(TextBlocks.group(paragraph + list) == [
            CGRect(x: 100, y: 100, width: 600, height: 68),
            CGRect(x: 100, y: 198, width: 220, height: 120),
        ])
    }

    @Test func aHeadingIsNotPartOfTheParagraphUnderIt() {
        let heading = CGRect(x: 100, y: 100, width: 300, height: 36)
        let blocks = TextBlocks.group([heading] + lines(widths: [600, 590, 300], y: 146))
        #expect(blocks == [heading, CGRect(x: 100, y: 146, width: 600, height: 68)])
    }

    @Test func aShortLabelIsNoBlockButALongLineIs() {
        let label = CGRect(x: 500, y: 300, width: 60, height: 20)
        let title = CGRect(x: 100, y: 300, width: 300, height: 20)
        #expect(TextBlocks.group([label]).isEmpty)
        #expect(TextBlocks.group([title, label]) == [title])
    }

    @Test func specksAndBrokenBoxesAreIgnored() {
        let speck = CGRect(x: 10, y: 10, width: 3, height: 3)
        let broken = CGRect(x: CGFloat.nan, y: 10, width: 100, height: 20)
        #expect(TextBlocks.group([speck, broken] + lines(widths: [600, 590], y: 100)) == [CGRect(x: 100, y: 100, width: 600, height: 44)])
        #expect(TextBlocks.group([]).isEmpty)
    }

    @Test func blocksComeTopToBottomThenLeftToRight() {
        let boxes = lines(x: 460, widths: [300, 300, 300], y: 100) + lines(x: 100, widths: [300, 300, 300], y: 100) + lines(x: 100, widths: [300, 300, 300], y: 300)
        let blocks = TextBlocks.group(boxes)
        #expect(blocks.map(\.minX) == [100, 460, 100])
        #expect(blocks.map(\.minY) == [100, 100, 300])
    }

    @Test func aPageAsTheDetectorSawItIsParagraphsCodeAndATable() {
        // The boxes the text-rectangle detector gave for a page drawn at two pixels per point (two paragraphs
        // of three lines, a listing of code, a table of four rows by three columns), as it gave them: the
        // listing's rows in pieces, its closing braces missed, the heights wobbling with the ink.
        let found: [(Int, Int, Int, Int)] = [
            (1847, 205, 144, 20), (1402, 205, 409, 23), (202, 206, 822, 24), (1654, 241, 55, 16), (1460, 240, 144, 17),
            (201, 246, 831, 24), (1461, 273, 276, 24), (201, 286, 809, 24), (1520, 308, 84, 17), (1653, 307, 260, 24),
            (1461, 376, 189, 17), (201, 386, 855, 24), (201, 425, 769, 24), (201, 465, 123, 20),
            (762, 807, 54, 18), (202, 807, 67, 18), (480, 805, 49, 21), (480, 867, 67, 19), (761, 867, 64, 20), (201, 866, 66, 24),
            (762, 926, 76, 19), (202, 927, 50, 18), (482, 927, 86, 20), (480, 987, 79, 18), (762, 987, 66, 20), (201, 987, 90, 20),
        ]
        let blocks = TextBlocks.group(found.map { CGRect(x: $0.0, y: $0.1, width: $0.2, height: $0.3) })
        #expect(blocks == [
            CGRect(x: 1402, y: 205, width: 589, height: 126),
            CGRect(x: 201, y: 206, width: 831, height: 104),
            // The listing's last row stands apart: the row of braces between them was never detected.
            CGRect(x: 1461, y: 376, width: 189, height: 17),
            CGRect(x: 201, y: 386, width: 855, height: 99),
            CGRect(x: 201, y: 805, width: 637, height: 202),
        ])
    }

    @Test func aRenderedPageIsFoundAsItsParagraphs() async throws {
        let size = CGSize(width: 900, height: 420)
        let font = NSFont.systemFont(ofSize: 13)
        let picture = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let first = [
                "Every capture keeps one copy in the history, so a card that has gone",
                "can still be found. The text in a screenshot can be copied, translated,",
                "or searched for later without taking the capture again from scratch.",
            ]
            let second = [
                "A second paragraph, set apart from the first by a blank line, starts here",
                "and runs on for a couple of lines before it ends with a short one.",
                "That is all it says on the page.",
            ]
            for (index, line) in first.enumerated() { (line as NSString).draw(at: CGPoint(x: 100, y: 60 + CGFloat(index) * 20), withAttributes: attributes) }
            for (index, line) in second.enumerated() { (line as NSString).draw(at: CGPoint(x: 100, y: 190 + CGFloat(index) * 20), withAttributes: attributes) }
            return true
        }
        var rect = CGRect(origin: .zero, size: size)
        let image = try #require(picture.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let scale = CGFloat(image.width) / size.width
        let blocks = await TextBlocks.find(in: image)
        #expect(blocks.count == 2, "\(blocks)")
        guard blocks.count == 2 else { return }
        // Each block takes in its three lines and nothing of the other, in pixels from the top left.
        #expect(blocks[0].minY < 70 * scale && blocks[0].maxY > 90 * scale && blocks[0].maxY < 190 * scale, "\(blocks[0])")
        #expect(blocks[1].minY > 150 * scale && blocks[1].minY < 200 * scale && blocks[1].maxY > 230 * scale, "\(blocks[1])")
        for block in blocks { #expect(abs(block.minX - 100 * scale) < 8 * scale, "\(block)") }
    }
}
