import CoreGraphics
import Foundation
import Testing
@testable import OMSOCR

struct AssemblyRangeTests {
    private func line(_ text: String, y: CGFloat, width: CGFloat = 400) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: 0, y: y, width: width, height: 20), confidence: 1)
    }

    @Test func rangesPointAtEachLineAfterSpacesInChineseAreRemoved() {
        let lines = [line("打开 设置", y: 0), line("Version 0.1.0 （build 42）", y: 30)]
        let assembly = TextAssembler.assembly(lines)
        let text = assembly.text as NSString
        #expect(assembly.text == "打开设置\nVersion 0.1.0 (build 42)")
        #expect(text.substring(with: assembly.lineRanges[0]) == "打开设置")
        #expect(text.substring(with: assembly.lineRanges[1]) == "Version 0.1.0 (build 42)")
    }

    @Test func rangesFollowJoinedLinesAndADroppedHyphen() {
        let lines = [
            line("Press Copy to put the capture on the clip-", y: 0, width: 400),
            line("board, then paste it anywhere.", y: 26, width: 300),
        ]
        let assembly = TextAssembler.assembly(lines, options: .init(joinsWrappedLines: true))
        let text = assembly.text as NSString
        #expect(assembly.text == "Press Copy to put the capture on the clipboard, then paste it anywhere.")
        #expect(text.substring(with: assembly.lineRanges[0]) == "Press Copy to put the capture on the clip")
        #expect(text.substring(with: assembly.lineRanges[1]) == "board, then paste it anywhere.")
    }
}

struct TableFormatTests {
    private let table = OCRTable(rows: [["Name", "Note"], ["A|B", "says \"hi\", twice"], ["C"]])

    @Test func markdownEscapesPipesAndPadsShortRows() {
        #expect(table.markdown == "| Name | Note |\n| --- | --- |\n| A\\|B | says \"hi\", twice |\n| C |  |")
    }

    @Test func csvQuotesFieldsWithCommasAndQuotes() {
        #expect(table.csv == "Name,Note\r\nA|B,\"says \"\"hi\"\", twice\"\r\nC,")
    }

    @Test func tsvAndHTMLKeepCellsApart() {
        #expect(table.tsv == "Name\tNote\nA|B\tsays \"hi\", twice\nC\t")
        #expect(table.html == "<table><tr><th>Name</th><th>Note</th></tr><tr><td>A|B</td><td>says &quot;hi&quot;, twice</td></tr><tr><td>C</td><td></td></tr></table>")
    }
}

struct TextDetectorTests {
    @Test func findsLinksEmailsAndPhoneNumbers() {
        let text = "文档在 https://example.com/docs 里，联系 support@example.com 或 +1 415 555 0100。"
        let items = TextDetector.items(in: text)
        #expect(items.contains { $0.kind == .link && $0.url?.host() == "example.com" })
        #expect(items.contains { $0.kind == .email && $0.text == "support@example.com" })
        #expect(items.contains { $0.kind == .phone && $0.url?.scheme == "tel" })
    }

    @Test func findsDates() {
        let items = TextDetector.items(in: "Meeting on October 9, 2026 at 3 PM")
        #expect(items.contains { $0.kind == .date && $0.date != nil })
    }
}

struct TableFillTests {
    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: 20), confidence: 1)
    }

    @Test func cellsTakeTheLinesInsideThem() {
        let table = OCRTable(
            rows: [["fitz Price", "Plan"], ["$0", ""]],
            cellBoxes: [
                [CGRect(x: 0, y: 0, width: 200, height: 40), CGRect(x: 200, y: 0, width: 200, height: 40)],
                [CGRect(x: 0, y: 40, width: 200, height: 40), CGRect(x: 200, y: 40, width: 200, height: 40)],
            ]
        )
        let filled = table.filled(from: [
            line("价格 Price", 10, 10, 120),
            // Straddles both cells of the second row: used for neither.
            line("$0 Free", 150, 50, 120),
        ])
        #expect(filled.rows == [["价格 Price", "Plan"], ["$0", ""]])
    }

    @Test func linesInOneCellJoinInReadingOrder() {
        let table = OCRTable(rows: [["x"]], cellBoxes: [[CGRect(x: 0, y: 0, width: 300, height: 80)]])
        let filled = table.filled(from: [line("cells", 10, 45, 80), line("Two-line", 10, 10, 100)])
        #expect(filled.rows == [["Two-line cells"]])
    }

    @Test func aSpaceOnlyTheTableKeptStays() {
        let boxes = [[CGRect(x: 0, y: 0, width: 200, height: 40), CGRect(x: 200, y: 0, width: 200, height: 40)]]
        let table = OCRTable(rows: [["1 TB", "价格Price"]], cellBoxes: boxes)
        let filled = table.filled(from: [line("1TB", 10, 10, 60), line("价格 Price", 210, 10, 120)])
        #expect(filled.rows == [["1 TB", "价格 Price"]])
    }

    @Test func tablesWithoutBoxesStayAsRead() {
        let table = OCRTable(rows: [["a", "b"]])
        #expect(table.filled(from: [line("z", 0, 0, 10)]) == table)
    }
}
