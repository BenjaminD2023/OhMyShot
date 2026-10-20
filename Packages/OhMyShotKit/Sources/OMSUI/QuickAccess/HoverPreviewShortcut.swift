import AppKit
import Carbon

/// Reserves just Space while a capture card is hovered. No event tap, keyboard monitoring permission,
/// stored shortcut, or focus change is needed; leaving the card immediately gives Space back.
final class HoverPreviewShortcut {
    var onPreview: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4F4D5350 // OMSP

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            stop()
            return false
        }
        if hotKey != nil { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetEventDispatcherTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    Unmanaged<HoverPreviewShortcut>.fromOpaque(context).takeUnretainedValue().handle(event)
                }
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard installed == noErr else { return false }
        let registered = RegisterEventHotKey(
            UInt32(kVK_Space), 0, EventHotKeyID(signature: Self.signature, id: 1),
            GetEventDispatcherTarget(), 0, &hotKey
        )
        guard registered == noErr else {
            stop()
            return false
        }
        return true
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    isolated deinit { stop() }

    private func handle(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        let status = GetEventParameter(
            event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &id
        )
        guard status == noErr, id.signature == Self.signature, id.id == 1, hotKey != nil else {
            return OSStatus(eventNotHandledErr)
        }
        onPreview?()
        return noErr
    }
}
