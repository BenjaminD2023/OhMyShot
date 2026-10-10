import AppKit
import CoreGraphics

/// One key pressed anywhere, as the keystroke display shows it.
public struct Keystroke: Equatable, Sendable {
    /// The key's virtual key code, the same on every keyboard layout.
    public let keyCode: UInt16
    /// Control, Option, Shift, and Command, as they were held.
    public let modifiers: NSEvent.ModifierFlags
    /// What the key types with the modifiers held ("A" with Shift); empty for keys that type nothing.
    public let characters: String
    /// What the key types without them ("a"), which names the key in a shortcut.
    public let keyCharacters: String
    /// Held down and repeating.
    public let isRepeat: Bool

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String, keyCharacters: String, isRepeat: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.control, .option, .shift, .command])
        self.characters = characters
        self.keyCharacters = keyCharacters
        self.isRepeat = isRepeat
    }
}

/// Every key pressed in any app while it runs: a listen-only event tap, which needs Input Monitoring. Keys
/// typed into secure fields (passwords) never reach it; the system keeps them from every tap.
@MainActor
public final class KeyMonitor {
    public var onPress: ((Keystroke) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    public init() {}

    /// Whether Input Monitoring lets the app see keys.
    public static var isAllowed: Bool {
        CGPreflightListenEventAccess()
    }

    public var isRunning: Bool {
        tap != nil
    }

    /// Starts listening on the main run loop; false when Input Monitoring is off.
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    let monitor = Unmanaged<KeyMonitor>.fromOpaque(context).takeUnretainedValue()
                    // The tap's source is on the main run loop.
                    MainActor.assumeIsolated { monitor.handle(type, event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    public func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            guard let key = NSEvent(cgEvent: event) else { return }
            onPress?(Keystroke(
                keyCode: key.keyCode, modifiers: key.modifierFlags, characters: key.characters ?? "",
                keyCharacters: key.charactersIgnoringModifiers ?? "", isRepeat: key.isARepeat
            ))
        default:
            break
        }
    }
}
