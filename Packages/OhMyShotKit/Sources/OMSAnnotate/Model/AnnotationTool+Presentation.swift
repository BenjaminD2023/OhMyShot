import Foundation

/// How each tool presents itself wherever it is offered (the editor's rail, the in-place toolbar, the
/// style capsule, the canvas's keys and undo steps): the key that picks it, its symbol, its name, its help
/// tag, and the name of the undo step a shape it drags out makes. Kept together, each switch naming every
/// tool, so a new tool is given all of them at once.
nonisolated extension AnnotationTool {
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

    /// The SF Symbol on the tool's chip.
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble.variable"
        case .highlighter: "highlighter"
        case .highlightBox: "rectangle.inset.filled"
        case .text: "textformat"
        case .counter: "1.circle"
        case .redact: "checkerboard.rectangle"
        case .spotlight: "circle.dashed.inset.filled"
        case .crop: "crop"
        case .background: "photo.artframe"
        }
    }

    var name: String {
        switch self {
        case .select: String(localized: "Select", bundle: .module)
        case .arrow: String(localized: "Arrow", bundle: .module)
        case .line: String(localized: "Line", bundle: .module)
        case .rectangle: String(localized: "Rectangle", bundle: .module)
        case .ellipse: String(localized: "Ellipse", bundle: .module)
        case .pen: String(localized: "Pen", bundle: .module)
        case .highlighter: String(localized: "Highlighter", bundle: .module)
        case .highlightBox: String(localized: "Highlight Box", bundle: .module)
        case .text: String(localized: "Text", bundle: .module)
        case .counter: String(localized: "Counter", bundle: .module)
        case .redact: String(localized: "Redact", bundle: .module)
        case .spotlight: String(localized: "Spotlight", bundle: .module)
        case .crop: String(localized: "Crop", bundle: .module)
        case .background: String(localized: "Background", bundle: .module)
        }
    }

    /// The tool's help tag: its name and key, and for the highlighter how it meets text.
    var help: String {
        let title = "\(name) (\(String(key).uppercased()))"
        guard self == .highlighter else { return title }
        return title + "\n" + String(localized: "Snaps to text. Hold ⌘ to draw freely.", bundle: .module)
    }

    /// The undo step a mark dragged out with the tool makes.
    var addName: String {
        switch self {
        case .arrow: String(localized: "Add Arrow", bundle: .module)
        case .line: String(localized: "Add Line", bundle: .module)
        case .rectangle: String(localized: "Add Rectangle", bundle: .module)
        case .ellipse: String(localized: "Add Ellipse", bundle: .module)
        case .highlightBox: String(localized: "Add Highlight Box", bundle: .module)
        case .redact: String(localized: "Add Redaction", bundle: .module)
        case .spotlight: String(localized: "Add Spotlight", bundle: .module)
        // Named by their own undo steps (Draw, Highlight, Add Text, Add Counter), or drawing nothing.
        case .select, .pen, .highlighter, .text, .counter, .crop, .background: String(localized: "Add Mark", bundle: .module)
        }
    }
}
