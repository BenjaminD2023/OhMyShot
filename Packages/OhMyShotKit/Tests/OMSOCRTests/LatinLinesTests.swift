import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import OMSOCR

struct LatinLineTests {
    @Test func latinLinesAreLatinOnly() {
        #expect(Script.isLatinLine("QuICK Access Keeps every capture"))
        #expect(Script.isLatinLine("Phone：+1 （555） 010-0199"))
        #expect(Script.isLatinLine("Café crème"))
        #expect(!Script.isLatinLine("按住 Option 再松开鼠标"))
        #expect(!Script.isLatinLine("Привет мир"))
        #expect(!Script.isLatinLine("$20"))
        #expect(Script.isLatinLine("1 TB"))
    }

    @Test func labelLinesAreProseButYAMLStaysCode() {
        for prose in ["Docs: https://example.com/docs", "Mail: hello@example.com", "Phone: +1 (555) 010-0199", "Release: October 15, 2026 at 2:30 PM"] {
            #expect(!TextAssembler.isCodeLike(prose), "\(prose)")
        }
        for code in ["name: ocr-bench", "on:", "  push:", "    runs-on: macos-26", "      - uses: actions/checkout@v4", "Resources:", "Type: AWS::S3::Bucket"] {
            #expect(TextAssembler.isCodeLike(code), "\(code)")
        }
    }

    @Test func aContactCardIsNotACodeListing() {
        let texts = ["发布说明 Release Notes", "截图完成后，卡片会出现在屏幕左下角", "Quick Access keeps every capture one click away.",
                     "Docs: https://example.com/docs", "Mail: hello@example.com", "Phone: +1 (555) 010-0199", "Release: October 15, 2026 at 2:30 PM"]
        let lines = texts.enumerated().map { OCRLine(text: $1, box: CGRect(x: 0, y: CGFloat($0) * 30, width: 400, height: 20), confidence: 1) }
        #expect(!TextAssembler.isCodeListing(lines))
    }
}

struct LatinReadingTests {
    private func line(_ text: String, _ x: CGFloat, _ width: CGFloat, y: CGFloat = 100) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: 30), confidence: 0.5)
    }

    @Test func aLineTakesThePageReadingOfItsBox() {
        let box = CGRect(x: 40, y: 100, width: 600, height: 30)
        let page = [line("Quick Access keeps", 40, 300), line("every capture", 350, 290), line("elsewhere", 40, 200, y: 200)]
        let pieces = VisionPipeline.pieces(of: box, in: page)
        #expect(pieces?.map(\.text) == ["Quick Access keeps", "every capture"])
        // Half the width read is not a reading of the line.
        #expect(VisionPipeline.pieces(of: box, in: [line("Quick Access", 40, 250)]) == nil)
    }

    @Test func onlyAReadingAboutAsLongIsAdopted() {
        var lines = [line("QuICK Access Keeps every capture", 40, 600)]
        VisionPipeline.adopt([line("every capture", 350, 290), line("Quick Access Keeps", 40, 300)], at: 0, in: &lines)
        #expect(lines[0].text == "Quick Access Keeps every capture")
        #expect(lines[0].box == CGRect(x: 40, y: 100, width: 600, height: 30))
        VisionPipeline.adopt([line("Quick", 40, 100)], at: 0, in: &lines)
        #expect(lines[0].text == "Quick Access Keeps every capture")
    }
}

struct LineStripTests {
    /// A white page with a black bar per line, and one dark-background line.
    private func page() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 300 - 160, width: 400, height: 60))
        return try #require(context.makeImage())
    }

    @Test func cropsStayClearOfOtherLines() {
        let lines = [
            OCRLine(text: "above", box: CGRect(x: 20, y: 20, width: 200, height: 30), confidence: 1),
            OCRLine(text: "line", box: CGRect(x: 20, y: 56, width: 200, height: 30), confidence: 1),
            OCRLine(text: "beside", box: CGRect(x: 226, y: 56, width: 100, height: 30), confidence: 1),
        ]
        let crop = LineStrip.crops(for: [1], of: lines, in: CGSize(width: 400, height: 300))[0]
        #expect(crop.minY == 50) // the line above ends at 50; a quarter-height pad would reach 48.5
        #expect(crop.maxX == 226) // the cell beside starts at 226
        #expect(crop.maxY == 93.5)
        #expect(crop.minX == 5)
    }

    @Test func rowsAreStackedApartAndFoundAgain() throws {
        let image = try page()
        let crops = [CGRect(x: 10, y: 20, width: 300, height: 30), CGRect(x: 10, y: 150, width: 200, height: 40)]
        let strip = try #require(LineStrip(source: image, crops: crops))
        #expect(strip.image.width == 300 + 32)
        #expect(strip.image.height == 16 + 30 + 18 + 40 + 16)
        #expect(strip.rows == [16..<46, 64..<104])
        #expect(strip.row(of: CGRect(x: 20, y: 18, width: 100, height: 26)) == 0)
        #expect(strip.row(of: CGRect(x: 20, y: 70, width: 100, height: 30)) == 1)
        #expect(strip.row(of: CGRect(x: 20, y: 46, width: 100, height: 14)) == nil)
    }
}

struct RecognitionSlotsTests {
    private final class Counter: Sendable {
        let running = Mutex(0)
        let peak = Mutex(0)
    }

    @Test func noMoreThanTwoRunAtOnce() async throws {
        let slots = RecognitionSlots(count: 2)
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await slots.run {
                        let now = counter.running.withLock { $0 += 1; return $0 }
                        counter.peak.withLock { $0 = max($0, now) }
                        try await Task.sleep(for: .milliseconds(30))
                        counter.running.withLock { $0 -= 1 }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(counter.peak.withLock { $0 } == 2)
    }
}
