import CoreGraphics
import Foundation
import Vision

/// L1 OCR: Apple Vision plus OhMyShot's own post-processing.
///
/// One Vision request runs one recognition model, picked by its first language (Chinese and Japanese
/// share one that also reads English; Korean has its own), and a model drops what it cannot read without
/// a word. So the pipeline reads the image with the primary model, finds text regions it left empty, and
/// reads only those again with the fallback models. See Docs/ocr.md for the measurements behind this.
public struct VisionPipeline: OCREngine {
    public struct Options: Sendable {
        /// The first pass: a Chinese or Japanese language, then English.
        public var primaryLanguages: [Locale.Language]
        /// Passes for regions the first one missed, each its own model, in order.
        public var fallbackLanguages: [[Locale.Language]]
        public var assembly: TextAssembler.Options
        /// Per Vision request.
        public var timeout: Duration

        public init(
            primaryLanguages: [Locale.Language] = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")],
            fallbackLanguages: [[Locale.Language]] = [[Locale.Language(identifier: "en-US")]],
            assembly: TextAssembler.Options = .init(),
            timeout: Duration = .seconds(10)
        ) {
            self.primaryLanguages = primaryLanguages
            self.fallbackLanguages = fallbackLanguages
            self.assembly = assembly
            self.timeout = timeout
        }
    }

    public let name: String
    public var options: Options

    public init(name: String = "l1", options: Options = .init()) {
        self.name = name
        self.options = options
    }

    private static let english = [Locale.Language(identifier: "en-US")]

    /// Runs off the caller's actor: besides Vision's requests, the pipeline scans pixels.
    @concurrent
    public func recognize(_ image: CGImage) async throws -> OCRResult {
        let started = ContinuousClock.now
        // Text detection is cheap and independent of the first pass, so the two run side by side.
        async let primary = readLines(in: image, languages: options.primaryLanguages)
        async let detected = textRectangles(in: image)
        var lines = try await primary
        let rectangles = try await detected

        // Text that is all but free of CJK (a stray misread glyph aside) reads better with the Latin
        // model: English UI, code. It cannot be the first pass: next to CJK its text detection misses
        // whole lines.
        let all = lines.flatMap(\.text).filter { !$0.isWhitespace }
        let cjk = all.filter(Script.isCJK).count
        var fallbacks = options.fallbackLanguages
        if !all.isEmpty, cjk <= 2, Double(cjk) < Double(all.count) * 0.05 {
            let latin = try await readLines(in: image, languages: Self.english)
            if characterCount(latin) >= characterCount(lines) * 4 / 5 {
                lines = latin
                // The Latin model drops the odd Chinese word (a name, a file name); let the primary
                // model have the regions it leaves empty first.
                fallbacks.insert(options.primaryLanguages, at: 0)
            }
        }

        lines = try await fillGaps(in: image, lines: lines, rectangles: rectangles, fallbacks: fallbacks)
        lines = try await rereadCodeWithLatinModel(in: image, lines: lines)
        lines = inferLoneBrackets(in: lines, image: image)

        let ordered = ReadingOrder.sorted(lines)
        return OCRResult(
            lines: ordered,
            text: TextAssembler.assemble(ordered, options: options.assembly),
            duration: ContinuousClock.now - started
        )
    }

    // MARK: Reading

    /// Lines in `region` (the whole image when nil), in image pixels with a top-left origin, with spaces
    /// restored where the image shows them.
    private func readLines(in image: CGImage, languages: [Locale.Language], region: CGRect? = nil) async throws -> [OCRLine] {
        let size = CGSize(width: image.width, height: image.height)
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = languages
        let regionOfInterest = region.map { Self.normalized($0, in: size) }
        if let regionOfInterest {
            request.regionOfInterest = regionOfInterest
        }
        let configured = request
        let observations = try await withTimeout(options.timeout) { try await configured.perform(on: image) }
        let place: (NormalizedRect) -> CGRect = { rect in
            if let regionOfInterest {
                rect.toImageCoordinates(from: regionOfInterest, imageSize: size, origin: .upperLeft)
            } else {
                rect.toImageCoordinates(size, origin: .upperLeft)
            }
        }
        return observations.compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = place(observation.boundingBox)
            var text = candidate.string
            if box.width > box.height, Spacing.mayNeedSpaces(text), let ink = InkProfile(image: image, box: box) {
                let glyphs = { (range: Range<String.Index>) in candidate.boundingBox(for: range).map { place($0.boundingBox) } }
                if let em = Spacing.em(of: text, glyphs: glyphs) {
                    text = Spacing.restored(text, ink: ink, em: em) { glyphs($0)?.maxX }
                }
            }
            return OCRLine(
                text: text,
                box: box,
                confidence: candidate.confidence,
                direction: OCRLine.Direction(observation.textDirection),
                wrapsToNextLine: observation.shouldWrapToNextLine
            )
        }
    }

    // MARK: Gaps

    /// Reads again, with each fallback model, the text regions the lines leave empty.
    private func fillGaps(in image: CGImage, lines: [OCRLine], rectangles: [CGRect], fallbacks: [[Locale.Language]]) async throws -> [OCRLine] {
        var lines = lines
        let size = CGSize(width: image.width, height: image.height)
        var gaps = padded(merged(rectangles.filter { isMissing($0, given: lines) }), in: size)
        for languages in fallbacks where !gaps.isEmpty {
            var remaining: [CGRect] = []
            for region in gaps {
                let found = try await readLines(in: image, languages: languages, region: region)
                let earlier = lines.filter { overlapFraction(of: $0.box, in: region) > 0.5 }
                // Keep whichever pass read more of the region.
                if characterCount(found) > characterCount(earlier) {
                    lines.removeAll { overlapFraction(of: $0.box, in: region) > 0.5 }
                    lines += found
                } else {
                    remaining.append(region)
                }
            }
            gaps = remaining
        }
        return lines
    }

    /// Where text is in the image, whatever its script, in pixels with a top-left origin.
    private func textRectangles(in image: CGImage) async throws -> [CGRect] {
        let size = CGSize(width: image.width, height: image.height)
        let request = DetectTextRectanglesRequest()
        return try await withTimeout(options.timeout) { try await request.perform(on: image) }
            .map { $0.boundingBox.toImageCoordinates(size, origin: .upperLeft) }
    }

    /// Whether the lines leave a text region empty, or cover it with far fewer characters than it holds
    /// (a model reading a script it does not know returns a few stray glyphs).
    private func isMissing(_ rectangle: CGRect, given lines: [OCRLine]) -> Bool {
        guard rectangle.width > 0, rectangle.height > 0 else { return false }
        var coveredWidth: CGFloat = 0
        var characters: CGFloat = 0
        for line in lines where line.box.intersects(rectangle) {
            let shared = line.box.intersection(rectangle)
            coveredWidth += shared.width
            characters += CGFloat(line.text.count) * shared.width / max(line.box.width, 1)
        }
        // Square CJK glyphs are about as wide as the line is tall; Latin text packs more characters.
        let expected = rectangle.width / (rectangle.height * 0.9)
        return coveredWidth < rectangle.width * 0.5 || characters < expected * 0.5
    }

    /// Vision never returns a line holding a single glyph, and its text detector skips such lines too, so
    /// the closing brackets of code, alone on their lines, go missing in every pass. The pixels still show
    /// them; in a code listing, each such glyph becomes the closer of the bracket left open on the line
    /// above it that starts in the same column. Nothing is guessed where no open bracket lines up.
    private func inferLoneBrackets(in lines: [OCRLine], image: CGImage) -> [OCRLine] {
        let ordered = ReadingOrder.sorted(lines)
        guard TextAssembler.isCodeListing(ordered) else { return lines }
        let widths = ordered.filter { !Script.containsCJK($0.text) && $0.text.count >= 4 }.map { $0.box.width / CGFloat($0.text.count) }.sorted()
        guard !widths.isEmpty else { return lines }
        let characterWidth = widths[widths.count / 2]
        let glyphs = LoneGlyphs.find(in: image, around: ordered, characterWidth: characterWidth)
        guard !glyphs.isEmpty else { return lines }

        enum Event {
            case line(OCRLine)
            case glyph(CGRect)
            var top: CGFloat {
                switch self {
                case .line(let line): line.box.minY
                case .glyph(let rectangle): rectangle.minY
                }
            }
        }
        let pairs: [Character: Character] = ["{": "}", "[": "]", "(": ")"]
        let closers = Set(pairs.values)
        var open: [(bracket: Character, x: CGFloat)] = []
        var inferred: [OCRLine] = []
        for event in (ordered.map(Event.line) + glyphs.map(Event.glyph)).sorted(by: { $0.top < $1.top }) {
            switch event {
            case .line(let line):
                for character in TextAssembler.asCode(line.text) {
                    if pairs[character] != nil {
                        open.append((character, line.box.minX))
                    } else if closers.contains(character), let index = open.lastIndex(where: { pairs[$0.bracket] == character }) {
                        open.removeSubrange(index...)
                    }
                }
            case .glyph(let rectangle):
                guard let index = open.lastIndex(where: { abs($0.x - rectangle.minX) < characterWidth * 0.6 }),
                      let closer = pairs[open[index].bracket] else { continue }
                open.removeSubrange(index...)
                inferred.append(OCRLine(text: String(closer), box: rectangle, confidence: 0.3, direction: .leftToRight))
            }
        }
        return lines + inferred
    }

    // MARK: Code

    /// In code with CJK comments, the CJK model reads the code itself poorly (`url` as `ur1`, full-width
    /// brackets, braces as 子) and the Latin model cannot see past the comments. So each run of code lines
    /// between CJK lines is read again on its own with the Latin model.
    private func rereadCodeWithLatinModel(in image: CGImage, lines: [OCRLine]) async throws -> [OCRLine] {
        let ordered = ReadingOrder.sorted(lines)
        guard TextAssembler.isCodeListing(ordered), ordered.contains(where: { Script.containsCJK($0.text) }) else { return lines }
        let size = CGSize(width: image.width, height: image.height)

        var blocks: [[OCRLine]] = [[]]
        for line in ordered {
            if Script.containsCJK(line.text) {
                blocks.append([])
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        let cjkLines = ordered.filter { Script.containsCJK($0.text) }
        var kept = ordered.filter { Script.containsCJK($0.text) }
        for block in blocks where !block.isEmpty {
            // The block's rows with some margin, but never reaching the CJK lines above or below.
            let union = block.dropFirst().reduce(block[0].box) { $0.union($1.box) }
            let rowHeight = block.map(\.box.height).min() ?? 0
            let ceiling = cjkLines.filter { $0.box.maxY <= union.minY }.map(\.box.maxY).max() ?? 0
            let floor = cjkLines.filter { $0.box.minY >= union.maxY }.map(\.box.minY).min() ?? size.height
            let top = max(ceiling, union.minY - rowHeight * 0.4)
            let bottom = min(floor, union.maxY + rowHeight * 0.4)
            let region = CGRect(x: union.minX - rowHeight, y: top, width: union.width + rowHeight * 2, height: bottom - top)
                .intersection(CGRect(origin: .zero, size: size))
            var replacement = block
            if !region.isNull, region.height > 0 {
                let found = try await readLines(in: image, languages: Self.english, region: region)
                if !found.contains(where: { Script.containsCJK($0.text) }), characterCount(found) >= characterCount(block) * 9 / 10 {
                    replacement = found
                }
            }
            kept += replacement
        }
        return kept
    }

    // MARK: Geometry

    /// Regions one line apart or closer, overlapping sideways, become one.
    private func merged(_ rectangles: [CGRect]) -> [CGRect] {
        var merged: [CGRect] = []
        for rectangle in rectangles.sorted(by: { $0.minY < $1.minY }) {
            if let last = merged.last,
               rectangle.minY - last.maxY < rectangle.height * 1.5,
               rectangle.minX < last.maxX, rectangle.maxX > last.minX {
                merged[merged.count - 1] = last.union(rectangle)
            } else {
                merged.append(rectangle)
            }
        }
        return merged
    }

    private func padded(_ rectangles: [CGRect], in size: CGSize) -> [CGRect] {
        let bounds = CGRect(origin: .zero, size: size)
        return rectangles.map { rectangle in
            let padding = min(rectangle.height, 40) * 0.5
            return rectangle.insetBy(dx: -padding, dy: -padding).intersection(bounds)
        }
    }

    private func characterCount(_ lines: [OCRLine]) -> Int {
        lines.reduce(0) { $0 + $1.text.filter { !$0.isWhitespace }.count }
    }

    /// How much of `box` lies inside `region`, from 0 to 1.
    private func overlapFraction(of box: CGRect, in region: CGRect) -> CGFloat {
        let shared = box.intersection(region)
        guard !shared.isNull, box.width > 0, box.height > 0 else { return 0 }
        return (shared.width * shared.height) / (box.width * box.height)
    }

    /// A pixel rect with a top-left origin as Vision's normalized rect (bottom-left origin).
    private static func normalized(_ rect: CGRect, in size: CGSize) -> NormalizedRect {
        NormalizedRect(
            x: rect.minX / size.width,
            y: (size.height - rect.maxY) / size.height,
            width: rect.width / size.width,
            height: rect.height / size.height
        )
    }
}

/// Which pixel columns of a line hold ink, measured against the line's own background, so it works on
/// light and dark backgrounds alike.
struct InkProfile {
    /// The image x of the first column.
    let originX: Int
    let ink: [Bool]

    init?(image: CGImage, box: CGRect) {
        let rect = box.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isNull, rect.width >= 2, rect.height >= 2, let cropped = image.cropping(to: rect) else { return nil }
        let width = Int(rect.width)
        let height = Int(rect.height)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // The background is what the box's top and bottom rows mostly show.
        let edges = (Array(pixels[0..<width]) + Array(pixels[(height - 1) * width..<height * width])).sorted()
        let background = Int(edges[edges.count / 2])
        originX = Int(rect.minX)
        ink = (0..<width).map { x in
            (0..<height).contains { y in abs(Int(pixels[y * width + x]) - background) > 48 }
        }
    }

    /// The widest run of empty columns between `from` and `to` (image x).
    func widestGap(from: CGFloat, to: CGFloat) -> CGFloat {
        let start = max(0, Int(from) - originX)
        let end = min(ink.count, Int(to.rounded(.up)) - originX)
        guard start < end else { return 0 }
        var widest = 0
        var run = 0
        for column in start..<end {
            run = ink[column] ? 0 : run + 1
            widest = max(widest, run)
        }
        return CGFloat(widest)
    }
}

/// Puts back the spaces Vision drops where Chinese meets Latin letters or digits ("下午 3 点" read as
/// "下午3点", "24 px" as "24px"), going by the empty pixel columns at that spot rather than a style rule.
///
/// macOS text layout already leaves a gap of up to about 0.25 em between CJK and Latin where nobody
/// typed a space, while a typed space leaves 0.32 em or more (measured with the benchmark), so the cut
/// is at 0.3 em. Japanese gets no spaces back at all: its automatic gap reaches 0.29 em, and Japanese
/// rarely puts spaces there anyway.
enum Spacing {
    /// Whether the text has a boundary Vision drops spaces at.
    static func mayNeedSpaces(_ text: String) -> Bool {
        text.contains(where: Script.isCJK) && text.contains(where: Script.isLatinOrDigit) && !text.contains(where: Script.isKana)
    }

    /// The width of a full-width character in this line: the median width Vision gives its CJK
    /// characters.
    static func em(of text: String, glyphs: (Range<String.Index>) -> CGRect?) -> CGFloat? {
        let widths = text.indices
            .filter { Script.isCJK(text[$0]) }
            .compactMap { glyphs($0..<text.index(after: $0))?.width }
            .sorted()
        return widths.isEmpty ? nil : widths[widths.count / 2]
    }

    /// Spaces at a CJK–Latin boundary follow the image both ways: one is added where the gap is a typed
    /// space (over 0.3 em), and one Vision put in is dropped where the glyphs nearly touch (under 0.2 em).
    ///
    /// - Parameter boundary: the image x where a range of the text ends, if Vision knows it.
    static func restored(_ text: String, ink: InkProfile, em: CGFloat, boundary: (Range<String.Index>) -> CGFloat?) -> String {
        var output = ""
        var previous: (character: Character, range: Range<String.Index>)?
        var spaceAfterPrevious = false
        for index in text.indices {
            let character = text[index]
            if character.isWhitespace {
                if previous == nil { output.append(character) } else { spaceAfterPrevious = true }
                continue
            }
            let range = index..<text.index(after: index)
            if let last = previous, isBoundary(last.character, character), let x = boundary(last.range) {
                // Vision's own spaces are usually right, so one goes only where the glyphs clearly touch.
                let window = em * 0.45
                let gap = ink.widestGap(from: x - window, to: x + window)
                if gap > em * (spaceAfterPrevious ? 0.2 : 0.3) {
                    output.append(" ")
                }
            } else if spaceAfterPrevious {
                output.append(" ")
            }
            spaceAfterPrevious = false
            output.append(character)
            previous = (character, range)
        }
        if spaceAfterPrevious { output.append(" ") }
        return output
    }

    /// CJK next to a Latin letter or digit, or a digit next to a letter ("24px"), in either order.
    private static func isBoundary(_ a: Character, _ b: Character) -> Bool {
        if Script.isCJK(a) && Script.isLatinOrDigit(b) || Script.isLatinOrDigit(a) && Script.isCJK(b) { return true }
        guard Script.isLatinOrDigit(a), Script.isLatinOrDigit(b) else { return false }
        return a.isNumber != b.isNumber
    }
}
