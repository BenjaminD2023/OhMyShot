import CoreGraphics
import Testing
@testable import OMSOCR

struct ReadingOrderTests {
    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, width: CGFloat = 100, height: CGFloat = 20, direction: OCRLine.Direction? = nil) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: height), confidence: 1, direction: direction)
    }

    @Test func rowsReadTopToBottomAndLeftToRight() {
        let lines = [line("c", 0, 60), line("b", 200, 2), line("a", 0, 0)]
        #expect(ReadingOrder.sorted(lines).map(\.text) == ["a", "b", "c"])
    }

    @Test func aSlightlyLowerBaselineStaysInTheRow() {
        // Overlaps the first line by 14 of 20 points.
        let lines = [line("right", 200, 6), line("left", 0, 0)]
        #expect(ReadingOrder.sorted(lines).map(\.text) == ["left", "right"])
    }

    @Test func tallLinesWithoutADirectionAreColumns() {
        let lines = [
            line("左列文字", 0, 0, width: 20, height: 90),
            line("右列文字", 100, 0, width: 20, height: 90),
            line("}", 300, 0, width: 8, height: 20),
        ]
        #expect(ReadingOrder.sorted(lines).map(\.text) == ["}", "右列文字", "左列文字"])
    }

    @Test func verticalColumnsReadRightToLeft() {
        let lines = [
            line("left", 0, 0, width: 20, height: 200, direction: .topToBottom),
            line("right", 100, 0, width: 20, height: 200, direction: .topToBottom),
        ]
        #expect(ReadingOrder.sorted(lines).map(\.text) == ["right", "left"])
    }
}
