import CoreGraphics
import Foundation
import Testing
@testable import OMSOCR

struct OCRAlgorithmRegressionTests {
    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 40, height: CGFloat = 20) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: height), confidence: 1)
    }

    private func permutations<T>(_ values: [T]) -> [[T]] {
        guard !values.isEmpty else { return [[]] }
        return values.indices.flatMap { index in
            var rest = values
            let first = rest.remove(at: index)
            return permutations(rest).map { [first] + $0 }
        }
    }

    @Test func tableReadingOrderDoesNotDependOnRecognitionOrder() {
        let lines = [line("A", x: 100, y: 0, height: 10), line("B", x: 0, y: 8, height: 30), line("C", x: 0, y: 50)]
        let table = OCRTable(rows: [[""]], cellBoxes: [[CGRect(x: 0, y: 0, width: 200, height: 100)]])
        for shuffled in permutations(lines) {
            #expect(table.filled(from: shuffled).rows == [["A B C"]])
        }
    }

    @Test func tiedRowAnchorsAndColumnsHaveADeterministicOrder() {
        // Equal centers must not let input order choose the row's anchor and change its membership.
        let lines = [
            line("wide", x: 0, y: 0, height: 30), line("short", x: 100, y: 10, height: 10),
            line("lower", x: 50, y: 18, height: 10), line("next", x: 0, y: 60),
        ]
        let expected = ReadingOrder.sorted(lines)
        for shuffled in permutations(lines) { #expect(ReadingOrder.sorted(shuffled) == expected) }
        let columns = [
            line("later", x: 0, y: 100, width: 10, height: 40),
            line("earlier", x: 0, y: 0, width: 10, height: 40),
        ]
        #expect(ReadingOrder.sorted(columns).map(\.text) == ["earlier", "later"])
    }

    @Test func tableFillingKeepsItsSpacingAndChineseRules() {
        let cell = CGRect(x: 0, y: 0, width: 200, height: 100)
        let spaced = OCRTable(rows: [["1 TB"]], cellBoxes: [[cell]])
        #expect(spaced.filled(from: [line("1TB", x: 0, y: 0)]).rows == [["1 TB"]])
        let chinese = OCRTable(rows: [[""]], cellBoxes: [[cell]])
        #expect(chinese.filled(from: [line("价格", x: 0, y: 0), line("100元", x: 50, y: 0)]).rows == [["价格100元"]])
    }

    @Test func wrapsLookOnlyAtTheThreeNeighborsOnEachSide() {
        var lines = (0..<9).map { line("continues", x: 0, y: CGFloat($0 * 24), width: 100) }
        lines[0].box.size.width = 1000
        // The first, distant line must not make this paragraph seem wider.
        #expect(TextAssembler.inferredWraps(lines)[4])
        lines[1].box.size.width = 1000
        #expect(!TextAssembler.inferredWraps(lines)[4])
        lines[1].isTableRow = true
        #expect(TextAssembler.inferredWraps(lines)[4])
        #expect(TextAssembler.inferredWraps([]).isEmpty)
        #expect(TextAssembler.inferredWraps([lines[4]]) == [false])
        #expect(TextAssembler.inferredWraps(lines).last == false)
    }
}

struct OCRWrapSpeedTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMS_OCR_WRAP_SPEED"] != nil))
    func densePageNeighborScan() {
        for count in [100, 1_000, 10_000] {
            let lines = (0..<count).map {
                OCRLine(text: "An unfinished paragraph continues", box: CGRect(x: 0, y: $0 * 24, width: 640, height: 20), confidence: 1)
            }
            var times: [Double] = []
            for _ in 0..<5 {
                let start = ContinuousClock.now
                let wraps = TextAssembler.inferredWraps(lines)
                let elapsed = ContinuousClock.now - start
                times.append(Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
                #expect(wraps.count == count && wraps.dropLast().allSatisfy { $0 } && wraps.last == false)
            }
            print("OCR_WRAP_BENCH lines=\(count) median_ms=\(times.sorted()[2])")
        }
    }
}
