import AppKit

/// Owns one balanced cursor hide while the selection draws its pointer. Native controls temporarily
/// give that hide back; ending selection ownership prevents later tracking events from hiding again.
///
/// The overlay's app is seldom the one in front (the overlay takes the keyboard without it), and some apps in front keep
/// the pointer shown over a hide made from behind them; the image set from behind still shows. So while hidden the
/// pointer is also the blank cursor, put back on every move (`keepHidden`), and it comes back as the arrow.
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
    private let keepHidden: () -> Void

    init(
        hide: @escaping () -> Void = { NSCursor.hide() },
        unhide: @escaping () -> Void = { NSCursor.unhide(); NSCursor.arrow.set() },
        keepHidden: @escaping () -> Void = { OverlayCursorVisibility.canvasCursor.set() }
    ) {
        self.hide = hide
        self.unhide = unhide
        self.keepHidden = keepHidden
    }

    func begin(drawsPointer: Bool, overControls: Bool) {
        self.drawsPointer = drawsPointer
        update(overControls: overControls)
    }

    func update(overControls: Bool) {
        setHidden(drawsPointer && !overControls)
        if isHidden { keepHidden() }
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

/// Lets the overlay hide and change the pointer before macOS makes OhMyShot the active app, or when it never does: the
/// window server ignores cursor changes from an app in the background, and after a global shortcut activation comes late
/// or not at all (`NSApp.isActive` can even say true meanwhile). The hide then never took, and the system's pointer showed
/// beside the drawn crosshair. Private window-server API, looked up at run time; where it is missing nothing changes.
enum BackgroundCursor {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    static func allow(_ allowed: Bool) {
        let process = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connection = dlsym(process, "CGSMainConnectionID"), let set = dlsym(process, "CGSSetConnectionProperty") else { return }
        let id = unsafeBitCast(connection, to: MainConnection.self)()
        _ = unsafeBitCast(set, to: SetProperty.self)(id, id, "SetsCursorInBackground" as CFString, allowed ? kCFBooleanTrue : kCFBooleanFalse)
    }
}
