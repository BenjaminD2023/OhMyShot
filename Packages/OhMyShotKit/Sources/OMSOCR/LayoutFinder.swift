import CoreGraphics
import CoreML
import Foundation
import OMSPixels

/// Where the formulas, tables, and charts are in a picture: the layout model the formula pack and the VLM pack both hold
/// (PP-DocLayoutV3; Docs/ocr.md › Formulas among text, › The VLM pack), on the CPU, as Tools/model-packs/formula_pack.py
/// checks it. A region is a query whose class of a kind the pack names (`Layout.classes`: "display" and "inline" for
/// formulas, "table" and "chart") scores the pack's threshold or more.
///
/// The model sees 800 × 800 whatever it is given, so a large picture is read in tiles (`tiles`), and a long strip is
/// padded nearer to a page's shape first. What two tiles both found, or two classes of one query, is found once
/// (`merged`).
public final class LayoutFinder: @unchecked Sendable {
    /// A formula, table, or chart found, in the picture's pixels with a top-left origin.
    public struct Region: Sendable, Equatable {
        public enum Kind: String, Sendable, Codable, CaseIterable {
            /// A formula set apart, on a line of its own.
            case display
            /// A formula within a line of text.
            case inline
            /// A table: rows and columns of cells.
            case table
            /// A chart: bars, lines, or slices with their data.
            case chart

            public var isFormula: Bool { self == .display || self == .inline }
        }

        public var kind: Kind
        public var box: CGRect
        public var score: Float

        public init(kind: Kind, box: CGRect, score: Float) {
            self.kind = kind
            self.box = box
            self.score = score
        }
    }

    /// A part of a picture read on its own: `area` of the picture, drawn at the top left of a `canvas` the color of its
    /// edges.
    struct Tile: Equatable {
        var area: CGRect
        var canvas: CGSize
    }

    public let configuration: FormulaConfiguration.Layout
    // MLModel predictions may run from any thread; the finder asks one at a time.
    private let model: MLModel

    init(configuration: FormulaConfiguration.Layout, model: MLModel) {
        self.configuration = configuration
        self.model = model
    }

    /// The finder of the formula pack installed in `folder`, its model compiled into `folder/Compiled` the first time.
    public static func load(from folder: URL) async throws -> LayoutFinder {
        let configuration = try FormulaConfiguration.load(from: folder)
        return try await load(from: folder, layout: configuration.layout, units: configuration.computeUnits)
    }

    /// The finder of the layout model `layout` describes in the pack installed in `folder` (the VLM pack's `layout.json`;
    /// or another pack's model with more kinds named, so that one run finds what two packs read), on `units`.
    public static func load(from folder: URL, layout: FormulaConfiguration.Layout, units: String) async throws -> LayoutFinder {
        let model = try await PackModel.load(layout.file, in: folder, units: PackModel.units(units))
        return LayoutFinder(configuration: layout, model: model)
    }

    /// The regions in `image` of the kinds the pack names, top to bottom.
    public func regions(in image: CGImage) async throws -> [Region] {
        var found: [Region] = []
        for tile in Self.tiles(width: image.width, height: image.height) {
            try Task.checkCancellation()
            guard let values = Self.values(of: image, tile, size: configuration.size) else { continue }
            let size = configuration.size
            let pixels = try MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
            pixels.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
                _ = buffer.update(fromContentsOf: values)
            }
            let output = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: [configuration.input: pixels]))
            guard let logits = output.featureValue(for: configuration.logits)?.multiArrayValue,
                  let boxes = output.featureValue(for: configuration.boxes)?.multiArrayValue,
                  logits.shape.count == 3, boxes.shape.count == 3, boxes.shape[2].intValue == 4, logits.shape[1] == boxes.shape[1]
            else { throw FormulaError.unexpectedOutput("the layout model gave no \(configuration.logits) and \(configuration.boxes) of one query each") }
            found += Self.regions(
                logits: Self.floats(logits), boxes: Self.floats(boxes), classes: logits.shape[2].intValue, layout: configuration, in: tile
            )
        }
        return Self.merged(found).sorted { ($0.box.minY, $0.box.minX) < ($1.box.minY, $1.box.minX) }
    }

    /// Whether formulas are looked for in a `width` × `height` picture: up to 40 megapixels (a 5K screen is 14.7; about
    /// 20 tiles). A longer scrolling capture is left as Vision reads it: decoded whole to be tiled, it would take 160 MB
    /// and more.
    public static func finds(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width * height <= 40_000_000
    }

    // MARK: Tiles

    /// The longest side of a tile, in the picture's pixels: scaled to 800, a tile shrinks by 2.25 at most. The corpus's
    /// pages, 1640 wide and shrunk by 2.05, gave every formula (Docs/ocr.md › Formulas among text).
    static let longest = 1800
    /// How far neighboring tiles reach into each other: a formula cut by one tile's edge is whole in the other.
    static let overlap = 200
    /// A tile longer than this many times its height (or taller than its width) is padded to it: a strip scaled to a
    /// square is no picture the model knows (a 2633 × 67 terminal line, scaled so, was a display formula at 0.33).
    static let aspect: CGFloat = 2

    /// The tiles that cover a `width` × `height` picture: one when it fits in `longest` on both sides, else as few as
    /// fit, evenly spread, each reaching `overlap` into the next.
    static func tiles(width: Int, height: Int) -> [Tile] {
        guard width > 0, height > 0 else { return [] }
        func spans(_ length: Int) -> [(start: Int, length: Int)] {
            guard length > longest else { return [(0, length)] }
            let count = Int((Double(length - overlap) / Double(longest - overlap)).rounded(.up))
            let size = Int((Double(length + (count - 1) * overlap) / Double(count)).rounded(.up))
            return (0..<count).map { index in (min(index * (size - overlap), length - size), size) }
        }
        return spans(height).flatMap { row in
            spans(width).map { column in
                let area = CGRect(x: column.start, y: row.start, width: column.length, height: row.length)
                let canvas = CGSize(width: max(area.width, (area.height / aspect).rounded(.up)), height: max(area.height, (area.width / aspect).rounded(.up)))
                return Tile(area: area, canvas: canvas)
            }
        }
    }

    /// The tile as the model reads it: its canvas scaled to `size` × `size` (PIL's antialiased bicubic, as transformers'
    /// processor scales it), 3 planes of value / 255.
    static func values(of image: CGImage, _ tile: Tile, size: Int) -> [Float]? {
        guard let pixels = PPOCRPixels(image, region: tile.area) else { return nil }
        let (width, height) = (Int(tile.canvas.width), Int(tile.canvas.height))
        var canvas: [UInt8]
        if width == pixels.width, height == pixels.height {
            canvas = pixels.bytes
        } else {
            let edge = Self.edgeColor(pixels.bytes, width: pixels.width, height: pixels.height)
            canvas = [UInt8](repeating: 0, count: width * height * 4)
            for i in stride(from: 0, to: canvas.count, by: 4) {
                canvas[i] = edge.0; canvas[i + 1] = edge.1; canvas[i + 2] = edge.2; canvas[i + 3] = 255
            }
            for y in 0..<pixels.height {
                canvas.replaceSubrange((y * width * 4)..<((y * width + pixels.width) * 4), with: pixels.bytes[(y * pixels.width * 4)..<((y + 1) * pixels.width * 4)])
            }
        }
        let scaled = canvas.withUnsafeBufferPointer { Resample.antialiased($0, width: width, height: height, toWidth: size, toHeight: size, filter: .bicubic) }
        return FormulaPixels.planes(scaled, width: size, height: size, size: size, mean: [0, 0, 0], std: [1, 1, 1], padding: 0)
    }

    /// The median color of the pixels along the edges of RGBX `bytes`: the page's own, for the canvas around a strip.
    static func edgeColor(_ bytes: [UInt8], width: Int, height: Int) -> (UInt8, UInt8, UInt8) {
        var channels: [[UInt8]] = [[], [], []]
        func add(_ x: Int, _ y: Int) {
            let i = (y * width + x) * 4
            for c in 0..<3 { channels[c].append(bytes[i + c]) }
        }
        for x in stride(from: 0, to: width, by: max(1, width / 64)) { add(x, 0); add(x, height - 1) }
        for y in stride(from: 0, to: height, by: max(1, height / 64)) { add(0, y); add(width - 1, y) }
        let medians = channels.map { values in values.sorted()[values.count / 2] }
        return (medians[0], medians[1], medians[2])
    }

    // MARK: Detections

    /// The regions among one tile's detections, in the picture's pixels: each query's class logits (`classes` a query)
    /// through a sigmoid, kept where a class of a kind the pack names scores the threshold or more; its box (center and
    /// size, 0-1 of the canvas) placed on the tile and kept within it.
    static func regions(logits: [Float], boxes: [Float], classes: Int, layout: FormulaConfiguration.Layout, in tile: Tile) -> [Region] {
        let kinds: [(Region.Kind, Int)] = Region.Kind.allCases.compactMap { kind in layout.classes[kind.rawValue].map { (kind, $0) } }
        let queries = min(logits.count / max(classes, 1), boxes.count / 4)
        var found: [Region] = []
        for query in 0..<queries {
            for (kind, label) in kinds where (0..<classes).contains(label) {
                let score = 1 / (1 + exp(-logits[query * classes + label]))
                guard score >= layout.threshold else { continue }
                let (cx, cy, w, h) = (CGFloat(boxes[query * 4]), CGFloat(boxes[query * 4 + 1]), CGFloat(boxes[query * 4 + 2]), CGFloat(boxes[query * 4 + 3]))
                let box = CGRect(
                    x: tile.area.minX + (cx - w / 2) * tile.canvas.width, y: tile.area.minY + (cy - h / 2) * tile.canvas.height,
                    width: w * tile.canvas.width, height: h * tile.canvas.height
                ).intersection(tile.area)
                guard !box.isNull, box.width >= 2, box.height >= 2 else { continue }
                found.append(Region(kind: kind, box: box, score: score))
            }
        }
        return found
    }

    /// Each formula, and each table or chart, once: detections of the one family that are mostly one box (IoU 0.5 or
    /// more: two classes of one query, or a region two tiles both found, one of them cut by its edge) are one, of the
    /// likeliest's kind, over both boxes; then none that lies mostly (0.6 of it) inside a larger one of its family: an
    /// inline formula found within a display one, or a cut-off part. A formula in a table's cell stays.
    static func merged(_ regions: [Region]) -> [Region] {
        let formulas = mergedFamily(regions.filter(\.kind.isFormula))
        return formulas + mergedFamily(regions.filter { !$0.kind.isFormula })
    }

    private static func mergedFamily(_ regions: [Region]) -> [Region] {
        var distinct: [Region] = []
        for region in regions.sorted(by: { $0.score > $1.score }) {
            if let same = distinct.firstIndex(where: { intersectionOverUnion($0.box, region.box) >= 0.5 }) {
                distinct[same].box = distinct[same].box.union(region.box)
            } else {
                distinct.append(region)
            }
        }
        return distinct.filter { region in
            let area = region.box.width * region.box.height
            return !distinct.contains { other in
                guard other != region, other.box.width * other.box.height > area else { return false }
                let shared = other.box.intersection(region.box)
                return !shared.isNull && shared.width * shared.height >= area * 0.6
            }
        }
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        guard !shared.isNull else { return 0 }
        let inter = shared.width * shared.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    /// An output's values in order, whatever its strides.
    static func floats(_ array: MLMultiArray) -> [Float] {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        let contiguous = strides == shape.indices.map { shape[($0 + 1)...].reduce(1, *) }
        if array.dataType == .float32, contiguous {
            return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
        }
        var values: [Float] = []
        values.reserveCapacity(array.count)
        var index = [Int](repeating: 0, count: shape.count)
        for _ in 0..<array.count {
            values.append(array[index.map { NSNumber(value: $0) }].floatValue)
            var axis = shape.count - 1
            while axis >= 0 {
                index[axis] += 1
                if index[axis] < shape[axis] { break }
                index[axis] = 0
                axis -= 1
            }
        }
        return values
    }
}
