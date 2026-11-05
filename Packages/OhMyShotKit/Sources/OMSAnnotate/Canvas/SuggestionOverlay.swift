import AppKit
import QuartzCore

/// The redaction tool's suggestions over the canvas: dashed accent outlines around text reading found
/// better covered, each covered by a click, and never part of the picture; a help tag over each naming
/// its kind; and a button each for VoiceOver. The canvas says which are open and where they are on
/// screen, and answers the help tags, as their owner.
final class SuggestionOverlay {
    /// The dashed accent outlines.
    private let outline = CAShapeLayer()
    /// A white line under the dashes, so their gaps are white.
    private let halo = CAShapeLayer()
    /// The suggestions as VoiceOver finds them, one button each.
    private var elements: [(suggestion: RedactionSuggestion, element: SuggestionElement)] = []
    /// The canvas: the help tags' view and owner, and the buttons' parent.
    private weak var view: (NSView & NSViewToolTipOwner)?
    /// Covers a suggestion, when VoiceOver presses its button; whether it did.
    var onPress: ((RedactionSuggestion) -> Bool)?

    init(on view: NSView & NSViewToolTipOwner) {
        self.view = view
        for layer in [halo, outline] {
            layer.fillColor = nil
            layer.isHidden = true
            layer.actions = ["path": NSNull(), "hidden": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        }
        outline.lineDashPattern = [4, 3]
    }

    /// Adds the outlines to `layer`, above what is already there.
    func install(in layer: CALayer?) {
        layer?.addSublayer(halo)
        layer?.addSublayer(outline)
    }

    /// The buttons, for the canvas's accessibility children.
    var accessibilityElements: [SuggestionElement] { elements.map(\.element) }

    /// Outlines `open`, each where `rect` puts it on screen (in the view's points), over a layer `frame`
    /// large, with each one's kind as its help tag.
    /// - Parameter fadingIn: the outlines arrive with a short fade (a reading that just finished), or at once
    ///   with Reduce Motion.
    func show(_ open: [RedactionSuggestion], in frame: CGRect, fadingIn: Bool, at rect: (RedactionSuggestion) -> CGRect) {
        let path = CGMutablePath()
        for suggestion in open {
            path.addRoundedRect(in: rect(suggestion), cornerWidth: 3, cornerHeight: 3)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [halo, outline] {
            layer.frame = frame
            layer.path = path
            layer.isHidden = open.isEmpty
            if fadingIn, !open.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.duration = 0.12
                fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(fade, forKey: "fade")
            }
        }
        CATransaction.commit()
        guard let view else { return }
        view.removeAllToolTips()
        for suggestion in open {
            view.addToolTip(rect(suggestion), owner: view, userData: nil)
        }
        updateElements(open, of: view, at: rect)
    }

    /// One button per open suggestion for VoiceOver, kept while the suggestions stay the same so its focus
    /// holds, and moved with the picture.
    private func updateElements(_ open: [RedactionSuggestion], of view: NSView, at rect: (RedactionSuggestion) -> CGRect) {
        if elements.map(\.suggestion) != open {
            elements = open.map { suggestion in
                let element = SuggestionElement()
                element.setAccessibilityRole(.button)
                element.setAccessibilityLabel(String(localized: "\(suggestion.label), suggested redaction", bundle: .module))
                element.setAccessibilityParent(view)
                element.press = { [weak self] in self?.onPress?(suggestion) ?? false }
                return (suggestion, element)
            }
            NSAccessibility.post(element: view, notification: .layoutChanged)
        }
        for (suggestion, element) in elements {
            element.setAccessibilityFrameInParentSpace(rect(suggestion))
        }
    }

    /// Resolves the outlines' colors for the appearance in effect, which the caller has made current:
    /// Increase Contrast thickens them.
    func applyAppearance(increasedContrast contrast: Bool) {
        // No fill: the accent is never a fill behind text, and this is the text being judged.
        outline.strokeColor = NSColor.controlAccentColor.cgColor
        outline.lineWidth = contrast ? 2 : 1.5
        // As wide as the dashes, so their gaps are white: the outline holds on any content, blue link
        // text and dark pages included, without reaching onto the text it surrounds.
        halo.strokeColor = CGColor(gray: 1, alpha: contrast ? 1 : 0.85)
        halo.lineWidth = contrast ? 2 : 1.5
    }
}

/// A redaction suggestion as VoiceOver finds it: a button that covers the text.
nonisolated final class SuggestionElement: NSAccessibilityElement {
    /// Set and called on the main thread, where accessibility actions arrive.
    nonisolated(unsafe) var press: (@MainActor () -> Bool)?

    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        return MainActor.assumeIsolated { press() }
    }
}
