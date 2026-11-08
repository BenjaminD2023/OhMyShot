import AppKit
import Carbon.HIToolbox
import OMSCore
import OSLog

/// Escape, taken from every app while it is armed, for something of OhMyShot's that Escape stops but that has no window
/// to take the key in, such as a reading behind Capture Text's highlight. A Carbon hot key, as the capture shortcuts
/// are (`HotkeyCenter`): it needs no permission and leaves the app in front the keyboard for every other key, where a
/// panel made key would take all of them (a ⌘V pressed a moment early would go nowhere).
///
/// While a panel of OhMyShot's holds the keyboard without bringing the app forward (the overlay of a capture started
/// meanwhile, a card given the keys), Escape is that panel's, and goes to it as the key it was. A window of the app's
/// own in front (Settings, History, an editor) doesn't keep it: Escape stops what waits on it.
public final class EscapeHotKey {
    /// `EventHotKeyID.signature` for these, beside KeyboardShortcuts' own (`SSKS`), which leaves others' hot keys alone.
    private nonisolated static let signature: OSType = 0x4F_4D_53_45 // OMSE
    private static var handler: EventHandlerRef?
    private static var armed: [UInt32: Weak] = [:]
    private static var lastID: UInt32 = 0

    private struct Weak {
        weak var key: EscapeHotKey?
    }

    private let id: UInt32
    private let pressed: () -> Void
    private var hotKey: EventHotKeyRef?

    /// `pressed` runs on the main thread when Escape is pressed while armed, unless a panel of OhMyShot's holds the keyboard.
    public init(pressed: @escaping () -> Void) {
        Self.lastID += 1
        id = Self.lastID
        self.pressed = pressed
    }

    isolated deinit {
        disarm()
    }

    public var isArmed: Bool { hotKey != nil }

    /// Takes Escape until `disarm`. False when it can't: another app holds Escape alone as a hot key of its own.
    @discardableResult
    public func arm() -> Bool {
        guard hotKey == nil else { return true }
        guard Self.installHandler() else { return false }
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape), 0, EventHotKeyID(signature: Self.signature, id: id), GetEventDispatcherTarget(), 0, &hotKey
        )
        guard status == noErr, let hotKey else {
            Log.hotkeys.error("Escape couldn't be taken as a hot key: \(status, privacy: .public)")
            return false
        }
        self.hotKey = hotKey
        Self.armed[id] = Weak(key: self)
        return true
    }

    /// Gives Escape back to the app in front.
    public func disarm() {
        guard let hotKey else { return }
        UnregisterEventHotKey(hotKey)
        self.hotKey = nil
        Self.armed[id] = nil
    }

    /// One handler for every Escape hot key, on the event dispatcher, where KeyboardShortcuts registers its own.
    private static func installHandler() -> Bool {
        guard handler == nil else { return true }
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        let status = InstallEventHandler(GetEventDispatcherTarget(), escapeHotKeyHandler, types.count, &types, nil, &handler)
        guard status == noErr else {
            Log.hotkeys.error("Escape's hot key handler couldn't be installed: \(status, privacy: .public)")
            return false
        }
        return true
    }

    /// Carbon's call for a hot key: one of these is answered, any other left to the handler after (KeyboardShortcuts').
    fileprivate nonisolated static func handle(_ event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == signature else { return OSStatus(eventNotHandledErr) }
        let id = hotKeyID.id
        MainActor.assumeIsolated {
            guard let key = armed[id]?.key, key.isArmed else { return }
            if let window = NSApplication.shared.keyWindow, window.styleMask.contains(.nonactivatingPanel) {
                // A panel of OhMyShot's holds the keyboard for a moment, as the overlay does: the Escape is its.
                forwardEscape(to: window)
            } else {
                Log.hotkeys.notice("hotkey.escape")
                key.pressed()
            }
        }
        return noErr
    }

    #if DEBUG
    /// A press of this hot key as Carbon delivers one, through the dispatcher's handlers (KeyboardShortcuts' among
    /// them); only the window server's match of the key itself is left out. For scripted checks. False when not armed.
    @discardableResult
    public func simulatePress() -> Bool {
        guard isArmed else { return false }
        var event: EventRef?
        guard CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(), EventAttributes(kEventAttributeNone), &event) == noErr,
              let event
        else { return false }
        defer { ReleaseEvent(event) }
        var hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        return SendEventToEventTarget(event, GetEventDispatcherTarget()) == noErr
    }
    #endif

    /// Escape, as the key it was, to a panel of the app's that holds the keyboard.
    private static func forwardEscape(to window: NSWindow) {
        guard let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: UInt16(kVK_Escape)
        ) else { return }
        Log.hotkeys.notice("hotkey.escape went to the panel with the keyboard")
        NSApplication.shared.sendEvent(escape)
    }
}

private let escapeHotKeyHandler: EventHandlerUPP = { _, event, _ in
    EscapeHotKey.handle(event)
}
