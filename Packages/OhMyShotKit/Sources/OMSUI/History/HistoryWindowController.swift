import AppKit
import Foundation
import Observation
import OMSCore
import SwiftUI

/// What the history window can do with an item.
public struct HistoryActions {
    public var restore: (HistoryItem) -> Void
    public var copy: (HistoryItem) -> Void
    /// Puts several captures' files on the clipboard, as Finder's Copy does with a selection.
    public var copyFiles: ([HistoryItem]) -> Void = { _ in }
    public var save: (HistoryItem) -> Void
    public var open: (HistoryItem) -> Void
    /// Opens the capture in the annotation editor, or a recording in the recording window.
    public var annotate: (HistoryItem) -> Void
    public var reveal: (HistoryItem) -> Void
    /// Opens the capture in the OCR panel.
    public var recognizeText: (HistoryItem) -> Void
    /// Keeps the capture on screen as a pin.
    public var pin: (HistoryItem) -> Void
    /// Prints a screenshot through the print panel, as a sheet on the window.
    public var print: (HistoryItem, NSWindow?) -> Void = { _, _ in }
    /// Moves the capture's file to the Trash; its record, marks, and text leave the history with it.
    public var moveToTrash: (HistoryItem) -> Void
    /// The file to hand to another app when a capture is dragged out: a copy in the format Settings choose, or nil for
    /// the capture's own file.
    public var fileToHandOver: (HistoryItem) -> URL? = { _ in nil }
    /// Uploading, for a person who set up a destination. Left as it is, the window offers none of it.
    public var sharing = Sharing()

    public struct Sharing {
        /// What the menu offers; read each time a menu opens, so a destination added or removed shows at once.
        public var menu: () -> UploadMenu = { .hidden }
        /// Uploads to a destination, or to the default for nil. The window does not wait for it.
        public var upload: (HistoryItem, UUID?) -> Void = { _, _ in }
        /// Whether the capture is being uploaded now.
        public var isUploading: (HistoryItem) -> Bool = { _ in false }
        public var cancel: (HistoryItem) -> Void = { _ in }
        /// Whether an earlier upload of the capture left a link that still works.
        public var hasLink: (HistoryItem) -> Bool = { _ in false }
        public var copyLink: (HistoryItem) -> Void = { _ in }
        /// Whether the capture's upload can be removed from its storage.
        public var canDeleteFromStorage: (HistoryItem) -> Bool = { _ in false }
        /// Asks, then removes the capture's upload from its storage.
        public var deleteFromStorage: (HistoryItem) -> Void = { _ in }

        public init() {}
    }

    public init(
        restore: @escaping (HistoryItem) -> Void,
        copy: @escaping (HistoryItem) -> Void,
        save: @escaping (HistoryItem) -> Void,
        open: @escaping (HistoryItem) -> Void,
        annotate: @escaping (HistoryItem) -> Void,
        reveal: @escaping (HistoryItem) -> Void,
        recognizeText: @escaping (HistoryItem) -> Void,
        pin: @escaping (HistoryItem) -> Void,
        moveToTrash: @escaping (HistoryItem) -> Void
    ) {
        self.restore = restore
        self.copy = copy
        self.save = save
        self.open = open
        self.annotate = annotate
        self.reveal = reveal
        self.recognizeText = recognizeText
        self.pin = pin
        self.moveToTrash = moveToTrash
    }
}

/// Capture History: every recent capture, restorable to Quick Access, and found by the text in it. Created
/// when opened and released when closed.
public final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    public var onClose: (() -> Void)?

    private let model: HistoryModel
    private let textReader: HistoryTextReader?
    private var windowLease: ActiveResources.Lease?
    private var readingShown: Task<Void, Never>?

    /// - Parameters:
    ///   - expiredCount: how many captures a retention would delete now, so the window can ask before
    ///     shortening it.
    ///   - textReader: what reads the captures' text, so the window can say while it does.
    public init(
        store: HistoryStore, settings: SettingsStore, actions: HistoryActions, textReader: HistoryTextReader?,
        expiredCount: @escaping (HistoryRetention) -> Int
    ) {
        model = HistoryModel(store: store, settings: settings, actions: actions, expiredCount: expiredCount)
        self.textReader = textReader
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = String(localized: "Capture History", bundle: .module)
        // The toolbar's room goes to the filter and the search field; the title stays in the Window menu.
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        super.init(window: window)
        model.window = window
        let content = NSHostingController(rootView: HistoryView(model: model))
        // The SwiftUI toolbar becomes the window's toolbar; the view sets only the minimum size.
        content.sceneBridgingOptions = [.toolbars]
        content.sizingOptions = [.minSize]
        window.contentViewController = content
        window.setContentSize(CGSize(width: 920, height: 640))
        window.setFrameAutosaveName("CaptureHistory")
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    #if DEBUG
    /// Prints the selected screenshot as File › Print… does, for scripted checks, which cannot make the window key.
    public func debugPrintSelection() -> Bool {
        guard let item = model.focusedItem, item.kind == .screenshot else { return false }
        model.print(item)
        return true
    }
    #endif

    public func show() {
        model.reload()
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        showReading()
        if window?.isVisible == false { window?.center() }
        showWindow(nil)
        AppActivation.bringForward(window)
    }

    /// Picks up captures taken while the window is open.
    public func reload() {
        model.reload()
    }

    /// Picks up new pictures of existing captures (marked up, or put back as taken).
    public func reload(changed ids: Set<UUID>) {
        model.reload(changed: ids)
    }

    /// Picks up the text just read in a capture, for searching it.
    public func textRead(_ id: UUID) {
        model.loadText(of: [id])
    }

    /// While captures are being read, a search says how many are left.
    private func showReading() {
        guard readingShown == nil, let textReader else { return }
        readingShown = Task { [weak self] in
            for await count in Observations({ textReader.reading }) {
                self?.model.reading = count
            }
        }
    }

    #if DEBUG
    /// Raises the confirmation that choosing `retention` would, or dismisses it with nil, without
    /// changing anything: for scripted checks of the dialog.
    public func previewRetentionChange(to retention: HistoryRetention?) {
        model.retentionRequest = retention.map { RetentionChangeRequest(retention: $0, count: model.expiredCount($0)) }
    }

    /// Searches for `query` as if it were typed into the search field.
    public func previewSearch(_ query: String) {
        model.query = query
    }

    /// Chooses All, Screenshots, or Recordings in the Show filter by name.
    public func previewFilter(_ name: String) {
        if let filter = HistoryModel.Filter(rawValue: name) { model.filter = filter }
    }
    #endif

    public func windowWillClose(_ notification: Notification) {
        // A closed window can be kept alive after its controller is gone, and with it everything its views hold:
        // the thumbnails loaded among it, some 55 MB once a long history has been scrolled through. They go now,
        // with the views, for left to SwiftUI they stayed a minute or more in one close of three. The window closes
        // at once, as it would show empty while it faded.
        window?.animationBehavior = .none
        model.release()
        window?.contentViewController = nil
        readingShown?.cancel()
        readingShown = nil
        windowLease?.end()
        windowLease = nil
        onClose?()
    }
}
