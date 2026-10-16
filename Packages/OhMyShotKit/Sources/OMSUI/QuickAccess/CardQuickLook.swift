import AppKit
import Foundation
import QuickLookUI

/// Quick Look for the capture of the card that has the keyboard: the system's preview panel, which shows a
/// picture at its size with Live Text and plays a recording. The preview owns the keyboard while it shows;
/// the arrows it receives move to the card above or below and the preview follows.
final class CardQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// The file shown.
    private(set) var url: URL?
    /// The arrows: the file of the card `offset` cards on (-1 above, 1 below), or nil at the end of the stack.
    var onMove: ((Int) -> URL?)?
    /// The preview went away, by Escape, Space, or its close button.
    var onClose: (() -> Void)?
    private var visibility: NSKeyValueObservation?
    private var closing: NSObjectProtocol?
    /// What the panel did on deactivating before the preview changed it: the History window's Quick Look is the
    /// same panel.
    private var hidesOnDeactivate = true

    /// Whether the preview is up showing a card's capture (it is one panel for the whole app: the History
    /// window's Quick Look is not this one).
    var isShowing: Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return false }
        let panel: QLPreviewPanel = QLPreviewPanel.shared()
        return panel.isVisible && (panel.dataSource as AnyObject?) === self
    }

    func show(_ url: URL) {
        self.url = url
        let panel: QLPreviewPanel = QLPreviewPanel.shared()
        panel.dataSource = self
        panel.delegate = self
        // It stays up while another app is in front: the card's panel never brings this app forward.
        if visibility == nil { hidesOnDeactivate = panel.hidesOnDeactivate }
        panel.hidesOnDeactivate = false
        panel.reloadData()
        // However the panel goes (its close button, Escape, Space), the preview is done with it.
        visibility = panel.observe(\.isVisible, options: [.new]) { [weak self] _, change in
            guard change.newValue == false else { return }
            MainActor.assumeIsolated { self?.closed() }
        }
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed() }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Shows another file in the preview that is already up, or the same file again after its contents changed
    /// (a picture turned under the preview).
    func replace(with url: URL) {
        let sameFile = self.url == url
        self.url = url
        guard isShowing else { return }
        let panel: QLPreviewPanel = QLPreviewPanel.shared()
        panel.reloadData()
        // A reload alone does not read a file again whose address has not changed.
        if sameFile { panel.refreshCurrentPreviewItem() }
    }

    func close() {
        guard isShowing else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    /// Lets the panel go: it does not keep its data source alive, so it must not be left pointing at this, and it
    /// is as it was for the History window.
    func detach() {
        visibility = nil
        if let closing { NotificationCenter.default.removeObserver(closing) }
        closing = nil
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return }
        let panel: QLPreviewPanel = QLPreviewPanel.shared()
        guard (panel.dataSource as AnyObject?) === self else { return }
        panel.dataSource = nil
        panel.delegate = nil
        panel.hidesOnDeactivate = hidesOnDeactivate
    }

    private func closed() {
        guard url != nil else { return }
        url = nil
        detach()
        onClose?()
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url.map { $0 as NSURL }
    }

    // MARK: QLPreviewPanelDelegate

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let offset: Int
        switch event.keyCode {
        case 123, 126: offset = -1
        case 124, 125: offset = 1
        default: return false
        }
        if let next = onMove?(offset) { replace(with: next) }
        return true
    }
}
