import AppKit
import Testing
@testable import OMSUI

/// A table's rows in the panel's text line up on stops as wide as its columns.
struct TableTabStopsTests {
    private let font = NSFont.systemFont(ofSize: 13)

    private func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    @Test func aTablesRowsLineUpOnItsColumns() throws {
        let text = "Quarterly results\nRegion\tQ1\tChange\nNorth\t1,240\t+11.7%\nEast\t860\t+9.3%\nNext quarter we expect more."
        let blocks = TableTabStops.blocks(in: text, font: font)
        let block = try #require(blocks.first)
        #expect(blocks.count == 1)
        // The rows, from the header through the last row's line break, and not the prose around them.
        let rows = (text as NSString).range(of: "Region\tQ1\tChange\nNorth\t1,240\t+11.7%\nEast\t860\t+9.3%\n")
        #expect(block.range == rows)
        // The second column starts past the widest first cell; figures end at a right-aligned stop.
        let first = max(width("Region"), width("North"), width("East"))
        #expect(block.stops.map(\.alignment) == [.right, .right])
        #expect(block.stops[0].location == first + TableTabStops.gap + max(width("Q1"), width("1,240"), width("860")))
        // A column of words starts at a left stop.
        let words = TableTabStops.blocks(in: "Plan\tNote\nFree\tfor one\nPro\tfor teams", font: font)
        #expect(words.first?.stops.map(\.alignment) == [.left])
        #expect(words.first?.stops.first?.location == max(width("Plan"), width("Free"), width("Pro")) + TableTabStops.gap)
    }

    @Test func indentingTabsAndPlainTextHaveNoStops() {
        #expect(TableTabStops.blocks(in: "func run() {\n\tlet a = 1\n\t\treturn a\n}", font: font).isEmpty)
        #expect(TableTabStops.blocks(in: "No tabs here.\nNor here.", font: font).isEmpty)
        // Two tables apart are two blocks.
        #expect(TableTabStops.blocks(in: "a\t1\nb\t2\n\nc\t3\nd\t4", font: font).count == 2)
    }

    @Test func aBlocksLinesTakeItsStops() throws {
        let text = "Intro\nA\t1\nB\t22\nOutro"
        let storage = NSTextStorage(string: text)
        let blocks = TableTabStops.blocks(in: text, font: font)
        TableTabStops.apply(blocks, base: RecognizedTextEditor.paragraphStyle, to: storage)
        let row = try #require(storage.attribute(.paragraphStyle, at: (text as NSString).range(of: "B").location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(row.tabStops == blocks[0].stops)
        #expect(row.lineHeightMultiple == RecognizedTextEditor.paragraphStyle.lineHeightMultiple)
        let prose = try #require(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(prose.tabStops == RecognizedTextEditor.paragraphStyle.tabStops)
    }
}
