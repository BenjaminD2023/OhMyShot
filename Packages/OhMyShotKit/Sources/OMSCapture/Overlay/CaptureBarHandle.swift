import AppKit

/// A grip that moves its owner's bar without starting a capture selection. Deltas stay in AppKit
/// window coordinates; a flipped owner converts their vertical direction when placing its bar.
final class CaptureBarHandle: NSView {
    var onMove: ((CGVector, CGPoint) -> Void)?
    private(set) var isDragging = false
    private var previousPoint: CGPoint?
    private let symbol = NSImageView()

    init() {
        super.init(frame: .zero)
        symbol.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        symbol.contentTintColor = .labelColor
        symbol.imageScaling = .scaleNone
        symbol.setAccessibilityElement(false)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbol)
        NSLayoutConstraint.activate([
            symbol.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 18),
            symbol.heightAnchor.constraint(equalToConstant: 20),
        ])
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        toolTip = String(localized: "Drag to move toolbar", bundle: .module)
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel(String(localized: "Move toolbar", bundle: .module))
        setAccessibilityHelp(toolTip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        previousPoint = event.locationInWindow
        isDragging = true
        NSCursor.closedHand.set()
        onMove?(.zero, event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previousPoint, isDragging else { return }
        let point = event.locationInWindow
        self.previousPoint = point
        onMove?(CGVector(dx: point.x - previousPoint.x, dy: point.y - previousPoint.y), point)
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        previousPoint = nil
        NSCursor.openHand.set()
        // The pointer may have stayed still while the bar reached an edge. Its owner reconciles the
        // cursor immediately rather than waiting for a further mouse move.
        onMove?(.zero, event.locationInWindow)
        window?.invalidateCursorRects(for: self)
    }
}
