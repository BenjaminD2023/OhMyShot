import CoreGraphics
import CoreText
import Foundation

/// The image with each translated unit drawn where its text was, as Live Text's translation does: every
/// original line is painted over with its own background, then the translation is laid out across the
/// unit's box in the original text's color and size, shrinking to 70% when it does not fit and cut
/// short with an ellipsis after that. A unit cut short is reported, so the full translation can be
/// shown elsewhere.
public enum TranslationOverlay {
    public struct Rendering: @unchecked Sendable {
        public var image: CGImage
        /// Units whose translation did not fit even at 70%.
        public var truncated: Set<Int>
    }

    /// The smallest the translation is drawn, as a share of the original size.
    static let minimumScale: CGFloat = 0.7

    /// Off the caller's actor: a full-screen image takes tens of milliseconds. `scale` is the image's
    /// pixels per point (2 for a Retina capture), which tells the size the text had on screen.
    @concurrent
    public static func render(
        _ image: CGImage, lines: [OCRLine], units: [TranslationUnit], translations: [Int: String], language: Locale.Language,
        scale: CGFloat = 1
    ) async -> Rendering? {
        let width = image.width
        let height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = Pixels(base: data.assumingMemoryBound(to: UInt8.self), width: width, height: height, bytesPerRow: context.bytesPerRow)

        let sizes = harmonized(lines.map { typeSize(of: $0, scale: scale) }, boxes: lines.map(\.box))
        // Where each line's ink starts, translated or not, so a translation lines up with the text that
        // stays beside it rather than with Vision's box, which starts a little before the ink.
        let lefts = columnLefts(lines.map(\.box), sizes: sizes, edges: lines.map { inkLeft(of: $0.box, in: pixels) ?? $0.box.minX })
        let bodySize = median(sizes) ?? 0
        let rightToLeft = language.characterDirection == .rightToLeft
        // Colors and room first, while every pixel is still the original.
        let drawn = units.indices.compactMap { index -> Drawn? in
            let unit = units[index]
            guard let text = translations[index], text != unit.text, !unit.lines.isEmpty else { return nil }
            let colors = unit.lines.map { LineColors(pixels: pixels, box: lines[$0].box) }
            var room = unit.box.width
            if unit.lines.count == 1 {
                let others = lines.indices.filter { $0 != unit.lines[0] }.map { lines[$0].box }
                room = clear(Self.room(for: unit.box, beside: others, imageWidth: CGFloat(width)), beside: unit.box, of: colors[0].paper, in: pixels)
            }
            let size = median(unit.lines.map { sizes[$0] }) ?? unit.box.height
            // A heading: a third larger than the body or more. Its weight cannot be read from its pixels
            // reliably (bold Latin is wider, so it reads as a larger size instead), but headings are set
            // bold far more often than not.
            let isHeading = unit.lines.count <= 2 && size >= bodySize * 1.3
            return Drawn(index: index, text: text, colors: colors, room: room, size: size, bold: isHeading)
        }
        let erasedLines = Set(drawn.flatMap { units[$0.index].lines })
        let kept = lines.indices.filter { !erasedLines.contains($0) }.map { lines[$0].box }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        // Core Graphics counts y from the bottom; boxes count from the top.
        func flipped(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height) }

        for unit in drawn {
            for (line, colors) in zip(units[unit.index].lines, unit.colors) {
                context.setFillColor(colors.background)
                context.fill(flipped(erasure(of: lines[line].box, keeping: kept).intersection(bounds)))
            }
        }
        var truncated = Set<Int>()
        for unit in drawn {
            let members = units[unit.index].lines.map { lines[$0] }
            // Placed where the text's ink was, which a box too tall for its text would put too low.
            var box = units[unit.index].box
            let inked = unit.colors.compactMap(\.inkRows)
            if let top = inked.map(\.lowerBound).min(), let bottom = inked.map(\.upperBound).max(), bottom > top {
                box = CGRect(x: box.minX, y: top, width: box.width, height: bottom - top)
            }
            // On its column's left edge: Vision's boxes start a few pixels apart on lines that align.
            let left = lefts[units[unit.index].lines[0]]
            box = CGRect(x: left, y: box.minY, width: box.maxX - left, height: box.height)
            let layout = Self.layout(
                unit.text, box: box, room: unit.room, members: members, size: unit.size, bold: unit.bold,
                language: language, color: unit.colors[0].ink
            )
            if layout.truncated { truncated.insert(unit.index) }
            context.saveGState()
            context.textMatrix = .identity
            for (line, origin) in zip(layout.lines, layout.origins) {
                // The ink on the edge, not the pen: a glyph's side bearing would set it in a little. Right
                // to left, the line ends at the box's right edge. (Measured from the glyphs' outlines, not
                // with `CTLineGetImageBounds`, which counts in the context's text position, by then at the
                // end of the line before.)
                let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                let x = ink.isNull || ink.isEmpty ? origin.x : rightToLeft ? box.maxX - ink.maxX : box.minX - ink.minX
                context.textPosition = CGPoint(x: x, y: CGFloat(height) - origin.y)
                CTLineDraw(line, context)
            }
            context.restoreGState()
        }
        guard let rendered = context.makeImage() else { return nil }
        return Rendering(image: rendered, truncated: truncated)
    }

    private struct Drawn {
        let index: Int
        let text: String
        let colors: [LineColors]
        let room: CGFloat
        let size: CGFloat
        let bold: Bool
    }

    /// What is painted over to hide a line: its box and a little more, for the descenders and accents
    /// Vision's box leaves out, but never into a line that stays.
    static func erasure(of box: CGRect, keeping kept: [CGRect]) -> CGRect {
        var top = box.minY - box.height * 0.12
        var bottom = box.maxY + box.height * 0.12
        for other in kept where other.minX < box.maxX && other.maxX > box.minX {
            if other.maxY <= box.minY + 1 { top = max(top, other.maxY) }
            if other.minY >= box.maxY - 1 { bottom = min(bottom, other.minY) }
        }
        return CGRect(x: box.minX - 2, y: min(top, box.minY), width: box.width + 4, height: max(bottom, box.maxY) - min(top, box.minY))
    }

    /// Each line's column's left edge: lines one under the next whose left edges are within a third of a
    /// line of each other make a column, and all of them take the median of its `edges` (where each
    /// line's ink starts; its box's edge when not given), so lines that were flush stay flush (Vision's
    /// boxes start a few pixels apart on them).
    static func columnLefts(_ boxes: [CGRect], sizes: [CGFloat], edges: [CGFloat]? = nil) -> [CGFloat] {
        let edges = edges ?? boxes.map(\.minX)
        var parent = Array(boxes.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        for a in boxes.indices {
            for b in boxes.indices where b > a {
                let size = min(sizes[a], sizes[b])
                let gap = max(boxes[a].minY - boxes[b].maxY, boxes[b].minY - boxes[a].maxY)
                if abs(boxes[a].minX - boxes[b].minX) <= size / 3, gap < size * 1.5 { parent[root(a)] = root(b) }
            }
        }
        var columns: [Int: [Int]] = [:]
        for index in boxes.indices { columns[root(index), default: []].append(index) }
        var lefts = edges
        for members in columns.values {
            guard let left = median(members.map { edges[$0] }) else { continue }
            for index in members { lefts[index] = left }
        }
        return lefts
    }

    /// The first column of ink in `box`, looked for within a line's height of its left edge: the first
    /// one with a pixel clearly unlike the box's surroundings.
    static func inkLeft(of box: CGRect, in pixels: Pixels) -> CGFloat? {
        let outer = box.insetBy(dx: -2, dy: -2).integral.intersection(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        guard !outer.isNull, outer.width >= 3, outer.height >= 3 else { return nil }
        let left = Int(outer.minX), right = Int(outer.maxX) - 1, top = Int(outer.minY), bottom = Int(outer.maxY) - 1
        var border: [(Int, Int, Int)] = []
        for x in left...right { border.append(pixels.rgb(x, top)); border.append(pixels.rgb(x, bottom)) }
        for y in top...bottom { border.append(pixels.rgb(left, y)); border.append(pixels.rgb(right, y)) }
        func channel(_ pick: ((Int, Int, Int)) -> Int) -> Int { border.map(pick).sorted()[border.count / 2] }
        let paper = (channel { $0.0 }, channel { $0.1 }, channel { $0.2 })
        let end = min(right, left + 1 + Int(box.height * 1.5))
        guard left + 1 < end else { return nil }
        for x in (left + 1)..<end {
            for y in (top + 1)..<bottom where LineColors.distance(pixels.rgb(x, y), paper) > LineColors.inkDistance {
                return CGFloat(x)
            }
        }
        return nil
    }

    // MARK: Size

    /// The type size of a line in pixels, from its width: Vision's box is as wide as the text set in the
    /// system font to within 2%, while its height runs from 0.87 to 1.24 times the size (capitals alone
    /// to Chinese with punctuation; measured). The width is measured again at the size found, in points
    /// on screen (`scale` pixels each): the system font is drawn wider at text sizes than at display
    /// sizes, by about a tenth. The height only bounds the result, for a line misread or set in another
    /// font, and loosely: Vision's box is sometimes half again as tall as the text in it.
    static func typeSize(of line: OCRLine, scale: CGFloat = 1) -> CGFloat {
        let height = line.box.height
        func width(at points: CGFloat) -> CGFloat {
            let font = CTFontCreateUIFontForLanguage(.system, points, nil) ?? CTFontCreateWithName("Helvetica" as CFString, points, nil)
            let probe = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ]))
            return CGFloat(CTLineGetTypographicBounds(probe, nil, nil, nil))
        }
        let scale = max(scale, 1)
        let rough = width(at: 100)
        guard rough > 0 else { return height * 0.95 }
        // Points on screen at the first guess, then measured at that size.
        let guess = max(line.box.width / scale / rough * 100, 4)
        let measured = width(at: guess)
        let size = measured > 0 ? guess * (line.box.width / scale) / measured * scale : guess * scale
        return min(max(size, height * 0.6), height * 1.25)
    }

    /// Sizes made one where lines belong together: lines of a column (left edges aligned, one under the
    /// next) or of a row (side by side) within 15% of each other take their median. A page repeats a
    /// style in such runs (a sidebar, a list, a table row), and the estimates of one style vary by a few
    /// percent from line to line, enough to make a sidebar's items look uneven. Only neighbors are
    /// joined, so sizes a little apart at each step never run together across the page.
    static func harmonized(_ sizes: [CGFloat], boxes: [CGRect]) -> [CGFloat] {
        var parent = Array(sizes.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        for a in sizes.indices {
            for b in sizes.indices where b > a {
                let size = min(sizes[a], sizes[b])
                guard size > 0, max(sizes[a], sizes[b]) <= size * 1.15 else { continue }
                let (first, second) = (boxes[a], boxes[b])
                let verticalGap = max(first.minY - second.maxY, second.minY - first.maxY)
                let horizontalGap = max(first.minX - second.maxX, second.minX - first.maxX)
                let column = abs(first.minX - second.minX) <= size * 0.5 && verticalGap < size * 1.5
                let row = abs(first.midY - second.midY) <= size * 0.3 && horizontalGap < size * 12
                if column || row { parent[root(a)] = root(b) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for index in sizes.indices { groups[root(index), default: []].append(index) }
        var result = sizes
        for members in groups.values {
            guard let middle = median(members.map { sizes[$0] }) else { continue }
            for index in members { result[index] = middle }
        }
        return result
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    // MARK: Layout

    struct Layout {
        var lines: [CTLine]
        /// Each line's baseline origin, in image pixels with a top-left origin.
        var origins: [CGPoint]
        var scale: CGFloat
        var truncated: Bool
    }

    /// How far right a unit's translation may run: to the next text on its row, or near the image's edge.
    static func room(for box: CGRect, beside others: [CGRect], imageWidth: CGFloat) -> CGFloat {
        let margin = box.height * 0.5
        let limit = others
            .filter { $0.minY < box.maxY && $0.maxY > box.minY && $0.minX >= box.maxX - 1 }
            .map { $0.minX - margin }
            .min() ?? (imageWidth - margin)
        return max(box.width, limit - box.minX)
    }

    /// `room`, or less: up to the first thing beside the line that is not its background (an icon, a
    /// button's edge), so a translation running on never covers it.
    static func clear(_ room: CGFloat, beside box: CGRect, of paper: (Int, Int, Int), in pixels: Pixels) -> CGFloat {
        guard room > box.width else { return room }
        let top = max(0, Int(box.minY)), bottom = min(pixels.height, Int(box.maxY.rounded(.up)))
        // A few pixels clear of the box, whose edge can cut the last stroke.
        let start = max(0, Int(box.maxX.rounded(.up)) + 3), end = min(pixels.width, Int((box.minX + room).rounded(.down)))
        guard top < bottom, start < end else { return box.width }
        for x in start..<end {
            for y in top..<bottom where LineColors.distance(pixels.rgb(x, y), paper) > LineColors.inkDistance {
                return max(box.width, CGFloat(x) - box.height * 0.5 - box.minX)
            }
        }
        return room
    }

    /// The translation set in `box` at `size`: as is if it fits, a little smaller if that is enough;
    /// then a line on its own may run on into the room beside it (a paragraph keeps its column) while
    /// shrinking to 70%; after that it is cut short. Lines keep the original's spacing, scaled with the
    /// type, and no more of them fit than the original had.
    static func layout(
        _ text: String, box: CGRect, room: CGFloat, members: [OCRLine], size: CGFloat, bold: Bool = false,
        language: Locale.Language, color: CGColor
    ) -> Layout {
        let pitch = members.count > 1
            ? (members[members.count - 1].box.midY - members[0].box.midY) / CGFloat(members.count - 1)
            : box.height
        // The height the original lines took, line to line, with a little to spare.
        let capacity = (CGFloat(members.count) + 0.1) * pitch
        let width = members.count > 1 ? box.width : room
        var steps: [(scale: CGFloat, width: CGFloat)] = [(1, box.width), (0.95, box.width), (0.9, box.width)]
        if width > box.width {
            for scale in stride(from: 1, through: minimumScale - 0.001, by: -0.05) { steps.append((scale, width)) }
        } else {
            for scale in stride(from: 0.85, through: minimumScale - 0.001, by: -0.05) { steps.append((scale, width)) }
        }
        for step in steps {
            let lines = typeset(text, font: font(size: size * step.scale, bold: bold, language: language), width: step.width, color: color)
            if CGFloat(lines.count) * pitch * step.scale <= capacity {
                return place(lines, in: box, pitch: pitch * step.scale, scale: step.scale, truncated: false)
            }
        }
        // Cut short: as many lines as the box holds, the last one ending in an ellipsis.
        let small = font(size: size * minimumScale, bold: bold, language: language)
        let linePitch = pitch * minimumScale
        var lines = typeset(text, font: small, width: width, color: color)
        let fitting = max(1, Int(capacity / linePitch))
        if lines.count > fitting {
            let lastRange = CTLineGetStringRange(lines[fitting - 1])
            let rest = (text as NSString).substring(from: lastRange.location)
            let full = CTLineCreateWithAttributedString(attributedString(rest, font: small, color: color))
            let ellipsis = CTLineCreateWithAttributedString(attributedString("…", font: small, color: color))
            lines = Array(lines.prefix(fitting - 1)) + [CTLineCreateTruncatedLine(full, Double(width), .end, ellipsis) ?? full]
        }
        return place(lines, in: box, pitch: linePitch, scale: minimumScale, truncated: true)
    }

    /// The system font for the target language (Chinese in PingFang, Japanese in Hiragino), semibold for
    /// a heading.
    static func font(size: CGFloat, bold: Bool, language: Locale.Language) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, Translator.identifier(of: language) as CFString)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func typeset(_ text: String, font: CTFont, width: CGFloat, color: CGColor) -> [CTLine] {
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString(text, font: font, color: color))
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: max(width, CTFontGetSize(font)), height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        return (CTFrameGetLines(frame) as? [CTLine]) ?? []
    }

    private static func attributedString(_ text: String, font: CTFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
    }

    /// Lines stacked at `pitch` from the box's left edge, the block centered in the box's height.
    private static func place(_ lines: [CTLine], in box: CGRect, pitch: CGFloat, scale: CGFloat, truncated: Bool) -> Layout {
        let top = box.midY - CGFloat(lines.count) * pitch / 2
        let origins = lines.indices.map { index -> CGPoint in
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(lines[index], &ascent, &descent, &leading)
            // The baseline sits where the line's type is centered in its slot.
            let slotMiddle = top + pitch * (CGFloat(index) + 0.5)
            return CGPoint(x: box.minX, y: slotMiddle + (ascent - descent) / 2)
        }
        return Layout(lines: lines, origins: origins, scale: scale, truncated: truncated)
    }
}

/// The pixels of an RGBA bitmap, read in place.
struct Pixels {
    let base: UnsafeMutablePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int

    /// The color at `x`, `y` (top-left origin), as red, green, blue from 0 to 255.
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        // A bitmap context's first row is the image's top.
        let offset = y * bytesPerRow + x * 4
        return (Int(base[offset]), Int(base[offset + 1]), Int(base[offset + 2]))
    }
}

/// A line's background and ink, measured: the background is the median of the pixels just outside the
/// line's box; the ink, the median of the inkiest half of the pixels inside it that differ clearly from
/// that background (the rest are the antialiased edges of strokes, part background).
struct LineColors {
    let background: CGColor
    let ink: CGColor
    /// The background as measured, red, green, blue from 0 to 255.
    let paper: (Int, Int, Int)
    /// The rows the text's ink covers, top to bottom, in image pixels; nil when none stood out.
    let inkRows: ClosedRange<CGFloat>?

    /// How far from the background a pixel must be to count as ink: summed over the channels, about
    /// half of black on white once antialiasing is allowed for.
    static let inkDistance = 120

    static func distance(_ pixel: (Int, Int, Int), _ other: (Int, Int, Int)) -> Int {
        abs(pixel.0 - other.0) + abs(pixel.1 - other.1) + abs(pixel.2 - other.2)
    }

    init(pixels: Pixels, box: CGRect) {
        let outer = box.insetBy(dx: -2, dy: -2).integral.intersection(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        guard !outer.isNull, outer.width >= 3, outer.height >= 3 else {
            background = CGColor(gray: 1, alpha: 1)
            ink = CGColor(gray: 0, alpha: 1)
            paper = (255, 255, 255)
            inkRows = nil
            return
        }
        let left = Int(outer.minX), right = Int(outer.maxX) - 1, top = Int(outer.minY), bottom = Int(outer.maxY) - 1
        var border: [(Int, Int, Int)] = []
        for x in left...right { border.append(pixels.rgb(x, top)); border.append(pixels.rgb(x, bottom)) }
        for y in top...bottom { border.append(pixels.rgb(left, y)); border.append(pixels.rgb(right, y)) }
        let paper = Self.median(border)
        self.paper = paper
        var inked: [(pixel: (Int, Int, Int), distance: Int)] = []
        var firstRow: Int?
        var lastRow: Int?
        for y in (top + 1)..<bottom {
            for x in (left + 1)..<right {
                let pixel = pixels.rgb(x, y)
                let away = Self.distance(pixel, paper)
                if away > Self.inkDistance {
                    inked.append((pixel, away))
                    if firstRow == nil { firstRow = y }
                    lastRow = y
                }
            }
        }
        inkRows = firstRow.flatMap { first in lastRow.map { CGFloat(first)...CGFloat($0 + 1) } }
        background = Self.color(paper)
        if inked.isEmpty {
            // Faint text: black on light, white on dark.
            let light = paper.0 + paper.1 + paper.2 > 3 * 128
            ink = CGColor(gray: light ? 0 : 1, alpha: 1)
        } else {
            let inkiest = inked.sorted { $0.distance > $1.distance }.prefix(max(1, inked.count / 2)).map(\.pixel)
            ink = Self.color(Self.median(Array(inkiest)))
        }
    }

    private static func median(_ values: [(Int, Int, Int)]) -> (Int, Int, Int) {
        func channel(_ pick: ((Int, Int, Int)) -> Int) -> Int {
            let sorted = values.map(pick).sorted()
            return sorted[sorted.count / 2]
        }
        return (channel { $0.0 }, channel { $0.1 }, channel { $0.2 })
    }

    private static func color(_ rgb: (Int, Int, Int)) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
    }
}
