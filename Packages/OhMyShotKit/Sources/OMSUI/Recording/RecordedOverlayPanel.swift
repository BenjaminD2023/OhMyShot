import AppKit
import OMSCore
import OMSDesign

/// The clear, click-through window that what is drawn into a recording lies in: the clicks' rings and the keys
/// pressed. It stays on screen for as long as the recording runs, so the recording's content filter takes it in from
/// the start, and only what it draws comes and goes.
enum RecordedOverlayPanel {
    static func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Above what is recorded and the Dock, which a recording of a whole display takes in at its foot;
        // under menus.
        panel.level = RecordingWindowLevel.chrome
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        panel.contentView = view
        return panel
    }
}
