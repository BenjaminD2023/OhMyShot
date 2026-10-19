import CoreGraphics
import Foundation

/// One line of recognized text, as an engine reports it.
public struct OCRLine: Sendable, Equatable {
    public enum Direction: Sendable, Equatable {
        case leftToRight
        case rightToLeft
        case topToBottom
    }

    /// Formulas a line holds as LaTeX between `$` signs (`FormulaMerge`).
    public enum Math: Sendable, Equatable {
        /// Within its text, as `$…$`.
        case inline
        /// The whole line, a formula set apart, as `$$…$$`.
        case display
    }

    public var text: String
    /// In image pixels, top-left origin.
    public var box: CGRect
    public var confidence: Float
    public var direction: Direction?
    /// Whether the text runs on into the next line (a wrapped sentence) rather than ending here.
    public var wrapsToNextLine: Bool?
    public var math: Math?
    /// Whether the text is the app's own, as the app under the picture shows it (`AppTextMerge`): its characters and
    /// spaces are kept as they are, where Vision's are put in the form their language writes them.
    public var isExact: Bool

    public init(
        text: String, box: CGRect, confidence: Float, direction: Direction? = nil, wrapsToNextLine: Bool? = nil, math: Math? = nil,
        isExact: Bool = false
    ) {
        self.text = text
        self.box = box
        self.confidence = confidence
        self.direction = direction
        self.wrapsToNextLine = wrapsToNextLine
        self.math = math
        self.isExact = isExact
    }
}

/// A table an engine recognized, as rows of cell text. A merged cell appears once, at its first row and
/// column.
public struct OCRTable: Sendable, Equatable {
    public var rows: [[String]]
    /// Each cell's box in image pixels (top-left origin), row by row like `rows`; empty when unknown.
    public var cellBoxes: [[CGRect]]

    public init(rows: [[String]], cellBoxes: [[CGRect]] = []) {
        self.rows = rows
        self.cellBoxes = cellBoxes
    }

    /// The table with each cell's text taken from `lines` wherever whole lines sit inside the cell. The
    /// document request reads tables with a weaker model than the lines get ("价格" came back as "fitz"),
    /// and the panel's text and table should agree. Lines that straddle cells are left out; a cell
    /// without lines of its own keeps what the document request read.
    public func filled(from lines: [OCRLine]) -> OCRTable {
        guard cellBoxes.count == rows.count else { return self }
        var filled = self
        for (row, cells) in rows.enumerated() where cellBoxes[row].count == cells.count {
            for column in cells.indices {
                let cell = cellBoxes[row][column]
                let inside = lines.filter { line in
                    let shared = line.box.intersection(cell)
                    guard !shared.isNull, line.box.width > 0, line.box.height > 0 else { return false }
                    return shared.width * shared.height >= line.box.width * line.box.height * 0.75
                }
                guard !inside.isEmpty else { continue }
                let ordered = inside.sorted { abs($0.box.minY - $1.box.minY) < $0.box.height / 2 ? $0.box.minX < $1.box.minX : $0.box.minY < $1.box.minY }
                let text = ordered.map(\.text).reduce("") { text, next in
                    guard let last = text.last, let first = next.first else { return text + next }
                    return text + (Script.isCJK(last) || Script.isCJK(first) ? "" : " ") + next
                }
                // The same characters with a space the lines lost ("1 TB" read as "1TB"): Vision drops
                // spaces far more often than it invents them. Not in Japanese, where it does invent them.
                let read = cells[column]
                let spaces = { (string: String) in string.filter(\.isWhitespace).count }
                if read.filter({ !$0.isWhitespace }) == text.filter({ !$0.isWhitespace }), spaces(read) > spaces(text),
                   !text.contains(where: Script.isKana) {
                    continue
                }
                filled.rows[row][column] = text
            }
        }
        return filled
    }
}

/// What an engine made of one image.
public struct OCRResult: Sendable {
    /// Lines in reading order.
    public var lines: [OCRLine]
    public var tables: [OCRTable]
    /// The engine's plain-text rendering of the image.
    public var text: String
    /// Time spent inside the engine.
    public var duration: Duration

    public init(lines: [OCRLine], tables: [OCRTable] = [], text: String, duration: Duration) {
        self.lines = lines
        self.tables = tables
        self.text = text
        self.duration = duration
    }
}

public enum OCRError: Error, Equatable {
    /// The engine did not answer in time; Vision can stall when too many accurate requests run at once.
    case timedOut
    /// The file holds no picture that could be read.
    case unreadableImage
}

/// Recognizes text in an image.
public protocol OCREngine: Sendable {
    var name: String { get }
    func recognize(_ image: CGImage) async throws -> OCRResult
    /// The text of the picture in the file at `url`; unreadableImage when the file holds none.
    func recognize(fileAt url: URL) async throws -> OCRResult
}

extension OCREngine {
    public func recognize(fileAt url: URL) async throws -> OCRResult {
        try await recognize(PictureText.image(at: url))
    }
}
