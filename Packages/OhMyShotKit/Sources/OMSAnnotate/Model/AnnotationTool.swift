import CoreGraphics
import Foundation

/// What a drag or click on the canvas does.
nonisolated public enum AnnotationTool: String, CaseIterable, Codable, Sendable {
    case select
    case arrow
    case line
    case rectangle
    case ellipse
    case pen
    case highlighter
    /// A rectangle of marker color multiplied into the picture.
    case highlightBox
    case text
    case counter
    case redact
    case spotlight
    case crop
    /// Sets the capture on a background for sharing.
    case background

    /// The key that picks the tool, as in CleanShot where they agree.
    public var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlighter: "h"
        case .highlightBox: "m"
        case .text: "t"
        case .counter: "n"
        case .redact: "b"
        case .spotlight: "s"
        case .crop: "c"
        case .background: "g"
        }
    }

    /// Tools that change the picture as a whole rather than draw marks on it: passing modes the canvas
    /// returns from, never the tool a new capture opens with.
    public var isPictureMode: Bool {
        self == .crop || self == .background
    }

    /// Tools that draw a mark by dragging from one corner or end to the other.
    public var dragsShape: Bool {
        switch self {
        case .arrow, .line, .rectangle, .ellipse, .highlightBox, .redact, .spotlight: true
        default: false
        }
    }
}

/// Everything a tool remembers between uses: the color, width, and the tool's own variant. Each tool
/// reads only its own fields.
nonisolated public struct ToolSettings: Codable, Sendable, Equatable {
    public var color: RGBA
    /// In points.
    public var lineWidth: CGFloat
    public var shadow: Bool
    public var arrowHead: Arrow.Head
    public var dashed: Bool
    public var filled: Bool
    /// In points.
    public var cornerRadius: CGFloat
    public var redaction: Redaction.Method
    public var numbering: Counter.Numbering
    public var textLook: TextBlock.Look
    /// In points.
    public var fontSize: CGFloat
    public var oval: Bool

    public init(
        color: RGBA = .red, lineWidth: CGFloat = 4, shadow: Bool = true, arrowHead: Arrow.Head = .classic,
        dashed: Bool = false, filled: Bool = false, cornerRadius: CGFloat = 4, redaction: Redaction.Method = .solid,
        numbering: Counter.Numbering = .numbers, textLook: TextBlock.Look = .plain, fontSize: CGFloat = 20, oval: Bool = false
    ) {
        self.color = color
        self.lineWidth = lineWidth
        self.shadow = shadow
        self.arrowHead = arrowHead
        self.dashed = dashed
        self.filled = filled
        self.cornerRadius = cornerRadius
        self.redaction = redaction
        self.numbering = numbering
        self.textLook = textLook
        self.fontSize = fontSize
        self.oval = oval
    }

    /// A tool's settings before the user changes them.
    public static func defaults(for tool: AnnotationTool) -> ToolSettings {
        switch tool {
        case .highlighter: ToolSettings(color: .marker, lineWidth: 18, shadow: false)
        case .highlightBox: ToolSettings(color: .marker, shadow: false, cornerRadius: 2)
        case .redact: ToolSettings(color: .black, shadow: false)
        case .spotlight: ToolSettings(shadow: false)
        case .pen: ToolSettings(lineWidth: 3)
        default: ToolSettings()
        }
    }

    public var style: Style {
        Style(color: color, lineWidth: lineWidth, shadow: shadow)
    }

    /// Takes over what a selected mark shows, so the controls and the next mark match it.
    public mutating func adopt(_ item: Annotation) {
        color = item.style.color
        lineWidth = item.style.lineWidth
        shadow = item.style.shadow
        switch item.shape {
        case .arrow(let arrow): arrowHead = arrow.head
        case .line(let line): dashed = line.dashed
        case .rectangle(let box):
            filled = box.filled
            cornerRadius = box.cornerRadius
        case .ellipse(let box): filled = box.filled
        case .highlightBox(let box): cornerRadius = box.cornerRadius
        case .text(let block):
            textLook = block.look
            fontSize = block.fontSize
        case .counter(let counter): numbering = counter.numbering
        case .redaction(let redaction): self.redaction = redaction.method
        case .spotlight(let spot): oval = spot.oval
        case .pen, .highlighter, .textHighlight, .image: break
        }
    }

    /// `item` restyled with these settings, as when a control changes with a mark selected.
    public func applied(to item: Annotation) -> Annotation {
        var item = item
        item.style = style
        switch item.shape {
        case .arrow(var arrow):
            arrow.head = arrowHead
            item.shape = .arrow(arrow)
        case .line(var line):
            line.dashed = dashed
            item.shape = .line(line)
        case .rectangle(var box):
            box.filled = filled
            box.cornerRadius = cornerRadius
            item.shape = .rectangle(box)
        case .ellipse(var box):
            box.filled = filled
            item.shape = .ellipse(box)
        case .highlightBox(var box):
            box.cornerRadius = cornerRadius
            item.shape = .highlightBox(box)
        case .text(var block):
            block.look = textLook
            block.fontSize = fontSize
            item.shape = .text(block)
        case .counter(var counter):
            counter.numbering = numbering
            item.shape = .counter(counter)
        case .redaction(var redaction):
            redaction.method = self.redaction
            item.shape = .redaction(redaction)
        case .spotlight(var spot):
            spot.oval = oval
            item.shape = .spotlight(spot)
        case .pen, .highlighter, .textHighlight, .image:
            break
        }
        return item
    }
}

nonisolated extension AnnotationTool {
    /// The mark this tool draws when dragged from `start` to `end` (pixels), or nil for tools that do not
    /// draw by dragging. `constrained` (Shift) makes squares and circles and snaps lines to 45°.
    public func mark(from start: CGPoint, to end: CGPoint, constrained: Bool, settings: ToolSettings, id: UUID = UUID()) -> Annotation? {
        let style = settings.style
        let shape: Shape
        switch self {
        case .arrow:
            shape = .arrow(Arrow(start: start, end: constrained ? Geometry.snapped(end, from: start) : end, head: settings.arrowHead))
        case .line:
            shape = .line(Line(start: start, end: constrained ? Geometry.snapped(end, from: start) : end, dashed: settings.dashed))
        case .rectangle:
            shape = .rectangle(Box(rect: Geometry.rect(from: start, to: end, square: constrained), filled: settings.filled, cornerRadius: settings.cornerRadius))
        case .ellipse:
            shape = .ellipse(Box(rect: Geometry.rect(from: start, to: end, square: constrained), filled: settings.filled))
        case .highlightBox:
            shape = .highlightBox(Box(rect: Geometry.rect(from: start, to: end, square: constrained), filled: true, cornerRadius: settings.cornerRadius))
        case .redact:
            shape = .redaction(Redaction(rect: Geometry.rect(from: start, to: end, square: constrained), method: settings.redaction))
        case .spotlight:
            shape = .spotlight(Spot(rect: Geometry.rect(from: start, to: end, square: constrained), oval: settings.oval))
        default:
            return nil
        }
        return Annotation(id: id, shape: shape, style: style)
    }
}
