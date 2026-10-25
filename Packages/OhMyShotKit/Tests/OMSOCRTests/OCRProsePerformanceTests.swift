import Foundation
import Testing
@testable import OMSOCR

struct OCRProsePerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMS_OCR_PROSE_SPEED"] != nil))
    func longPunctuationAndWhitespace() {
        for count in [1_000, 3_000, 10_000] {
            let source = "甲" + String(repeating: ", ", count: count / 2) + "乙"
            let expected = "甲" + String(repeating: "， ", count: count / 2) + "乙"
            var elapsed: [Double] = []
            for _ in 0..<3 {
                let start = ContinuousClock.now
                let result = TextAssembler.asProse(source)
                let duration = ContinuousClock.now - start
                elapsed.append(Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15)
                #expect(result == expected)
            }
            print("OCR_PROSE_BENCH characters=\(count + 2) median_ms=\(elapsed.sorted()[1])")
        }
    }
}
