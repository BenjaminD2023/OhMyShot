import CoreGraphics
import Foundation

/// List items: a line that starts with a bullet, read as a character or seen in the pixels just left of the line.
///
/// A bullet starts an item, whatever the line before it says, and the lines under its text, indented past the bullet,
/// carry the item on (`TextAssembler.inferredWraps`). A bullet read as text is taken off before the item is translated
/// and drawn again in front of the translation; one seen only in the pixels lies outside the line's box, so the
/// translation leaves it where it is. The rules follow SnowAir's list handling (Apache-2.0), measured afresh here.
enum Bullets {
    /// The characters read as a bullet at the start of a line.
    static let marks: Set<Character> = ["•", "·", "●", "○", "▪", "◦", "※", "◆", "◇", "■", "□", "‣", "⁃"]

    /// What a translation of a bulleted item starts with: a bullet and two spaces.
    static let drawnMark = "•  "

    /// The line's text with a bullet read at its start taken off, or nil when it starts with none. A bullet must stand
    /// apart: "·" in "·5" is not one, and a line of bullets alone is no item.
    static func strippingMark(from text: String) -> String? {
        let trimmed = text.drop { $0 == " " }
        guard let first = trimmed.first, marks.contains(first) else { return nil }
        let rest = trimmed.dropFirst()
        guard let next = rest.first, next == " " || next == "\u{3000}" || Script.isCJK(next) || next.isLetter else { return nil }
        let words = rest.drop { $0 == " " || $0 == "\u{3000}" }
        return words.isEmpty ? nil : String(words)
    }

    /// Where a bullet drawn just left of `box` lies, in image pixels, or nil when there is none. Looked for from two
    /// line heights left of the box to a little inside it, over the line's rows: the background is the median of that
    /// strip's edge, and ink is what differs from it by more than 40 in brightness. The ink splits into groups at gaps
    /// of two blank columns; a group that ends before a third of a line into the box is a bullet when it is at most
    /// half a line wide and 0.55 of a line tall (and no speck, at least 0.12 of a line), about as wide as tall, its
    /// middle between a quarter and 0.72 of the line down, with a gap of at least 0.18 of a line before the next ink.
    /// SnowAir allows the middle from 0.18 to 0.85 of the line; that takes in a period on the baseline, the end of a
    /// column of text to the left, so here the middle stays nearer the middle of the line, where bullets are set.
    static func pixelBullet(leftOf box: CGRect, in pixels: Pixels) -> CGRect? {
        let height = box.height
        guard height >= 6 else { return nil }
        let left = max(0, Int((box.minX - height * 2).rounded(.down)))
        let right = min(pixels.width - 1, Int((box.minX + height * 0.8).rounded(.up)))
        let top = max(0, Int(box.minY.rounded(.down))), bottom = min(pixels.height - 1, Int(box.maxY.rounded(.up)) - 1)
        guard right - left >= 4, bottom - top >= 4 else { return nil }
        func brightness(_ x: Int, _ y: Int) -> Int {
            let (r, g, b) = pixels.rgb(x, y)
            return (r * 299 + g * 587 + b * 114) / 1000
        }
        var edge: [Int] = []
        for x in left...right { edge.append(brightness(x, top)); edge.append(brightness(x, bottom)) }
        for y in top...bottom { edge.append(brightness(left, y)); edge.append(brightness(right, y)) }
        let background = edge.sorted()[edge.count / 2]
        // Each column's ink rows.
        var columns: [(x: Int, top: Int, bottom: Int)?] = []
        for x in left...right {
            var first: Int?, last: Int?
            for y in top...bottom where abs(brightness(x, y) - background) > 40 {
                if first == nil { first = y }
                last = y
            }
            columns.append(first.flatMap { f in last.map { (x, f, $0) } })
        }
        // Groups of inked columns, split by two blank columns or more.
        var groups: [(minX: Int, maxX: Int, minY: Int, maxY: Int)] = []
        var blank = 2
        for column in columns {
            guard let column else { blank += 1; continue }
            if blank >= 2 || groups.isEmpty {
                groups.append((column.x, column.x, column.top, column.bottom))
            } else {
                let last = groups.removeLast()
                groups.append((last.minX, column.x, min(last.minY, column.top), max(last.maxY, column.bottom)))
            }
            blank = 0
        }
        let limit = box.minX + height * 0.35
        for (index, group) in groups.enumerated() {
            guard CGFloat(group.maxX) < limit else { break }
            let width = CGFloat(group.maxX - group.minX + 1), tall = CGFloat(group.maxY - group.minY + 1)
            let middle = (CGFloat(group.minY + group.maxY) / 2 + 0.5 - box.minY) / height
            guard index + 1 < groups.count else { continue }
            let gap = CGFloat(groups[index + 1].minX - group.maxX - 1)
            let round = width <= tall * 2 && tall <= width * 2
            if width <= height * 0.5, tall <= height * 0.55, tall >= height * 0.12, round, middle >= 0.25, middle <= 0.72,
               gap >= max(2, height * 0.18) {
                return CGRect(x: CGFloat(group.minX), y: CGFloat(group.minY), width: width, height: tall)
            }
        }
        return nil
    }

    /// Which `lines` start a list item: a bullet read at the start of their text, or one seen in `pixels` just left of
    /// their box (nil: text alone).
    static func items(_ lines: [OCRLine], in pixels: Pixels? = nil) -> [Bool] {
        lines.map { line in
            strippingMark(from: line.text) != nil || pixels.map { pixelBullet(leftOf: line.box, in: $0) != nil } ?? false
        }
    }
}
