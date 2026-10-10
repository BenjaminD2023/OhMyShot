import CoreGraphics
import Foundation
import Vision

/// Where the lines of text in a picture lie, and the words in them, for the highlighter to snap to. It reads
/// with the Chinese model, which places English as well as Chinese, the reading the redaction suggestions
/// use too; only where the text lies is kept, never what it says. All of it stays on this Mac.
public struct TextLineReader: Sendable {
    /// A line of text, in the picture's pixels with the origin at the top left.
    public struct Line: Sendable, Equatable {
        /// From the first glyph to the last, and from the top of the tallest letters to the bottom of the
        /// lowest, as tall as the other lines of its paragraph.
        public var box: CGRect
        /// Each word's glyphs along x, left to right. Each Chinese, Japanese, or Korean character is a word.
        public var words: [ClosedRange<CGFloat>]

        public init(box: CGRect, words: [ClosedRange<CGFloat>]) {
            self.box = box
            self.words = words
        }
    }

    /// A line as Vision placed it: its box, and a cell for each word, the cells meeting edge to edge.
    struct Placed: Equatable {
        var box: CGRect
        var cells: [ClosedRange<CGFloat>]
    }

    /// A line's glyphs: how far their ink reaches up and down, the row their letters stand on, and where
    /// each word's ink begins and ends.
    struct Ink: Equatable {
        var top: CGFloat
        var bottom: CGFloat
        var baseline: CGFloat
        var words: [ClosedRange<CGFloat>]
    }

    public init() {}

    public func read(_ image: CGImage) async throws -> [Line] {
        try await read(TextRecognition(image))
    }

    /// The lines `recognition` reads: a reading it has made already, or is making for something else, is not
    /// made again. Fitting them to the ink takes a moment, off the main thread.
    @concurrent
    public func read(_ recognition: TextRecognition) async throws -> [Line] {
        let placed = try await placed(in: recognition)
        try Task.checkCancellation()
        return Self.lines(placed, in: recognition.image)
    }

    /// The lines as Vision places them.
    func placed(in recognition: TextRecognition) async throws -> [Placed] {
        let observations = try await recognition.lines(by: .chinese)
        let image = recognition.image
        let size = CGSize(width: image.width, height: image.height)
        var placed: [Placed] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox.toImageCoordinates(size, origin: .upperLeft)
            // Level lines only: a band along a slanted or vertical line would miss its ends.
            let left = observation.topLeft.toImageCoordinates(size, origin: .upperLeft)
            let right = observation.topRight.toImageCoordinates(size, origin: .upperLeft)
            guard abs(atan2(right.y - left.y, right.x - left.x)) < 0.035, box.height < box.width * 1.5 || candidate.string.count < 2 else { continue }
            let words = Self.words(in: candidate.string)
            guard !words.isEmpty else { continue }
            let cells = words.enumerated().map { index, range -> ClosedRange<CGFloat> in
                if let cell = candidate.boundingBox(for: range)?.boundingBox.toImageCoordinates(size, origin: .upperLeft), cell.width > 0 {
                    return cell.minX...cell.maxX
                }
                // Where Vision cannot place a word, an equal share of the line stands in for it.
                let share = box.width / CGFloat(words.count)
                return (box.minX + share * CGFloat(index))...(box.minX + share * CGFloat(index + 1))
            }
            placed.append(Placed(box: box, cells: cells))
        }
        return placed
    }

    /// The words of a line, as ranges of it: runs of characters between spaces, with each Chinese,
    /// Japanese, or Korean character, and each full-width mark, a word of its own.
    static func words(in line: String) -> [Range<String.Index>] {
        var words: [Range<String.Index>] = []
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character.isWhitespace {
                index = line.index(after: index)
                continue
            }
            var end = line.index(after: index)
            if !isSquare(character) {
                while end < line.endIndex, !line[end].isWhitespace, !isSquare(line[end]) { end = line.index(after: end) }
            }
            words.append(index..<end)
            index = end
        }
        // Punctuation goes with its word, as a Latin word keeps its period: a closing mark (，。、) with the
        // word before it, an opening one (（「) with the word after, so a band never starts or ends on one.
        var joined: [Range<String.Index>] = []
        for word in words {
            if let last = joined.last, last.upperBound == word.lowerBound, line[word].allSatisfy(isClosing) {
                joined[joined.count - 1] = last.lowerBound..<word.upperBound
            } else {
                joined.append(word)
            }
        }
        for index in joined.indices.reversed().dropFirst() where joined[index].upperBound == joined[index + 1].lowerBound && line[joined[index]].allSatisfy(isOpening) {
            joined[index + 1] = joined[index].lowerBound..<joined[index + 1].upperBound
            joined.remove(at: index)
        }
        return joined
    }

    private static func isClosing(_ character: Character) -> Bool {
        "，。、；：！？）」』】〉》〕］｝．…,.;:!?)]}".contains(character) || character == "\u{201D}" || character == "\u{2019}"
    }

    private static func isOpening(_ character: Character) -> Bool {
        "（「『【〈《〔［｛([{".contains(character) || character == "\u{201C}" || character == "\u{2018}"
    }

    /// Characters set one to a square cell: Chinese, Japanese, and Korean, and the full-width marks among
    /// them.
    private static func isSquare(_ character: Character) -> Bool {
        Script.isCJK(character) || character.unicodeScalars.contains { (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }

    // MARK: Fitting to the ink

    /// The lines with their boxes and words moved to the ink, and the lines of each paragraph made one
    /// height: a band over each stands on its letters' baseline and reaches as high and as low as the
    /// paragraph's letters do, so a line without descenders gets as tall a band as the line under it.
    static func lines(_ placed: [Placed], in image: CGImage) -> [Line] {
        let shades = Shades(image)
        let inks = placed.map { line in shades.flatMap { ink(of: line, in: $0) } }
        let paragraphs = paragraphs(of: inks)
        return placed.indices.map { index in
            let words = inks[index]?.words ?? placed[index].cells
            let left = words.first?.lowerBound ?? placed[index].box.minX
            let right = words.last?.upperBound ?? placed[index].box.maxX
            guard let ink = inks[index] else {
                // A background too busy to tell ink from: as Vision placed it.
                return Line(box: CGRect(x: left, y: placed[index].box.minY, width: right - left, height: placed[index].box.height), words: words)
            }
            let paragraph = paragraphs[index].map { inks[$0]! }
            let ascents = paragraph.map { $0.baseline - $0.top }.sorted()
            let descents = paragraph.map { $0.bottom - $0.baseline }
            // A stray mark (an underline, a tall symbol) stretches no paragraph past measure.
            let ascent = min(ascents.last ?? 0, ascents[ascents.count / 2] * 1.25)
            let descent = min(descents.max() ?? 0, ascent * 0.6)
            let top = min(ink.baseline - ascent, ink.top)
            let bottom = max(ink.baseline + descent, ink.bottom)
            return Line(box: CGRect(x: left, y: top, width: right - left, height: bottom - top), words: words)
        }
    }

    /// For each line, the lines of its paragraph (itself included): lines one above the other, of about one
    /// height, overlapping side to side, and closer than their height.
    static func paragraphs(of inks: [Ink?]) -> [[Int]] {
        var parent = Array(inks.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        for i in inks.indices {
            guard let a = inks[i], let aLeft = a.words.first?.lowerBound, let aRight = a.words.last?.upperBound else { continue }
            for j in inks.indices where j > i {
                guard let b = inks[j], let bLeft = b.words.first?.lowerBound, let bRight = b.words.last?.upperBound else { continue }
                let aHeight = a.bottom - a.top, bHeight = b.bottom - b.top
                guard aHeight > 0, bHeight > 0, max(aHeight, bHeight) / min(aHeight, bHeight) < 1.45 else { continue }
                guard min(aRight, bRight) > max(aLeft, bLeft) else { continue }
                let gap = max(b.top - a.bottom, a.top - b.bottom)
                // Apart, one above the other (a line beside another on the same row is not its paragraph).
                guard gap > -0.2 * min(aHeight, bHeight), gap < max(aHeight, bHeight) else { continue }
                parent[root(j)] = root(i)
            }
        }
        var members: [Int: [Int]] = [:]
        for index in inks.indices { members[root(index), default: []].append(index) }
        return inks.indices.map { members[root($0)]! }
    }

    /// A picture's pixels as 8-bit gray, row 0 at the top, drawn once for every line's ink to be read from.
    struct Shades {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        init?(_ image: CGImage) {
            let width = image.width, height = image.height
            guard width > 0, height > 0 else { return nil }
            // Clear parts read as white: drawn over white.
            var pixels = [UInt8](repeating: 255, count: width * height)
            let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.width = width
            self.height = height
            self.pixels = pixels
        }
    }

    static func ink(of placed: Placed, in image: CGImage) -> Ink? {
        Shades(image).flatMap { ink(of: placed, in: $0) }
    }

    /// Where a line's glyphs are: its ink's top and bottom, its baseline (the lowest row as dense as the
    /// body of its letters), and each word's ink, the line's ends on a glyph Vision clipped moving out to
    /// the glyph's edge. Nil where the background is too busy to tell ink from.
    static func ink(of placed: Placed, in shades: Shades) -> Ink? {
        let box = placed.box
        let width = shades.width
        // How far the ink may reach past Vision's box: a glyph it clipped, a descender it left out.
        let reach = Int((box.height * 0.5).rounded())
        // The region looked at, in the picture's rows and columns (the ends exclusive).
        let left = max(0, Int(box.minX.rounded(.down)) - reach), right = min(width, Int(box.maxX.rounded(.up)) + reach)
        let top = max(0, Int(box.minY.rounded(.down)) - reach), bottom = min(shades.height, Int(box.maxY.rounded(.up)) + reach)
        guard right - left >= 4, bottom - top >= 4 else { return nil }
        // Vision's box, inclusive.
        let boxTop = max(top, min(bottom - 1, Int(box.minY.rounded(.down))))
        let boxBottom = max(boxTop, min(bottom - 1, Int(box.maxY.rounded(.up)) - 1))
        let boxLeft = max(left, min(right - 1, Int(box.minX.rounded(.down))))
        let boxRight = max(boxLeft, min(right - 1, Int(box.maxX.rounded(.up)) - 1))
        let boxHeight = boxBottom - boxTop + 1

        return shades.pixels.withUnsafeBufferPointer { pixels -> Ink? in
            // The background is the most common shade of the line's middle, clear of the lines above and
            // below (every other row is enough).
            let middle = Array(stride(from: boxTop + boxHeight * 15 / 100, through: max(boxTop + boxHeight * 15 / 100, boxBottom - boxHeight * 15 / 100), by: 2))
            var histogram = [Int](repeating: 0, count: 32)
            for row in middle {
                let base = row * width
                for column in boxLeft...boxRight { histogram[Int(pixels[base + column]) >> 3] += 1 }
            }
            let background = (histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0) * 8 + 4
            var table = [Bool](repeating: false, count: 256)
            for value in 0..<256 { table[value] = abs(value - background) > 48 }
            return table.withUnsafeBufferPointer { isInk -> Ink? in
                // Ink in nearly every column of the line's middle: a picture, not a page.
                var inked = 0
                for column in boxLeft...boxRight where middle.contains(where: { isInk[Int(pixels[$0 * width + column])] }) { inked += 1 }
                guard inked < (boxRight - boxLeft + 1) * 9 / 10 else { return nil }

                // How much ink each row holds across the line, counted as it is needed.
                var counts = [Int](repeating: -1, count: bottom - top)
                func count(_ row: Int) -> Int {
                    if counts[row - top] >= 0 { return counts[row - top] }
                    let base = row * width
                    var total = 0
                    for column in boxLeft...boxRight where isInk[Int(pixels[base + column])] { total += 1 }
                    counts[row - top] = total
                    return total
                }
                let core = (boxTop + boxHeight / 4)...max(boxTop + boxHeight / 4, boxBottom - boxHeight / 4)
                guard let seed = core.max(by: { count($0) < count($1) }), count(seed) > 0 else { return nil }
                // The glyphs reach up and down from the densest row to the first row without ink. Ink running
                // on to the region's edge (short of the picture's) is a neighbor touching this line: Vision's
                // edge stands there.
                var inkTop = seed, inkBottom = seed
                while inkTop > top, count(inkTop - 1) > 0 { inkTop -= 1 }
                while inkBottom < bottom - 1, count(inkBottom + 1) > 0 { inkBottom += 1 }
                if inkTop == top, top > 0 { inkTop = min(boxTop, seed) }
                if inkBottom == bottom - 1, bottom < shades.height { inkBottom = max(boxBottom, seed) }
                guard inkBottom - inkTop + 1 >= boxHeight * 2 / 5 else { return nil }
                // The baseline: the lowest row with two fifths of the densest row's ink. Below it hang
                // descenders.
                let densest = (inkTop...inkBottom).map(count).max() ?? 0
                let baseline = (inkTop...inkBottom).last { count($0) * 5 >= densest * 2 } ?? inkBottom

                // Which columns hold ink within the rows the line's glyphs fill.
                var columns = [Bool](repeating: false, count: right - left)
                for row in inkTop...inkBottom {
                    let base = row * width
                    for column in left..<right where !columns[column - left] && isInk[Int(pixels[base + column])] { columns[column - left] = true }
                }
                func hasInk(_ column: Int) -> Bool { columns[column - left] }
                let words = placed.cells.enumerated().map { index, cell -> ClosedRange<CGFloat> in
                    let first = max(left, min(right - 1, Int(cell.lowerBound.rounded(.down))))
                    let last = max(first, min(right - 1, Int(cell.upperBound.rounded(.up)) - 1))
                    guard var start = (first...last).first(where: hasInk), var end = (first...last).last(where: hasInk) else { return cell }
                    // The line's ends on a glyph move out to the glyph's edge, no farther than the reach.
                    // Between words the cells meet, and ink across the meeting may be the neighbor's.
                    if index == 0, start == first { while start > left, hasInk(start - 1), first - start < reach { start -= 1 } }
                    if index == placed.cells.count - 1, end == last { while end < right - 1, hasInk(end + 1), end - last < reach { end += 1 } }
                    return CGFloat(start)...CGFloat(end + 1)
                }
                return Ink(top: CGFloat(inkTop), bottom: CGFloat(inkBottom + 1), baseline: CGFloat(baseline + 1), words: words)
            }
        }
    }
}
