import AppKit

/// A transparent, borderless panel covering one display, above full-screen apps, the menu bar, open
/// menus, and the Dock.
///
/// While an area is chosen it sits at the screen-saver level: just above pop-up menus, macOS 26 and
/// later kept handing presses in the menu bar's band to the menu bar, so a selection could neither start
/// there nor be dragged up into it, and a press there opened a menu. When macOS's periodic Screen
/// Recording confirmation holds the first frame back, the overlay covers it for at most half a second,
/// until the overlay controller's watchdog dismisses it. In-place annotation goes back just above pop-up
/// menus, under input methods' candidate windows.
final class OverlayPanel: NSPanel {
    static let selectionLevel = NSWindow.Level.screenSaver
    static let annotationLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)

    var suppressesInputUntilTransientComparison = false
    private var deferredMouseEvents: [NSEvent] = []

    #if DEBUG
    var debugDeferredMouseEventCount: Int { deferredMouseEvents.count }
    #endif

    func configureInput(
        acceptingInput: Bool, suppressingInputUntilComparison: Bool,
        enqueueEvent: ((NSEvent, Bool) -> Void)? = nil
    ) {
        let wasSuppressingInput = suppressesInputUntilTransientComparison
        suppressesInputUntilTransientComparison = suppressingInputUntilComparison
        ignoresMouseEvents = !acceptingInput && !suppressingInputUntilComparison
        if wasSuppressingInput && acceptingInput && !suppressingInputUntilComparison {
            let events = deferredMouseEvents
            deferredMouseEvents.removeAll()
            Self.postInAppKitOrder(events) { event, atStart in
                if let enqueueEvent {
                    enqueueEvent(event, atStart)
                } else {
                    NSApplication.shared.postEvent(event, atStart: atStart)
                }
            }
        } else if !suppressingInputUntilComparison {
            deferredMouseEvents.removeAll()
        }
    }

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = Self.selectionLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        isMovable = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard suppressesInputUntilTransientComparison else { return super.performKeyEquivalent(with: event) }
        return event.type != .keyDown || event.keyCode != 53
    }

    override func sendEvent(_ event: NSEvent) {
        guard suppressesInputUntilTransientComparison else {
            super.sendEvent(event)
            return
        }
        guard event.type == .keyDown else {
            if Self.isMouseEvent(event.type) { deferredMouseEvents.append(event) }
            return
        }
        guard Self.dispatches(event.type, keyCode: event.keyCode, whileComparisonPending: true) else { return }
        super.sendEvent(event)
    }

    static func isMouseEvent(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
             .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            true
        default:
            false
        }
    }

    static func postInAppKitOrder(_ events: [NSEvent], enqueue: (NSEvent, Bool) -> Void) {
        for event in events.reversed() { enqueue(event, true) }
    }

    static func dispatches(
        _ type: NSEvent.EventType, keyCode: UInt16, whileComparisonPending: Bool
    ) -> Bool {
        !whileComparisonPending || (type == .keyDown && keyCode == 53)
    }
}
