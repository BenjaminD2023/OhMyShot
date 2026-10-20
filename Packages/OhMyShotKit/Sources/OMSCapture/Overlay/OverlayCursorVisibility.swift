import AppKit

/// Owns one balanced cursor hide while the selection draws its pointer. Native controls temporarily
/// give that hide back; ending selection ownership prevents later tracking events from hiding again.
@MainActor
final class OverlayCursorVisibility {
    /// An explicit transparent image also keeps the canvas clear if AppKit restores a native cursor.
    static let canvasCursor = NSCursor(
        image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            return true
        },
        hotSpot: .zero
    )

    static func restoreCanvasCursor() {
        if NSCursor.current === canvasCursor { NSCursor.arrow.set() }
    }

    private(set) var isHidden = false
    private var drawsPointer = false
    private let hide: () -> Void
    private let unhide: () -> Void

    init(hide: @escaping () -> Void = { NSCursor.hide() }, unhide: @escaping () -> Void = { NSCursor.unhide() }) {
        self.hide = hide
        self.unhide = unhide
    }

    func begin(drawsPointer: Bool, overControls: Bool) {
        self.drawsPointer = drawsPointer
        update(overControls: overControls)
    }

    func update(overControls: Bool) {
        setHidden(drawsPointer && !overControls)
    }

    func end() {
        drawsPointer = false
        setHidden(false)
    }

    private func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        if hidden { hide() } else { unhide() }
    }

    isolated deinit {
        if isHidden { unhide() }
    }
}
