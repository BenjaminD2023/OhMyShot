import CoreGraphics
import Foundation
import Testing
@testable import OMSOCR

struct ReadingLayoutTests {
    private func line(_ text: String, x: Double = 0, y: Double, width: Double = 280, height: Double = 20,
                      direction: OCRLine.Direction? = .leftToRight, table: Bool = false) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: height), confidence: 1,
                direction: direction, isTableRow: table)
    }

    private func column(_ name: String, x: Double, y: Double = 0, count: Int = 4) -> [OCRLine] {
        (0..<count).map { line("\(name) paragraph line \($0)", x: x, y: y + Double($0 * 26), width: $0 == count - 1 ? 230 : 280) }
    }

    @Test func twoColumnsReadSeparatelyDespiteDifferentBaselines() {
        let left = column("Left", x: 0), right = column("Right", x: 400, y: 12)
        let sorted = ReadingOrder.sorted(Array((left + right).reversed()))
        #expect(sorted == left + right)
        #expect(ReadingOrder.sorted(left + right, layout: .rows) != sorted)
    }

    @Test func threeColumnsReadOneAtATime() {
        let first = column("First", x: 0), second = column("Second", x: 400), third = column("Third", x: 800)
        #expect(ReadingOrder.sorted(third + second + first) == first + second + third)
    }

    @Test func sharedHeadingsAndParagraphsSeparateColumnBands() {
        let title = line("A title over both columns", y: 0, width: 680, height: 28)
        let first = column("Upper left", x: 0, y: 50), second = column("Upper right", x: 400, y: 50)
        let middle = (0..<7).map { line("A full width paragraph line \($0)", y: 180 + Double($0 * 26), width: 680) }
        let third = column("Lower left", x: 0, y: 400), fourth = column("Lower right", x: 400, y: 400)
        let footer = line("A note beneath both columns", y: 540, width: 680)
        let expected = [title] + first + second + middle + third + fourth + [footer]
        #expect(ReadingOrder.sorted(Array(expected.reversed())) == expected)
    }

    @Test func aSideNoteDoesNotInterruptTheMainParagraph() {
        let main = column("Main", x: 0, count: 6)
        let note = [line("See the detail", x: 400, y: 26, width: 100), line("in Figure 2", x: 400, y: 52, width: 100)]
        #expect(ReadingOrder.sorted(note + main) == main + note)
        let shortNote = line("Figure 2", x: 400, y: 40, width: 100, height: 12)
        #expect(ReadingOrder.sorted([shortNote] + main) == main + [shortNote])
        let shortMain = Array(main.prefix(3))
        let caption = (0..<3).map { line("Figure \($0)", x: 400, y: Double($0 * 26), width: 100) }
        #expect(ReadingOrder.sorted(shortMain + caption) == shortMain + caption)
    }

    @Test func alternatingChatBubblesKeepTheirChronologicalOrder() {
        let messages = (0..<8).map { line("A chat message \($0)", x: $0.isMultiple(of: 2) ? 0 : 400, y: Double($0 * 40)) }
        #expect(ReadingOrder.sorted(Array(messages.reversed())) == messages)
        let bubbles = (0..<4).flatMap { index in
            [line("First line of bubble \(index)", x: index.isMultiple(of: 2) ? 0 : 400, y: Double(index * 70)),
             line("Second line of bubble \(index)", x: index.isMultiple(of: 2) ? 0 : 400, y: Double(index * 70 + 26))]
        }
        #expect(ReadingOrder.sorted(Array(bubbles.reversed())) == bubbles)
    }

    @Test func sparseUIAndTableCellsStayInRows() {
        let labels = (0..<4).flatMap { index in
            [line("Field \(index)", y: Double(index * 26), width: 100), line("Value \(index)", x: 400, y: Double(index * 26), width: 100)]
        }
        #expect(ReadingOrder.sorted(Array(labels.reversed())) == labels)
        let marked = (column("Column A", x: 0) + column("Column B", x: 400)).map { value -> OCRLine in
            var copy = value; copy.isTableRow = true; return copy
        }
        #expect(ReadingOrder.sorted(marked) == ReadingOrder.sorted(marked, layout: .rows))
    }

    @Test func evenParagraphShapedContentInsideATableCellUsesRows() {
        let left = column("Cell left", x: 0), right = column("Cell right", x: 400)
        let lines = left + right
        let table = OCRTable(rows: [[""]], cellBoxes: [[CGRect(x: 0, y: 0, width: 700, height: 130)]])
        let expected = zip(left, right).flatMap { [$0.text, $1.text] }.joined(separator: " ")
        #expect(table.filled(from: lines).rows == [[expected]])
    }

    @Test func codeFragmentsKeepTheirRowAndIndentationOrder() {
        let lines = (0..<4).flatMap { index in
            [line("let value\(index) = make(", x: 40, y: Double(index * 26), width: 220),
             line("option: \(index))", x: 300, y: Double(index * 26), width: 220)]
        }
        let ordered = ReadingOrder.sorted(Array(lines.reversed()))
        #expect(ordered == lines)
        #expect(TextAssembler.assembly(ordered).isCode)
    }

    @Test func explicitRTLRowsReadFromTheRightWithoutReversingTheirCharacters() {
        let right = line("النص العربي", x: 300, y: 0, width: 160, direction: .rightToLeft)
        let left = line("التالي", x: 0, y: 1, width: 140, direction: .rightToLeft)
        let number = line("123", x: 180, y: 0, width: 50, direction: .leftToRight)
        #expect(ReadingOrder.sorted([left, number, right]).map(\.text) == [right.text, number.text, left.text])
    }

    @Test func rightAlignedRTLColumnsReadRightColumnFirst() {
        func arabicColumn(_ edge: Double) -> [OCRLine] {
            (0..<4).map { index in
                let width = Double([280, 250, 270, 240][index])
                return line("هذه فقرة عربية \(edge) \(index)", x: edge - width, y: Double(index * 26), width: width, direction: .rightToLeft)
            }
        }
        let left = arabicColumn(300), right = arabicColumn(700)
        #expect(ReadingOrder.sorted(left + right) == right + left)
    }

    @Test func columnLayoutDoesNotDependOnInputOrder() {
        let lines = [line("Title spanning the page", y: 0, width: 680)]
            + column("Left", x: 0, y: 40) + column("Right", x: 400, y: 40)
        for shift in lines.indices {
            let shuffled = Array(lines[shift...]) + Array(lines[..<shift])
            #expect(ReadingOrder.sorted(shuffled) == lines)
            #expect(ReadingOrder.sorted(Array(shuffled.reversed())) == lines)
        }
    }
}
