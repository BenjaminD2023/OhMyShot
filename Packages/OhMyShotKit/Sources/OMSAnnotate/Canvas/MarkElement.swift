import AppKit

/// A mark as VoiceOver finds it among the canvas's children: a layout item named for what it is ("Arrow, Red",
/// "Text: Fix this", "Counter 3"), framed where it is drawn, picking the mark up when pressed or selected, and
/// deleting it with its Delete action. It asks the canvas each time, so it never goes stale as marks move or the
/// picture zooms. Used only on the main thread, where accessibility asks.
nonisolated final class MarkElement: NSAccessibilityElement, @unchecked Sendable {
    let id: Annotation.ID
    nonisolated(unsafe) private weak var canvas: AnnotationCanvasView?

    @MainActor init(id: Annotation.ID, canvas: AnnotationCanvasView) {
        self.id = id
        self.canvas = canvas
        super.init()
        setAccessibilityRole(.layoutItem)
        setAccessibilityParent(canvas)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: String(localized: "Delete", bundle: .module), target: self, selector: #selector(deleteMark)),
        ])
    }

    override func accessibilityLabel() -> String? {
        let (canvas, id) = (canvas, id)
        return MainActor.assumeIsolated { canvas?.accessibilityName(ofMark: id) }
    }

    override func accessibilityFrame() -> NSRect {
        let (canvas, id) = (canvas, id)
        return MainActor.assumeIsolated { canvas?.accessibilityFrame(ofMark: id) ?? .zero }
    }

    override func isAccessibilitySelected() -> Bool {
        let (canvas, id) = (canvas, id)
        return MainActor.assumeIsolated { canvas?.session.selection.contains(id) ?? false }
    }

    override func setAccessibilitySelected(_ selected: Bool) {
        let (canvas, id) = (canvas, id)
        MainActor.assumeIsolated { canvas?.setMark(id, selected: selected) }
    }

    override func isAccessibilityFocused() -> Bool {
        (canvas?.accessibilityFocusedUIElement as? MarkElement) === self
    }

    override func accessibilityPerformPress() -> Bool {
        let (canvas, id) = (canvas, id)
        return MainActor.assumeIsolated {
            canvas?.setMark(id, selected: true)
            return canvas?.session.selection == [id]
        }
    }

    @objc private func deleteMark() -> Bool {
        let (canvas, id) = (canvas, id)
        return MainActor.assumeIsolated { canvas?.deleteMark(id) ?? false }
    }

    /// What VoiceOver calls the mark: its kind, and the color for those drawn in one; a text's words; a counter's
    /// number as it shows.
    @MainActor static func name(of item: Annotation) -> String {
        let kind = AnnotationSession.tool(for: item).name
        switch item.shape {
        case .arrow, .line, .rectangle, .ellipse, .pen, .highlighter, .textHighlight, .highlightBox:
            let color = StyleCapsule.colorName(item.style.color.withAlpha(1))
            return String(localized: "\(kind), \(color)", bundle: .module, comment: "A mark for VoiceOver: its kind, then its color, as in “Arrow, Red”.")
        case .text(let text):
            let words = text.string.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            return words.isEmpty ? kind : String(localized: "Text: \(words)", bundle: .module, comment: "A text mark for VoiceOver, with its words.")
        case .counter(let counter):
            return String(localized: "Counter \(counter.label)", bundle: .module, comment: "A counter mark for VoiceOver, with what it shows: 3, C, or III.")
        case .redaction:
            return String(localized: "Redaction", bundle: .module)
        case .spotlight, .magnifier:
            return kind
        case .image:
            return String(localized: "Picture", bundle: .module)
        }
    }
}
