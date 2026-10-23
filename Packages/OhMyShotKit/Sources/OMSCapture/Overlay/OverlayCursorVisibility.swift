import AppKit

/// Owns one balanced cursor hide while the selection draws its pointer. Native controls temporarily
/// give that hide back; ending selection ownership prevents later tracking events from hiding again.
@MainActor
final class OverlayCursorVisibility {
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
