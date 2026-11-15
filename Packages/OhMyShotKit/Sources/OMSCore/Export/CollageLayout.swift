import CoreGraphics
import Foundation

/// Where each picture goes when several are combined into one: a pure layout, in points, y down, for the Collage
/// window to preview and `CollageRenderer` to draw.
///
/// After SnowAir's collage presets (Apache-2.0): the same idea of a few arrangements chosen by how many pictures
/// there are, written again here, without its free-angled dividers.
public struct CollageLayout: Sendable, Equatable {
    public enum Arrangement: String, CaseIterable, Sendable, Identifiable {
        /// Side by side, all as tall as each other: nothing is cut and no room is left.
        case row
        /// One under another, all as wide as each other.
        case column
        /// Equal cells in rows.
        case grid
        /// The first picture large on the left, the others stacked beside it.
        case featured

        public var id: String { rawValue }
    }

    /// How a picture sits in a cell that is not its shape. Rows and columns are made of cells of the pictures' own
    /// shapes, so this matters only in grids and the featured arrangement.
    public enum Fitting: String, CaseIterable, Sendable, Identifiable {
        /// The whole picture, centered, with the background around it.
        case fit
        /// The cell filled, the picture's middle kept and its edges cut.
        case fill

        public var id: String { rawValue }
    }

    public struct Options: Sendable, Equatable {
        public var arrangement: Arrangement
        /// The collage's width, in points.
        public var width: CGFloat
        /// Between pictures, in points.
        public var spacing: CGFloat
        /// Around them all, in points.
        public var margin: CGFloat
        public var fitting: Fitting

        public init(arrangement: Arrangement, width: CGFloat, spacing: CGFloat = 16, margin: CGFloat = 24, fitting: Fitting = .fit) {
            self.arrangement = arrangement
            self.width = width
            self.spacing = spacing
            self.margin = margin
            self.fitting = fitting
        }
    }

    /// The collage's size, in points.
    public var size: CGSize
    /// Each picture's cell, in the order the pictures were given.
    public var cells: [CGRect]

    /// The narrowest a collage can be made, in points.
    public static let leastWidth: CGFloat = 200

    /// The arrangement a number of pictures of these sizes starts with: two side by side or one under the other,
    /// whichever comes out nearer 4:3; three as one beside two; four in a square; more in the grid nearest 4:3.
    public static func suggested(for sizes: [CGSize]) -> Arrangement {
        switch sizes.count {
        case ...1: return .column
        case 2:
            let row = layout(sizes, options: Options(arrangement: .row, width: 1000, spacing: 0, margin: 0)).size
            let column = layout(sizes, options: Options(arrangement: .column, width: 1000, spacing: 0, margin: 0)).size
            return distance(fromFourThree: row) <= distance(fromFourThree: column) ? .row : .column
        case 3: return .featured
        default: return .grid
        }
    }

    /// A width to start from: the pictures at about their own size, side by side for a row, within reason.
    public static func suggestedWidth(for sizes: [CGSize], arrangement: Arrangement) -> CGFloat {
        let widths = sizes.map(\.width).filter { $0 > 0 }
        guard !widths.isEmpty else { return 1200 }
        let typical = widths.sorted()[widths.count / 2]
        let natural: CGFloat = switch arrangement {
        case .row: sizes.map { $0.width * (median(sizes.map(\.height)) / max($0.height, 1)) }.reduce(0, +)
        case .column: typical
        case .grid: typical * CGFloat(columns(for: sizes))
        case .featured: typical * 1.6
        }
        return min(max(natural.rounded(), leastWidth), 3200)
    }

    /// Lays `sizes` out as `options` say. Pictures with no area are given a square.
    public static func layout(_ sizes: [CGSize], options: Options) -> CollageLayout {
        let aspects = sizes.map { $0.width > 0 && $0.height > 0 ? $0.width / $0.height : 1 }
        let count = aspects.count
        let margin = max(options.margin, 0), spacing = max(options.spacing, 0)
        let width = max(options.width, leastWidth)
        let inner = max(width - margin * 2, 1)
        guard count > 0 else { return CollageLayout(size: CGSize(width: width, height: margin * 2), cells: []) }

        switch count == 1 ? .column : options.arrangement {
        case .row:
            // One height for all: the widths at that height and the gaps fill the inner width exactly.
            let height = max(inner - spacing * CGFloat(count - 1), 1) / aspects.reduce(0, +)
            var x = margin
            let cells = aspects.map { aspect -> CGRect in
                defer { x += aspect * height + spacing }
                return CGRect(x: x, y: margin, width: aspect * height, height: height)
            }
            return CollageLayout(size: CGSize(width: width, height: (height + margin * 2).rounded(.up)), cells: cells)
        case .column:
            var y = margin
            let cells = aspects.map { aspect -> CGRect in
                defer { y += inner / aspect + spacing }
                return CGRect(x: margin, y: y, width: inner, height: inner / aspect)
            }
            return CollageLayout(size: CGSize(width: width, height: (y - spacing + margin).rounded(.up)), cells: cells)
        case .grid:
            let columns = columns(for: sizes)
            let rows = (count + columns - 1) / columns
            let cellWidth = max(inner - spacing * CGFloat(columns - 1), 1) / CGFloat(columns)
            // Cells of the pictures' usual shape, so fitting leaves little room and filling cuts little.
            let cellHeight = cellWidth / median(aspects)
            var cells: [CGRect] = []
            for index in 0..<count {
                let row = index / columns, column = index % columns
                // A last row that is short is centered.
                let inRow = row == rows - 1 ? count - row * columns : columns
                let rowWidth = cellWidth * CGFloat(inRow) + spacing * CGFloat(inRow - 1)
                let x = margin + (inner - rowWidth) / 2 + CGFloat(column) * (cellWidth + spacing)
                cells.append(CGRect(x: x, y: margin + CGFloat(row) * (cellHeight + spacing), width: cellWidth, height: cellHeight))
            }
            let height = CGFloat(rows) * cellHeight + spacing * CGFloat(rows - 1) + margin * 2
            return CollageLayout(size: CGSize(width: width, height: height.rounded(.up)), cells: cells)
        case .featured:
            // The first picture in its own shape on the left; the others share the right side's height, in cells of
            // their usual shape: the left side's width is solved so the two sides come out as tall.
            let others = count - 1
            let first = aspects[0], rest = median(Array(aspects.dropFirst()))
            let gaps = spacing * CGFloat(others - 1)
            let usable = max(inner - spacing, 1)
            let leftWidth = (usable + rest * gaps / CGFloat(others)) / (1 + rest / (first * CGFloat(others)))
            let rightWidth = max(usable - leftWidth, 1)
            let height = leftWidth / first
            let cellHeight = max(height - gaps, 1) / CGFloat(others)
            var cells = [CGRect(x: margin, y: margin, width: leftWidth, height: height)]
            for index in 0..<others {
                cells.append(CGRect(x: margin + leftWidth + spacing, y: margin + CGFloat(index) * (cellHeight + spacing), width: rightWidth, height: cellHeight))
            }
            return CollageLayout(size: CGSize(width: width, height: (height + margin * 2).rounded(.up)), cells: cells)
        }
    }

    /// Where a picture of `size` is drawn in `cell`: the whole of it centered when fitting, else the cell covered (the
    /// part outside the cell is cut by the cell).
    public static func pictureRect(of size: CGSize, in cell: CGRect, fitting: Fitting) -> CGRect {
        guard size.width > 0, size.height > 0 else { return cell }
        let scale = fitting == .fit
            ? min(cell.width / size.width, cell.height / size.height)
            : max(cell.width / size.width, cell.height / size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: cell.midX - drawn.width / 2, y: cell.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
    }

    /// The grid's columns: the count whose collage comes out nearest 4:3.
    static func columns(for sizes: [CGSize]) -> Int {
        let count = sizes.count
        guard count > 1 else { return 1 }
        let aspect = median(sizes.map { $0.width > 0 && $0.height > 0 ? $0.width / $0.height : 1 })
        return (1...count).min { a, b in
            func shape(_ columns: Int) -> CGSize {
                let rows = (count + columns - 1) / columns
                return CGSize(width: CGFloat(columns) * aspect, height: CGFloat(rows))
            }
            return distance(fromFourThree: shape(a)) < distance(fromFourThree: shape(b))
        } ?? 2
    }

    private static func distance(fromFourThree size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return .infinity }
        return abs(log((size.width / size.height) / (4.0 / 3.0)))
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 1 }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }
}

/// Draws a collage: the background, then each picture in its cell, rounded.
public enum CollageRenderer {
    public struct Picture: @unchecked Sendable {
        public var image: CGImage
        /// Its size in points.
        public var size: CGSize

        public init(image: CGImage, size: CGSize) {
            self.image = image
            self.size = size
        }
    }

    /// The collage at `scale` pixels per point, on `background` (clear when nil), each picture rounded by
    /// `cornerRadius` points. Nil when the picture would be empty or too large to make.
    public static func render(
        _ pictures: [Picture], layout: CollageLayout, fitting: CollageLayout.Fitting, cornerRadius: CGFloat, background: CGColor?, scale: CGFloat
    ) -> CGImage? {
        let width = Int((layout.size.width * scale).rounded()), height = Int((layout.size.height * scale).rounded())
        guard width > 0, height > 0, width * height <= 400_000_000,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // y down, in points.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.interpolationQuality = .high
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(origin: .zero, size: layout.size))
        }
        for (picture, cell) in zip(pictures, layout.cells) {
            let rect = CollageLayout.pictureRect(of: picture.size, in: cell, fitting: fitting)
            let shown = rect.intersection(cell)
            guard !shown.isNull, shown.width > 0, shown.height > 0 else { continue }
            context.saveGState()
            let radius = min(max(cornerRadius, 0), shown.width / 2, shown.height / 2)
            context.addPath(CGPath(roundedRect: shown, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            // Images draw y up: flip about the picture's rect.
            context.translateBy(x: 0, y: rect.minY + rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(picture.image, in: rect)
            context.restoreGState()
        }
        return context.makeImage()
    }
}
