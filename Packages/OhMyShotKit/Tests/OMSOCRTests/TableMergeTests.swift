import CoreGraphics
import Foundation
@testable import OMSOCR
import Testing

/// The VLM pack's tables and charts in place of Vision's lines there, where they bear themselves out.
struct TableMergeTests {
    private static func line(_ text: String, y: CGFloat, x: CGFloat = 40, width: CGFloat = 600) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: 24), confidence: 0.9)
    }

    /// A page as tests/page-table.png draws it: a paragraph, a table of four columns, a paragraph.
    private static let page: [OCRLine] = [
        line("Revenue grew in every region but the South, where a supplier change", y: 85),
        line("delayed two large orders into the next quarter.", y: 115),
        line("Region Q1 Q2 Change", y: 182),
        line("North 1,240 1,385 +11.7%", y: 230),
        line("South 980 912 -6.9%", y: 278),
        line("West 1,105 1,230 +11.3%", y: 326),
        line("East 860 940 +9.3%", y: 374),
        line("Next quarter we expect the South to recover once the new supplier", y: 450),
        line("ships the backlog, which would put the total near 4,700.", y: 480),
    ]

    private static let read = TableText.rows(otsl: "<fcel>Region<fcel>Q1<fcel>Q2<fcel>Change<nl><fcel>North<fcel>1,240<fcel>1,385<fcel>+11.7%<nl><fcel>South<fcel>980<fcel>912<fcel>-6.9%<nl><fcel>West<fcel>1,105<fcel>1,230<fcel>+11.3%<nl><fcel>East<fcel>860<fcel>940<fcel>+9.3%<nl>")
    private static let box = CGRect(x: 37, y: 169, width: 785, height: 240)

    @Test func otslBecomesRowsOfCells() {
        #expect(Self.read.count == 5)
        #expect(Self.read[1] == ["North", "1,240", "1,385", "+11.7%"])
        // Empty and merged cells are empty; rows are padded to the widest.
        #expect(TableText.rows(otsl: "<fcel>Name<lcel><fcel>Size<nl><fcel>a<ecel><fcel>1<nl><ucel><fcel>b<nl>")
            == [["Name", "", "Size"], ["a", "", "1"], ["", "b", ""]])
        // A last row without its <nl>, and text broken over lines in a cell.
        #expect(TableText.rows(otsl: "<fcel>A<fcel>B<nl><fcel>first<br>second<fcel>2") == [["A", "B"], ["first second", "2"]])
    }

    @Test func chartDataBecomesRowsOfCells() {
        #expect(TableText.rows(chart: "Month | Users (thousands)\nJan | 42\nFeb | 55\n") == [["Month", "Users (thousands)"], ["Jan", "42"], ["Feb", "55"]])
        // A Markdown table, its rule line left out.
        #expect(TableText.rows(chart: "| Year | Sales |\n|---|:---:|\n| 2025 | 10 |") == [["Year", "Sales"], ["2025", "10"]])
    }

    @Test func aTableTakesTheLinesInsideItsBox() {
        let table = TableMerge.Table(kind: .table, box: Self.box, rows: Self.read, isWhole: true)
        let merge = TableMerge.merged(Self.page, with: [table])
        #expect(merge.taken == [0])
        #expect(merge.lines.count == 2 + 5 + 2)
        #expect(merge.lines[2].text == "Region\tQ1\tQ2\tChange")
        #expect(merge.lines[2...6].allSatisfy { $0.isTableRow && $0.isExact && $0.wrapsToNextLine == false })
        #expect(merge.lines[2...6].allSatisfy { Self.box.contains($0.box) })
        #expect(merge.tables == [OCRTable(rows: Self.read)])
        // Paragraph, rows, paragraph; the paragraphs' wrapped lines joined, the rows never.
        let text = TextAssembler.assemble(merge.lines, options: .init(joinsWrappedLines: true))
        #expect(text == """
            Revenue grew in every region but the South, where a supplier change delayed two large orders into the next quarter.
            Region\tQ1\tQ2\tChange
            North\t1,240\t1,385\t+11.7%
            South\t980\t912\t-6.9%
            West\t1,105\t1,230\t+11.3%
            East\t860\t940\t+9.3%
            Next quarter we expect the South to recover once the new supplier ships the backlog, which would put the total near 4,700.
            """)
    }

    @Test func aReadingThatDoesntBearItselfOutLeavesVisionsLines() {
        func refused(_ rows: [[String]], kind: TableMerge.Table.Kind = .table, whole: Bool = true, lines: [OCRLine] = Self.page) -> TableMerge.Refusal? {
            let merge = TableMerge.merged(lines, with: [TableMerge.Table(kind: kind, box: Self.box, rows: rows, isWhole: whole)])
            #expect(merge.taken.isEmpty == !merge.refused.isEmpty)
            if !merge.taken.isEmpty { #expect(merge.lines != lines) } else { #expect(merge.lines == lines) }
            return merge.refused.first?.refusal
        }
        #expect(refused(Self.read, whole: false) == .cut)
        #expect(refused([["Region", "Q1"]]) == .small)
        #expect(refused([["Region"], ["North"]]) == .small)
        #expect(refused(Self.read, lines: Array(Self.page.prefix(2)) + Array(Self.page.suffix(2))) == .unseen)
        // Numbers Vision never read there: a made-up or misread table. One or two that differ of the 22 pass: the VLM
        // reads digits better than Vision, and either may be the one wrong.
        var changed = Self.read
        changed[1][1] = "7,240"
        changed[2][2] = "315"
        #expect(refused(changed) == nil)
        changed[3][1] = "2,105"
        changed[4][1] = "760"
        changed[4][2] = "990"
        #expect(refused(changed) == .numbers)
        // Numbers Vision read that the table lacks: a table read short.
        #expect(refused(Array(Self.read.prefix(2))) == .numbers)
        // A chart holds its labels' numbers, not the axis's steps.
        let chartLines = [Self.line("Monthly Active Users", y: 182), Self.line("100 80 60 40 20 0", y: 230), Self.line("42 55 61", y: 278), Self.line("Jan Feb Mar", y: 326)]
        #expect(refused([["Month", "Users"], ["Jan", "42"], ["Feb", "55"], ["Mar", "61"]], kind: .chart, lines: Array(Self.page.prefix(2)) + chartLines) == nil)
        // A chart's values estimated from bars Vision saw no labels on.
        #expect(refused([["Month", "Users"], ["Jan", "43"], ["Feb", "57"], ["Mar", "64"]], kind: .chart, lines: Array(Self.page.prefix(2)) + chartLines) == .numbers)
        // Text that isn't what Vision read there.
        #expect(refused([["Name", "Kind"], ["Alpha", "Folder"], ["Beta", "Document"]], lines: Array(Self.page.prefix(2)) + [Self.line("Region Change", y: 182), Self.line("North South West", y: 230)] ) == .characters)
        // A code listing in columns.
        let code = [Self.line("let a = f(x)", y: 182), Self.line("let b = g(y)", y: 230), Self.line("return a + b;", y: 278)]
        #expect(refused([["let", "a", "f(x)"], ["let", "b", "g(y)"]], lines: code) == .code)
        // The app's own characters there (Text from apps): the reading mustn't change them.
        let exact = Self.page.map { line -> OCRLine in
            var line = line
            line.isExact = true
            return line
        }
        #expect(refused(Self.read, lines: exact) == .appText)
    }

    @Test func theAnalysisTakesTheTableInPlaceOfVisions() {
        let vision = OCRTable(rows: [["Region Q1", "Q2 Change"]], cellBoxes: [[CGRect(x: 40, y: 182, width: 300, height: 24), CGRect(x: 360, y: 182, width: 300, height: 24)]])
        let elsewhere = OCRTable(rows: [["a", "b"]], cellBoxes: [[CGRect(x: 40, y: 900, width: 100, height: 24), CGRect(x: 160, y: 900, width: 100, height: 24)]])
        let analysis = TextAnalysis(result: OCRResult(lines: Self.page, text: "", duration: .zero), tables: [vision, elsewhere], codes: [])
        let (merged, merge) = analysis.withTables([TableMerge.Table(kind: .table, box: Self.box, rows: Self.read, isWhole: true)], assembly: .init())
        #expect(merge.taken == [0])
        #expect(merged.tables == [elsewhere, OCRTable(rows: Self.read)])
        #expect(merged.result.text.contains("North\t1,240\t1,385\t+11.7%"))
        // Nothing taken, nothing changed.
        let (same, _) = analysis.withTables([TableMerge.Table(kind: .table, box: Self.box, rows: Self.read, isWhole: false)], assembly: .init())
        #expect(same.tables == analysis.tables)
    }

    @Test func theLayoutFindsTablesAndChartsApartFromFormulas() {
        let layout = FormulaConfiguration.Layout(file: "layout.mlpackage", input: "pixel_values", size: 800, logits: "logits", boxes: "boxes",
                                                 classes: ["table": 21, "chart": 3, "inline": 15], threshold: 0.5)
        var logits = [Float](repeating: -9, count: 3 * 25)
        logits[0 * 25 + 21] = 3 // a table
        logits[1 * 25 + 15] = 3 // a formula in it
        logits[2 * 25 + 3] = 3 // a chart below
        let boxes: [Float] = [0.5, 0.3, 0.8, 0.4, 0.3, 0.3, 0.1, 0.05, 0.5, 0.8, 0.6, 0.3]
        let tile = LayoutFinder.Tile(area: CGRect(x: 0, y: 0, width: 1000, height: 1000), canvas: CGSize(width: 1000, height: 1000))
        let found = LayoutFinder.merged(LayoutFinder.regions(logits: logits, boxes: boxes, classes: 25, layout: layout, in: tile))
        #expect(Set(found.map(\.kind)) == [.table, .inline, .chart])
    }
}
