import CoreGraphics

/// Text that reading found better covered, offered while the redaction tool is in hand: where it is, in
/// capture pixels with a top-left origin, and what kind it is ("Email"), as its tooltip says.
nonisolated public struct RedactionSuggestion: Sendable, Equatable {
    public var rect: CGRect
    public var label: String

    public init(rect: CGRect, label: String) {
        self.rect = rect
        self.label = label
    }

    /// The redaction that covers it: a little larger than the text, so its anti-aliased edges go too.
    var coveringRect: CGRect {
        let pad = max(2, rect.height * 0.12)
        return rect.insetBy(dx: -pad, dy: -pad).integral
    }

    /// The part of the covering rectangle within `canvas`: what a crop keeps of it.
    func coveringRect(within canvas: CGRect) -> CGRect {
        coveringRect.intersection(canvas.standardized)
    }
}
