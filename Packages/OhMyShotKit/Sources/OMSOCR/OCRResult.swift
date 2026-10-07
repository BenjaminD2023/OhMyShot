import CoreGraphics
import Foundation

/// One line of recognized text, as an engine reports it.
public struct OCRLine: Sendable, Equatable {
    public enum Direction: Sendable, Equatable {
        case leftToRight
        case rightToLeft
        case topToBottom
    }

    public var text: String
    /// In image pixels, top-left origin.
    public var box: CGRect
    public var confidence: Float
    public var direction: Direction?
    /// Whether the text runs on into the next line (a wrapped sentence) rather than ending here.
    public var wrapsToNextLine: Bool?

    public init(text: String, box: CGRect, confidence: Float, direction: Direction? = nil, wrapsToNextLine: Bool? = nil) {
        self.text = text
        self.box = box
        self.confidence = confidence
        self.direction = direction
        self.wrapsToNextLine = wrapsToNextLine
    }
}

/// A table an engine recognized, as rows of cell text. A merged cell appears once, at its first row and
/// column.
public struct OCRTable: Sendable, Equatable {
    public var rows: [[String]]

    public init(rows: [[String]]) {
        self.rows = rows
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
}

/// Recognizes text in an image.
public protocol OCREngine: Sendable {
    var name: String { get }
    func recognize(_ image: CGImage) async throws -> OCRResult
}
