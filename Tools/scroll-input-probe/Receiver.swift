import AppKit
import Foundation

var appEvents = 0
var eventPoint = ""
var eventWindow = 0
var localMonitor: Any?
let stateURL = URL(fileURLWithPath: "/tmp/ohmyshot-input-receiver.json")

final class Doc: NSView { override var isFlipped: Bool { true } }
final class Scroll: NSScrollView {
    var received = 0
    override func scrollWheel(with event: NSEvent) {
        received += 1
        super.scrollWheel(with: event)
        save()
    }
    func save() {
        guard let window else { return }
        let frame = window.frame
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let data: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier, "window": window.windowNumber,
            "x": frame.minX, "y": primaryHeight - frame.maxY, "width": frame.width, "height": frame.height,
            "received": received, "offset": contentView.bounds.origin.y,
            "appEvents": appEvents, "eventPoint": eventPoint, "eventWindow": eventWindow,
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: data) { try? bytes.write(to: stateURL, options: .atomic) }
    }
}
final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var scroll: Scroll!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let point = NSEvent.mouseLocation
        let x = point.x < screen.midX ? screen.maxX - 350 : screen.minX + 50
        window = NSWindow(contentRect: CGRect(x: x, y: screen.midY - 120, width: 280, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "OhMyShot input verification"
        window.isReleasedWhenClosed = false
        scroll = Scroll(frame: CGRect(x: 0, y: 0, width: 280, height: 240))
        scroll.hasVerticalScroller = true
        let doc = Doc(frame: CGRect(x: 0, y: 0, width: 280, height: 3000))
        for i in 0..<70 {
            let text = NSTextField(labelWithString: "Scroll test row \(i)")
            text.frame = CGRect(x: 20, y: i * 40, width: 220, height: 24)
            doc.addSubview(text)
        }
        scroll.documentView = doc
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        scroll.save()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .mouseMoved]) { event in
            appEvents += 1
            eventPoint = "delta=\(event.type == .scrollWheel ? event.scrollingDeltaY : 0) precise=\(event.type == .scrollWheel ? event.hasPreciseScrollingDeltas : false) type=\(event.type.rawValue) local=\(event.locationInWindow) global=\(String(describing:event.cgEvent?.location)) source=\(event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1) mark=\(event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? -1)"
            eventWindow = event.windowNumber
            return event
        }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.scroll.save() }
        Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in NSApp.terminate(nil) }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
