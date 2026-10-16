import AppKit
import OMSCore
import QuartzCore

/// What a card shows of its capture's upload.
public nonisolated enum CardUpload: Equatable, Sendable {
    case uploading(fraction: Double)
    /// `linkCopied` is false when the link waits in the card's menu instead of the clipboard.
    case finished(linkCopied: Bool)
    case failed(message: String)
}

/// The materials of the small capsules on a card: white (a dark gray in Dark Mode), the hairline, dark ink.
enum BadgeMaterial {
    static func apply(to layer: CALayer?, in view: NSView) -> NSColor {
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        layer?.backgroundColor = dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 0.94) : CGColor(gray: 1, alpha: 0.96)
        layer?.borderWidth = contrast ? 1 : 0.5
        layer?.borderColor = dark ? CGColor(gray: 1, alpha: contrast ? 0.5 : 0.12) : CGColor(gray: 0, alpha: contrast ? 0.35 : 0.08)
        return dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.85)
    }
}

/// A capture's upload on its card, in a small reading capsule at the top: a ring that fills with the percent
/// and a cancel mark while it goes; a check and "Link copied" when it is done; a warning, "Upload failed" and
/// Retry when it did not work. It takes its own clicks, so a press on it neither drags the card nor does
/// what a click on the card does.
final class CardUploadBadge: NSView {
    /// Cancels while uploading; retries after a failure.
    var onAction: (() -> Void)?

    private let mark = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let action = NSTextField(labelWithString: "")
    private let ring = CAShapeLayer()
    private let track = CAShapeLayer()
    private let cancelMark = NSImageView()
    private var display: CardUpload?
    private var ink = NSColor.labelColor

    private static let height: CGFloat = 24
    private static let ringDiameter: CGFloat = 13

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: 1)
        label.font = Theme.Typeface.reading(size: 10.5, weight: .semibold)
        action.font = Theme.Typeface.reading(size: 10.5, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        for shape in [track, ring] {
            shape.fillColor = nil
            shape.lineWidth = 2
            shape.lineCap = .round
            // Progress steps are still: a ring that eased between them would trail what it measures.
            shape.actions = ["strokeEnd": NSNull(), "path": NSNull(), "strokeColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
        }
        ring.strokeEnd = 0
        layer?.addSublayer(track)
        layer?.addSublayer(ring)
        cancelMark.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        for view in [mark, label, action, cancelMark] { addSubview(view) }
        setAccessibilityElement(false)
        isHidden = true
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shows the upload's state, or nothing for nil.
    func show(_ new: CardUpload?) {
        let fading = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Theme.Motion.fade
        guard let new else {
            display = nil
            animateHidden(duration: fading)
            return
        }
        let wasHidden = isHidden || display == nil
        display = new
        switch new {
        case .uploading(let fraction):
            // Never 100% before the server has answered: a full ring still has the answer to wait for.
            label.stringValue = "\(min(Int((min(max(fraction, 0), 1) * 100).rounded()), 99))%"
            ring.strokeEnd = fraction
            toolTip = String(localized: "Uploading. Click the mark to cancel.", bundle: .module)
        case .finished(let copied):
            label.stringValue = copied ? String(localized: "Link copied", bundle: .module) : String(localized: "Uploaded", bundle: .module)
            toolTip = nil
        case .failed(let message):
            label.stringValue = String(localized: "Upload failed", bundle: .module)
            // Underlined in the badge's ink: the accent can be a color that does not read on white.
            action.attributedStringValue = NSAttributedString(string: String(localized: "Retry", bundle: .module), attributes: [
                .font: Theme.Typeface.reading(size: 10.5, weight: .semibold), .foregroundColor: ink,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
            toolTip = message
        }
        updateParts()
        if wasHidden {
            isHidden = false
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = fading
                animator().alphaValue = 1
            }
        }
    }

    private func animateHidden(duration: TimeInterval) {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, display == nil else { return }
            isHidden = true
        }
    }

    // MARK: Layout

    private func updateParts() {
        let uploading: Bool, failed: Bool
        switch display {
        case .uploading: (uploading, failed) = (true, false)
        case .failed: (uploading, failed) = (false, true)
        default: (uploading, failed) = (false, false)
        }
        ring.isHidden = !uploading
        track.isHidden = !uploading
        cancelMark.isHidden = !uploading
        action.isHidden = !failed
        mark.isHidden = uploading
        switch display {
        case .finished:
            mark.image = Self.symbol("checkmark.circle.fill", colors: [.white, .systemGreen])
        case .failed:
            mark.image = Self.symbol("exclamationmark.triangle.fill", colors: [.systemOrange])
        default:
            mark.image = nil
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
        if let superview { superview.needsLayout = true }
    }

    private static func symbol(_ name: String, colors: [NSColor]) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold).applying(.init(paletteColors: colors)))
    }

    /// The label's text at its natural size: a field that truncates reports a squeezed one of its own.
    private var labelSize: NSSize {
        let size = label.attributedStringValue.size()
        // A text field's cell wants a few points of its own around the text, or it shortens it.
        return NSSize(width: ceil(size.width) + 6, height: ceil(size.height))
    }

    private var actionWidth: CGFloat {
        ceil(action.attributedStringValue.size().width) + 6
    }

    private var isUploading: Bool {
        if case .uploading? = display { true } else { false }
    }

    private var leading: CGFloat { 8 }

    /// The most the badge may span: the card's width less the room of the corner buttons on both sides.
    private static let widest: CGFloat = 152

    private var trailing: CGFloat {
        switch display {
        case .uploading: 6 + 14 + 6
        case .failed: 8 + actionWidth + 11
        default: 9
        }
    }

    override var fittingSize: NSSize {
        let text = ceil(labelSize.width)
        let mark: CGFloat = (isUploading ? Self.ringDiameter : 13) + 5
        // The percent has room for "99%". A long label is cut with an ellipsis rather than reach the corner buttons.
        let body: CGFloat = isUploading ? max(text, 28) : text
        let wide: CGFloat = leading + mark + body + trailing
        return NSSize(width: min(wide, Self.widest), height: Self.height)
    }

    /// Where a press cancels or retries: the part of the capsule after the label.
    private var actionZone: CGRect {
        switch display {
        case .uploading, .failed: CGRect(x: label.frame.maxX + 2, y: 0, width: max(bounds.width - label.frame.maxX - 2, 0), height: bounds.height)
        default: .null
        }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let text = labelSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = height / 2
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
        let ringBox = CGRect(x: leading, y: (height - Self.ringDiameter) / 2, width: Self.ringDiameter, height: Self.ringDiameter).insetBy(dx: 1, dy: 1)
        // A ring starts at twelve o'clock and runs clockwise; the layer's own path starts at three.
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(origin: .zero, size: ringBox.size))
        track.path = path
        track.frame = ringBox
        let arc = CGMutablePath()
        arc.addArc(center: CGPoint(x: ringBox.width / 2, y: ringBox.height / 2), radius: ringBox.width / 2, startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: false)
        ring.path = arc
        ring.frame = ringBox
        CATransaction.commit()
        mark.frame = CGRect(x: leading, y: (height - 13) / 2, width: 13, height: 13)
        let labelX = leading + (display.map { if case .uploading = $0 { Self.ringDiameter } else { 13 } } ?? 13) + 5
        let room = max(bounds.width - labelX - trailing, 0)
        label.frame = CGRect(x: labelX, y: ((height - text.height) / 2).rounded(), width: min(ceil(text.width), room), height: text.height)
        let actionSize = NSSize(width: actionWidth, height: action.intrinsicContentSize.height)
        action.frame = CGRect(x: label.frame.maxX + 8, y: ((height - actionSize.height) / 2).rounded(), width: ceil(actionSize.width), height: actionSize.height)
        cancelMark.frame = CGRect(x: bounds.maxX - 6 - 14, y: (height - 14) / 2, width: 14, height: 14)
    }

    // MARK: Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        ink = BadgeMaterial.apply(to: layer, in: self)
        label.textColor = ink
        cancelMark.contentTintColor = ink.withAlphaComponent(0.7)
        track.strokeColor = ink.withAlphaComponent(0.16).cgColor
        // Fixed to the ink: a ring in the accent nearly vanishes on white when the accent is yellow.
        ring.strokeColor = ink.withAlphaComponent(0.85).cgColor
        if case .failed? = display { show(display) }
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        NSApp.preventWindowOrdering()
        let point = convert(event.locationInWindow, from: nil)
        if actionZone.contains(point) { onAction?() }
    }

    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}
