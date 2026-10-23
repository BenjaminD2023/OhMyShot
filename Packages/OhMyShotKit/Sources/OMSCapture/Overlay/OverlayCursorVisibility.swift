import AppKit

/// Owns one balanced cursor hide while the selection draws its pointer. Native controls temporarily
/// give that hide back; ending selection ownership prevents later tracking events from hiding again.
///
/// The window server ignores a hide from an app in the background, and the overlay takes input a moment before
/// its activation is granted: a hide made then never took, and the system's pointer showed beside the drawn
/// crosshair. So the hide waits until the app is active (`activationChanged`), and is given back while it isn't.
@MainActor
final class OverlayCursorVisibility {
    private(set) var isHidden = false
    private var drawsPointer = false
    private var overControls = false
    private let isActive: () -> Bool
    private let hide: () -> Void
    private let unhide: () -> Void
    /// Hears `isHidden` change: the overlay draws its pointer only while the system's is hidden.
    var onChange: ((Bool) -> Void)?

    init(
        isActive: @escaping () -> Bool = { NSApp.isActive },
        hide: @escaping () -> Void = { NSCursor.hide() }, unhide: @escaping () -> Void = { NSCursor.unhide() }
    ) {
        self.isActive = isActive
        self.hide = hide
        self.unhide = unhide
    }

    func begin(drawsPointer: Bool, overControls: Bool) {
        self.drawsPointer = drawsPointer
        update(overControls: overControls)
    }

    func update(overControls: Bool) {
        self.overControls = overControls
        setHidden(drawsPointer && !overControls && isActive())
    }

    /// The app became active, or stopped being.
    func activationChanged() {
        update(overControls: overControls)
    }

    func end() {
        drawsPointer = false
        setHidden(false)
    }

    private func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        if hidden { hide() } else { unhide() }
        onChange?(hidden)
    }

    isolated deinit {
        if isHidden { unhide() }
    }
}
