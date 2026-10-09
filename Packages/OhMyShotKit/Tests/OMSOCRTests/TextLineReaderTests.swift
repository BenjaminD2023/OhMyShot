import AppKit
import CoreGraphics
import Testing
@testable import OMSOCR

struct TextLineReaderTests {
    @Test func wordsAreSplitAtSpacesAndEachCJKCharacter() {
        func words(_ line: String) -> [String] {
            TextLineReader.words(in: line).map { String(line[$0]) }
        }
        #expect(words("Hello, world") == ["Hello,", "world"])
        #expect(words("截图完成") == ["截", "图", "完", "成"])
        #expect(words("按住 Option 再松开") == ["按", "住", "Option", "再", "松", "开"])
        // Punctuation goes with its word: closing marks with the one before, opening marks with the one after.
        #expect(words("完成，Option。") == ["完", "成，", "Option。"])
        #expect(words("后，卡片（截图）") == ["后，", "卡", "片", "（截", "图）"])
        #expect(words("完成, 好") == ["完", "成,", "好"])
        #expect(words("，开头") == ["，", "开", "头"])
        #expect(words("  ") == [])
    }

    /// White, 120 by 110, with glyphs drawn as black strokes on two lines, row 0 at the top. The first line
    /// has an ascender (columns 20–21, rows 10–39), letters on rows 20–39, and a descender (columns 44–45,
    /// rows 40–47), its two words at 20–53 and 65–88; the second, from row 60, has an ascender but no
    /// descender.
    private func glyphs() throws -> CGImage {
        let width = 120, height = 110
        var bytes = [UInt8](repeating: 255, count: width * height)
        func fill(_ columns: ClosedRange<Int>, _ rows: ClosedRange<Int>) {
            for row in rows { for column in columns { bytes[row * width + column] = 0 } }
        }
        /// A letter's outline, two pixels thick.
        func letter(_ columns: ClosedRange<Int>, _ rows: ClosedRange<Int>) {
            fill(columns, rows.lowerBound...(rows.lowerBound + 1))
            fill(columns, (rows.upperBound - 1)...rows.upperBound)
            fill(columns.lowerBound...(columns.lowerBound + 1), rows)
            fill((columns.upperBound - 1)...columns.upperBound, rows)
        }
        fill(20...21, 10...39)
        for columns in [30...39, 44...53, 65...74, 79...88] { letter(columns, 20...39) }
        fill(44...45, 40...47)
        fill(20...21, 60...89)
        for columns in [30...39, 44...53, 65...74] { letter(columns, 70...89) }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    @Test func aLinesInkIsFoundPastVisionsBox() throws {
        let image = try glyphs()
        // Vision's box leaves out the descender; its word cells meet edge to edge, the space in the first.
        let placed = TextLineReader.Placed(box: CGRect(x: 16, y: 12, width: 76, height: 32), cells: [16...60, 60...92])
        let ink = try #require(TextLineReader.ink(of: placed, in: image))
        #expect(ink.top == 10)
        #expect(ink.bottom == 48)
        #expect(ink.baseline == 40)
        #expect(ink.words == [20...54, 65...89])
    }

    @Test func linesOfAParagraphAreOneHeight() throws {
        let image = try glyphs()
        let lines = TextLineReader.lines([
            TextLineReader.Placed(box: CGRect(x: 16, y: 12, width: 76, height: 32), cells: [16...60, 60...92]),
            TextLineReader.Placed(box: CGRect(x: 16, y: 62, width: 64, height: 28), cells: [16...60, 60...80]),
        ], in: image)
        #expect(lines.map(\.box) == [CGRect(x: 20, y: 10, width: 69, height: 38), CGRect(x: 20, y: 60, width: 55, height: 38)])
    }

    @Test func paragraphsAreLinesOneAboveTheOther() {
        func ink(_ top: CGFloat, _ bottom: CGFloat, _ words: ClosedRange<CGFloat>) -> TextLineReader.Ink {
            TextLineReader.Ink(top: top, bottom: bottom, baseline: bottom - 6, words: [words])
        }
        let paragraphs = TextLineReader.paragraphs(of: [
            ink(10, 40, 0...100),
            ink(50, 80, 10...90),
            // Beside the first, on its row.
            ink(10, 40, 200...300),
            // Far below.
            ink(150, 180, 0...100),
            // Twice as tall: a heading, not a line of the paragraph.
            ink(90, 150, 0...100),
            nil,
        ])
        #expect(paragraphs == [[0, 1], [0, 1], [2], [3], [4], [5]])
    }

    @Test func aPicturesLinesAndWordsAreFound() async throws {
        let size = CGSize(width: 520, height: 160)
        let font = NSFont.systemFont(ofSize: 15)
        let picture = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            // A paragraph of two lines, the second without descenders, and a line of Chinese.
            ("Every capture keeps one copy" as NSString).draw(at: CGPoint(x: 30, y: 24), withAttributes: attributes)
            ("The text in a" as NSString).draw(at: CGPoint(x: 30, y: 48), withAttributes: attributes)
            ("截图完成后可以直接拖出" as NSString).draw(at: CGPoint(x: 30, y: 100), withAttributes: attributes)
            return true
        }
        var rect = CGRect(origin: .zero, size: size)
        let image = try #require(picture.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let scale = CGFloat(image.width) / size.width
        let lines = try await TextLineReader().read(image).sorted { $0.box.minY < $1.box.minY }
        #expect(lines.map(\.words.count) == [5, 4, 11], "\(lines)")
        guard lines.count == 3 else { return }
        // One height for the paragraph's lines: the second's band reaches as low as the first's descenders.
        #expect(lines[0].box.height == lines[1].box.height)
        // Each line starts at its first glyph, not at the edge of Vision's box.
        for line in lines {
            #expect(abs(line.box.minX - 30 * scale) <= 3 * scale, "\(line.box)")
        }
        // Words do not overlap, and lie within their line.
        for line in lines {
            for (a, b) in zip(line.words, line.words.dropFirst()) { #expect(a.upperBound <= b.lowerBound + 1) }
            #expect(line.words.first?.lowerBound == line.box.minX && line.words.last?.upperBound == line.box.maxX)
        }
    }
}
