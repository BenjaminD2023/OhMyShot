import CoreGraphics
import Foundation

/// The rounded corners of a window that the area shares with it. Past them shows what is behind the window (nothing,
/// for a window streamed on its own), which stays where it is on screen while the content scrolls, so the first view's
/// corners were kept in the picture where columns stay put. Each view's pixels past the window's shape are filled from
/// the first pixel within it further in along the same column, so they show what the column shows there (the same, in
/// a column that stays put) and go along with the content as the rest of the column does. The picture's corners come
/// out square.
nonisolated public struct ViewCorners: Sendable, Equatable {
    public enum Corner: CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Per corner, for each row from the view's top or bottom edge (the outermost first), how many pixels from the side
    /// are past the shape: never more for a row further in, and none past the last.
    public private(set) var topLeft: [Int]
    public private(set) var topRight: [Int]
    public private(set) var bottomLeft: [Int]
    public private(set) var bottomRight: [Int]

    public init(topLeft: [Int] = [], topRight: [Int] = [], bottomLeft: [Int] = [], bottomRight: [Int] = []) {
        self.topLeft = Self.clean(topLeft)
        self.topRight = Self.clean(topRight)
        self.bottomLeft = Self.clean(bottomLeft)
        self.bottomRight = Self.clean(bottomRight)
    }

    /// The corners' shape in `image`'s alpha (a window captured on its own, no shadow): for each corner, the pixels
    /// not wholly opaque from the side, row by row in from the edge, up to `most` rows and pixels. A corner that is not
    /// a clean rounded one (square; or see-through further than `most`, as a translucent sidebar is) is left out. Nil
    /// when none is.
    public init?(alphaOf image: CGImage, most: Int) {
        let width = image.width, height = image.height
        guard width >= 4, height >= 4, most > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let alpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
        let reach = min(most, width / 4, height / 4)
        // Rows from the top of the buffer are the image's rows from its top.
        func measure(top: Bool, left: Bool) -> [Int] {
            var insets: [Int] = []
            for index in 0..<reach {
                let row = top ? index : height - 1 - index
                var count = 0
                while count < reach, alpha[row * width + (left ? count : width - 1 - count)] < 255 { count += 1 }
                guard count < reach else { return [] }
                guard count > 0 else { return insets }
                if let last = insets.last, count > last { return [] }
                insets.append(count)
            }
            return []
        }
        self.init(
            topLeft: measure(top: true, left: true), topRight: measure(top: true, left: false),
            bottomLeft: measure(top: false, left: true), bottomRight: measure(top: false, left: false)
        )
        guard !isEmpty else { return nil }
    }

    public var isEmpty: Bool { topLeft.isEmpty && topRight.isEmpty && bottomLeft.isEmpty && bottomRight.isEmpty }

    /// These corners but those in `kept`.
    public func only(_ kept: Set<Corner>) -> ViewCorners {
        ViewCorners(
            topLeft: kept.contains(.topLeft) ? topLeft : [], topRight: kept.contains(.topRight) ? topRight : [],
            bottomLeft: kept.contains(.bottomLeft) ? bottomLeft : [], bottomRight: kept.contains(.bottomRight) ? bottomRight : []
        )
    }

    /// How many rows from the top and from the bottom hold pixels past the shape.
    var rows: (top: Int, bottom: Int) {
        (max(topLeft.count, topRight.count), max(bottomLeft.count, bottomRight.count))
    }

    /// For a log line or a replay: "corners tl=… tr=… bl=… br=…", each the insets joined by commas, "-" for none.
    public var description: String {
        func list(_ insets: [Int]) -> String { insets.isEmpty ? "-" : insets.map(String.init).joined(separator: ",") }
        return "corners tl=\(list(topLeft)) tr=\(list(topRight)) bl=\(list(bottomLeft)) br=\(list(bottomRight))"
    }

    /// Reads `description` back.
    public init?(description: String) {
        let words = description.split(separator: " ")
        guard words.first == "corners" else { return nil }
        var found: [String: [Int]] = [:]
        for word in words.dropFirst() {
            let parts = word.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            found[String(parts[0])] = parts[1] == "-" ? [] : parts[1].split(separator: ",").compactMap { Int($0) }
        }
        self.init(topLeft: found["tl"] ?? [], topRight: found["tr"] ?? [], bottomLeft: found["bl"] ?? [], bottomRight: found["br"] ?? [])
    }

    /// Fills the pixels of a `width` × `height` view past the shape, each from the first pixel within it along its
    /// column. `pixel(x, y)` is where a pixel of the view is, its four bytes.
    func fill(width: Int, height: Int, pixel: (Int, Int) -> UnsafeMutableRawPointer) {
        for (insets, top, left) in [(topLeft, true, true), (topRight, true, false), (bottomLeft, false, true), (bottomRight, false, false)] {
            guard let widest = insets.first, insets.count < height / 2, widest < width / 2 else { continue }
            for column in 0..<widest {
                // The rows past the shape in this column, from the edge: those whose inset reaches past it.
                let past = insets.firstIndex { $0 <= column } ?? insets.count
                let x = left ? column : width - 1 - column
                let from = pixel(x, top ? past : height - 1 - past)
                for row in 0..<past {
                    pixel(x, top ? row : height - 1 - row).copyMemory(from: from, byteCount: 4)
                }
            }
        }
    }

    /// Keeps a corner's insets as described: at most as many as the row before, none after the first that has none.
    private static func clean(_ insets: [Int]) -> [Int] {
        var kept: [Int] = []
        for inset in insets {
            guard inset > 0 else { break }
            kept.append(min(inset, kept.last ?? inset))
        }
        return kept
    }
}
