import CoreGraphics
import CoreText
import Foundation

/// The image with each translated unit drawn where its text was, as Live Text's translation does: every
/// original line is painted over with its own background, then the translation is laid out across the
/// unit's box in the original text's color and size, aligned as its lines were (`alignments`). When it does not
/// fit, a translation into a language of words (English, French…) first runs on into the clear room to its right
/// and the blank rows under it, as SnowAir lays translations out, and only then shrinks; Chinese, Japanese and
/// Korean shrink in place. Neither goes below 70% of the original size, nor below a readable 12 pt (13 pt for
/// CJK) unless the page is of small text throughout; after that it is cut short with an ellipsis. A unit cut short
/// is reported, so the full translation can be shown elsewhere.
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
        // A line holding a formula tells its size less well than one of words alone: the formula is set in another face,
        // its scripts smaller (`typeSize`). Lines of words alone say the body's size where there are a few; two could be a
        // heading and one more line, and the body would read as the heading's size.
        let words = lines.indices.filter { lines[$0].math == nil }
        let bodySize = median((words.count < 3 ? Array(lines.indices) : words).map { sizes[$0] }) ?? 0
        let rightToLeft = language.characterDirection == .rightToLeft
        let widens = !Self.isCJK(language)
        let floor = Self.readableFloor(for: language, scale: scale, sizes: (words.isEmpty ? Array(lines.indices) : words).map { sizes[$0] })
        let aligns = Self.alignments(lines.map(\.box), sizes: sizes)
        // Colors and room first, while every pixel is still the original.
        let drawn = units.indices.compactMap { index -> Drawn? in
            let unit = units[index]
            guard let text = translations[index], text != unit.text, !unit.lines.isEmpty else { return nil }
            let colors = unit.lines.map { LineColors(pixels: pixels, box: lines[$0].box) }
            let members = Set(unit.lines)
            let others = lines.indices.filter { !members.contains($0) }.map { lines[$0].box }
            // Centered or right-aligned lines keep their place: only text set flush left runs on to the right.
            let alignment = rightToLeft ? Alignment.right : unit.lines.allSatisfy({ aligns[$0] == .center }) ? .center : aligns[unit.lines[0]]
            var room = unit.box.width
            // A line on its own may run on into the room beside it; a paragraph keeps its column unless its language
            // is one of words, which reads better wider than smaller.
            if alignment == .left, unit.lines.count == 1 || widens {
                room = clear(Self.room(for: unit.box, beside: others, imageWidth: CGFloat(width)), beside: unit.box, of: colors[0].paper, in: pixels)
            }
            let lastLine = lines[unit.lines[unit.lines.count - 1]].box.height
            let below = widens ? Self.blankBelow(unit.box, lineHeight: lastLine, width: room, beside: others, of: colors[colors.count - 1].paper, in: pixels) : 0
            let wordLines = unit.lines.filter { lines[$0].math == nil }
            let size = median((wordLines.isEmpty ? unit.lines : wordLines).map { sizes[$0] }) ?? unit.box.height
            // A heading: a third larger than the body or more. Its weight cannot be read from its pixels
            // reliably (bold Latin is wider, so it reads as a larger size instead), but headings are set
            // bold far more often than not.
            let isHeading = unit.lines.count <= 2 && size >= bodySize * 1.3
            // A formula drawn as its LaTeX would read as code: drawn readable instead (the text copied keeps the LaTeX).
            var drawnText = unit.hasMath ? MathText.readable(in: text) : text
            // A bullet read as text was painted over with the line: it comes back in front of the translation.
            if unit.bulleted { drawnText = Bullets.drawnMark + drawnText }
            return Drawn(
                index: index, text: drawnText, colors: colors, room: room, below: below, size: size, bold: isHeading,
                alignment: alignment, minimumScale: floor.map { max(Self.minimumScale, min(1, $0 / size)) } ?? Self.minimumScale
            )
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
            if unit.alignment == .left {
                let left = lefts[units[unit.index].lines[0]]
                box = CGRect(x: left, y: box.minY, width: box.maxX - left, height: box.height)
            }
            let layout = Self.layout(
                unit.text, box: box, room: unit.room, members: members, size: unit.size, bold: unit.bold,
                language: language, color: unit.colors[0].ink, minimumScale: unit.minimumScale, widens: widens, below: unit.below
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
                let x: CGFloat = if ink.isNull || ink.isEmpty {
                    origin.x
                } else {
                    switch unit.alignment {
                    case .left: box.minX - ink.minX
                    case .center: box.midX - ink.midX
                    case .right: box.maxX - ink.maxX
                    }
                }
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
        /// Blank height under the unit the translation may grow into, in pixels.
        let below: CGFloat
        let size: CGFloat
        let bold: Bool
        let alignment: Alignment
        let minimumScale: CGFloat
    }

    enum Alignment: Equatable {
        case left, center, right
    }

    /// Whether `language` is written in Chinese, Japanese or Korean, which shrink in place rather than run on.
    static func isCJK(_ language: Locale.Language) -> Bool {
        ["zh", "ja", "ko"].contains(language.languageCode?.identifier ?? "")
    }

    /// The smallest size a translation is drawn at, in pixels: 12 pt on screen, 13 pt for Chinese, Japanese and
    /// Korean, whose strokes need it; nil when four fifths of the page's lines of words are already smaller (a
    /// page of small print stays as it is, and only the share of the original holds).
    static func readableFloor(for language: Locale.Language, scale: CGFloat, sizes: [CGFloat]) -> CGFloat? {
        let floor = (isCJK(language) ? 13 : 12) * max(scale, 1)
        guard !sizes.isEmpty else { return floor }
        let smaller = sizes.filter { $0 < floor }.count
        return Double(smaller) >= Double(sizes.count) * 0.8 ? nil : floor
    }

    /// How each line is aligned, told by how the lines of its block agree, as SnowAir reads alignment: a block is
    /// lines one under the next (less than one and a half lines apart) whose spans overlap. Within a block, edges
    /// and middles within 3% of its width (2 px at least) go together. The block is centered when the largest group
    /// of middles holds two lines or more and beats the largest groups of left and right edges, both edges sit well
    /// inside it (6% of its width), and about as far (within a tenth of its width). Otherwise a line is left aligned
    /// when its left edge is shared, right aligned when its right edge is, or when it ends at the block's right edge
    /// while being clearly shorter than the block; else left. A line on its own is left aligned.
    static func alignments(_ boxes: [CGRect], sizes: [CGFloat]) -> [Alignment] {
        var blocks = DisjointSets(count: boxes.count)
        for a in boxes.indices {
            for b in boxes.indices where b > a {
                let size = max(min(sizes[a], sizes[b]), 1)
                let gap = max(boxes[a].minY - boxes[b].maxY, boxes[b].minY - boxes[a].maxY)
                let overlap = min(boxes[a].maxX, boxes[b].maxX) - max(boxes[a].minX, boxes[b].minX)
                if gap < size * 1.5, overlap > 0 { blocks.join(a, b) }
            }
        }
        var result = Array(repeating: Alignment.left, count: boxes.count)
        for members in blocks.groups where members.count >= 2 {
            let block = members.dropFirst().reduce(boxes[members[0]]) { $0.union(boxes[$1]) }
            let width = block.width
            let tolerance = max(2, width * 0.03)
            // How many lines share each line's value, first come first grouped.
            func shared(_ value: (CGRect) -> CGFloat) -> [Int: Int] {
                var groups: [(value: CGFloat, members: [Int])] = []
                for member in members {
                    let v = value(boxes[member])
                    if let index = groups.firstIndex(where: { abs($0.value - v) <= tolerance }) {
                        groups[index].members.append(member)
                    } else {
                        groups.append((v, [member]))
                    }
                }
                var counts: [Int: Int] = [:]
                for group in groups { for member in group.members { counts[member] = group.members.count } }
                return counts
            }
            let lefts = shared(\.minX), rights = shared(\.maxX), middles = shared(\.midX)
            let largest = { (counts: [Int: Int]) in counts.values.max() ?? 0 }
            let leftInset = median(members.map { boxes[$0].minX - block.minX }) ?? 0
            let rightInset = median(members.map { block.maxX - boxes[$0].maxX }) ?? 0
            let inset = max(3, width * 0.06)
            let centered = largest(middles) >= 2 && largest(middles) > largest(lefts) && largest(middles) > largest(rights)
                && leftInset > inset && rightInset > inset && abs(leftInset - rightInset) <= max(width * 0.1, 6)
            for member in members {
                let box = boxes[member]
                if centered {
                    result[member] = .center
                } else if lefts[member, default: 1] >= 2 {
                    result[member] = .left
                } else if rights[member, default: 1] >= 2 || (block.maxX - box.maxX <= max(3, width * 0.05) && box.width < width * 0.85) {
                    result[member] = .right
                }
            }
        }
        return result
    }

    /// How far down from `box` a translation may grow over the image's own background: the blank rows under it,
    /// across `width` from its left edge, before the next line below or the first ink, less a third of a line
    /// (`lineHeight`) to spare; at most as tall again as the box, or two lines for a short one. Zero when there is no
    /// blank room.
    static func blankBelow(_ box: CGRect, lineHeight: CGFloat, width: CGFloat, beside others: [CGRect], of paper: (Int, Int, Int), in pixels: Pixels) -> CGFloat {
        let span = box.minX..<(box.minX + max(width, box.width))
        let spare = lineHeight / 3
        var limit = min(CGFloat(pixels.height), box.maxY + max(box.height, lineHeight * 2))
        for other in others where other.minY >= box.maxY - 1 && other.maxX > span.lowerBound && other.minX < span.upperBound {
            limit = min(limit, other.minY)
        }
        let left = max(0, Int(span.lowerBound.rounded(.down))), right = min(pixels.width, Int(span.upperBound.rounded(.up)))
        let start = Int(box.maxY.rounded(.up)) + 2, end = Int(limit.rounded(.down))
        guard left < right, start < end else { return 0 }
        var lastBlank = start
        rows: for y in start..<end {
            for x in left..<right where LineColors.distance(pixels.rgb(x, y), paper) > LineColors.inkDistance {
                break rows
            }
            lastBlank = y + 1
        }
        return max(0, CGFloat(lastBlank) - box.maxY - spare)
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
        var columns = DisjointSets(count: boxes.count)
        for a in boxes.indices {
            for b in boxes.indices where b > a {
                let size = min(sizes[a], sizes[b])
                let gap = max(boxes[a].minY - boxes[b].maxY, boxes[b].minY - boxes[a].maxY)
                if abs(boxes[a].minX - boxes[b].minX) <= size / 3, gap < size * 1.5 { columns.join(a, b) }
            }
        }
        var lefts = edges
        for members in columns.groups {
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
    /// font, and loosely: Vision's box is sometimes half again as tall as the text in it. A formula in the line is
    /// measured as it is drawn readable (`MathText`), not as its LaTeX, which runs several times as wide as its ink.
    static func typeSize(of line: OCRLine, scale: CGFloat = 1) -> CGFloat {
        let height = line.box.height
        let text = line.math == nil ? line.text : MathText.readable(in: line.text)
        func width(at points: CGFloat) -> CGFloat {
            let font = CTFontCreateUIFontForLanguage(.system, points, nil) ?? CTFontCreateWithName("Helvetica" as CFString, points, nil)
            let probe = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
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
        var sets = DisjointSets(count: sizes.count)
        for a in sizes.indices {
            for b in sizes.indices where b > a {
                let size = min(sizes[a], sizes[b])
                guard size > 0, max(sizes[a], sizes[b]) <= size * 1.15 else { continue }
                let (first, second) = (boxes[a], boxes[b])
                let verticalGap = max(first.minY - second.maxY, second.minY - first.maxY)
                let horizontalGap = max(first.minX - second.maxX, second.minX - first.maxX)
                let column = abs(first.minX - second.minX) <= size * 0.5 && verticalGap < size * 1.5
                let row = abs(first.midY - second.midY) <= size * 0.3 && horizontalGap < size * 12
                if column || row { sets.join(a, b) }
            }
        }
        var result = sizes
        for members in sets.groups {
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

    /// The translation set in `box` at `size`: as is if it fits, a little smaller if that is enough. Then, for a
    /// language of words (`widens`), it runs on to the right into `room`, only as far as it needs, then down into the
    /// blank height `below` the box, and only then shrinks, no smaller than `minimumScale`. Otherwise a line on its
    /// own runs on into `room` while shrinking, and a paragraph keeps its column and shrinks. After that it is cut
    /// short. Lines keep the original's spacing, scaled with the type, and no more of them fit than the original had,
    /// with the room below added.
    static func layout(
        _ text: String, box: CGRect, room: CGFloat, members: [OCRLine], size: CGFloat, bold: Bool = false,
        language: Locale.Language, color: CGColor, minimumScale: CGFloat = Self.minimumScale, widens: Bool = false, below: CGFloat = 0
    ) -> Layout {
        let pitch = members.count > 1
            ? (members[members.count - 1].box.midY - members[0].box.midY) / CGFloat(members.count - 1)
            : box.height
        // The height the original lines took, line to line, with a little to spare.
        let capacity = (CGFloat(members.count) + 0.1) * pitch
        let width = members.count > 1 && !widens ? box.width : max(room, box.width)
        var steps: [(scale: CGFloat, width: CGFloat, capacity: CGFloat)] = [(1, box.width, capacity), (0.95, box.width, capacity)]
        if widens {
            // No wider than it needs: the column it was in, a little at a time, then all the room.
            for factor in [1.15, 1.3, 1.5, 1.75, 2.0, 2.5] where box.width * factor < width { steps.append((1, box.width * factor, capacity)) }
            if width > box.width { steps.append((1, width, capacity)) }
            if below > 0 { steps.append((1, width, capacity + below)) }
            for scale in stride(from: 0.95, through: minimumScale - 0.001, by: -0.05) { steps.append((scale, width, capacity + below)) }
        } else {
            steps.append((0.9, box.width, capacity))
            let first: CGFloat = width > box.width ? 1 : 0.85
            for scale in stride(from: first, through: minimumScale - 0.001, by: -0.05) { steps.append((scale, width, capacity)) }
        }
        for step in steps where step.scale >= minimumScale - 0.001 {
            let lines = typeset(text, font: font(size: size * step.scale, bold: bold, language: language), width: step.width, color: color)
            if CGFloat(lines.count) * pitch * step.scale <= step.capacity {
                let grows = CGFloat(lines.count) * pitch * step.scale > capacity
                return place(lines, in: box, pitch: pitch * step.scale, scale: step.scale, truncated: false, fromTop: grows)
            }
        }
        // Cut short: as many lines as the box (and the room below) holds, the last one ending in an ellipsis.
        let small = font(size: size * minimumScale, bold: bold, language: language)
        let linePitch = pitch * minimumScale
        var lines = typeset(text, font: small, width: width, color: color)
        let fitting = max(1, Int((capacity + (widens ? below : 0)) / linePitch))
        if lines.count > fitting {
            let lastRange = CTLineGetStringRange(lines[fitting - 1])
            let rest = (text as NSString).substring(from: lastRange.location)
            let full = CTLineCreateWithAttributedString(attributedString(rest, font: small, color: color))
            let ellipsis = CTLineCreateWithAttributedString(attributedString("…", font: small, color: color))
            lines = Array(lines.prefix(fitting - 1)) + [CTLineCreateTruncatedLine(full, Double(width), .end, ellipsis) ?? full]
        }
        return place(lines, in: box, pitch: linePitch, scale: minimumScale, truncated: true, fromTop: CGFloat(lines.count) * linePitch > capacity)
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

    /// Lines stacked at `pitch` from the box's left edge, the block centered in the box's height, or, grown into the
    /// room below (`fromTop`), from the box's top.
    private static func place(_ lines: [CTLine], in box: CGRect, pitch: CGFloat, scale: CGFloat, truncated: Bool, fromTop: Bool = false) -> Layout {
        let height = CGFloat(lines.count) * pitch
        let top = fromTop ? box.minY : box.midY - height / 2
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

    /// `body` given `image`'s pixels, drawn into a bitmap of their own for the while; nil when no bitmap could be made.
    static func reading<T>(_ image: CGImage, _ body: (Pixels) -> T) -> T? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return body(Pixels(base: data.assumingMemoryBound(to: UInt8.self), width: image.width, height: image.height, bytesPerRow: context.bytesPerRow))
    }

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
