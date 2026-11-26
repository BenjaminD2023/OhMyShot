import AppKit
import CoreGraphics
import OMSDesign
import Observation
import OMSCore
import SwiftUI
import UniformTypeIdentifiers

/// The annotation editor: a standard window holding the canvas, its tool rail and style capsule, and a
/// toolbar with Undo and Redo, zoom, a handle to drag the capture out, Save, and Copy.
///
/// Edits are kept in the capture itself (its file shows the marks, and the marks stay editable) when the
/// window closes and whenever the capture leaves it: copied, saved, dragged out, pinned, uploaded, or shared.
public final class AnnotationEditorWindowController: NSWindowController, NSWindowDelegate {
    public enum Presentation: Equatable, Sendable {
        case editor
        case preview
    }

    public struct Actions {
        /// Keeps the marked-up capture in place of the capture: the PNG, the image, and the document that
        /// recreates it. Returns the file that now holds the capture.
        public var keep: (_ document: AnnotationDocument, _ png: Data, _ image: CGImage) -> URL?
        /// Saves a copy of the capture's file to the export location; returns where it went, or nil when it was not saved
        /// (cancelled, or failed, which it has said why for).
        public var save: (_ file: URL) async -> URL?
        /// Asks where and how to save a copy of the capture's file, in the Save panel; returns where it went, or nil when
        /// it was not saved. Nil when the editor offers no Save As.
        public var saveAs: ((_ file: URL) async -> URL?)?
        /// The file to hand to another app when the capture is dragged out of the window: the capture's file itself, or a
        /// copy of it in the format Settings choose; nil when that copy could not be made, which the app says, and then
        /// nothing goes.
        public var fileToHandOver: (_ file: URL) -> URL? = { $0 }
        /// Puts the rendered picture on the clipboard, with its pixels per point, and returns whether it succeeded. Without a
        /// callback, the PNG goes as it is.
        public var copy: ((_ image: CGImage, _ png: Data, _ scale: CGFloat) async -> Bool)?
        /// Pins the picture as it looks now over the screen, at its pixels per point, and whether it was kept in the capture's
        /// file: one that wasn't is the pin's own, since the file doesn't show it. Nil when the editor offers no Pin to Screen.
        public var pin: ((_ image: CGImage, _ scale: CGFloat, _ kept: Bool) -> Void)?
        /// What the editor offers for uploading, asked each time the window comes forward: nothing without a destination.
        public var uploadMenu: () -> UploadMenu = { .hidden }
        /// Uploads the capture's file, its edits kept, to the default destination (nil) or the one chosen. Nil when the
        /// editor offers no Upload.
        public var upload: ((_ file: URL, _ destination: UUID?) -> Void)?
        /// Whether the capture is uploading now. A capture uploads once at a time, so Upload waits for that one to end.
        public var isUploading: () -> Bool = { false }
        /// Opens text recognition on the rendered capture. Nil when the editor offers no Recognize Text.
        public var recognizeText: ((_ image: CGImage, _ scale: CGFloat, _ title: String) -> Void)?
        /// Prints the rendered capture; nil prints directly from this window with `ImagePrinter`.
        public var print: ((_ image: CGImage, _ scale: CGFloat, _ title: String, _ window: NSWindow?) -> Void)?

        public init(keep: @escaping (AnnotationDocument, Data, CGImage) -> URL?, save: @escaping (URL) async -> URL?) {
            self.keep = keep
            self.save = save
        }
    }

    enum CloseChoice {
        case save
        case dontSave
        case cancel
    }

    public var onClose: (() -> Void)?
    /// Whether closing with unsaved changes prompts Save / Don't Save / Cancel instead of silently
    /// overwriting the file on disk (true for external `.ohmyshot` projects; false for History captures).
    public var confirmsSaveOnClose = false
    /// Overridable close-confirmation presenter for tests.
    var confirmSaveOnClose: ((_ title: String, _ completion: @escaping @MainActor (CloseChoice) -> Void) -> Void)?
    public let session: AnnotationSession
    public private(set) var presentation: Presentation

    /// Current thumbnail shown by `DragOutHandle`, exposed for tests.
    var currentThumbnail: CGImage? { model.thumbnail }
    /// Whether the Picture › Revert to Original action is currently enabled.
    var canRevertToOriginal: Bool { model.canRevertToOriginal }

    private let model: EditorModel
    let content: EditorContentView
    private let actions: Actions
    private var fileURL: URL?
    private var windowLease: ActiveResources.Lease?
    private var closing: Task<Bool, Never>?
    public private(set) var didClose = false
    /// The Image Size sheet, while it is down.
    private var imageSizeSheet: NSWindow?
    /// Background render task keeping `DragOutHandle`'s preview thumbnail in sync with edits.
    private var thumbnailTask: Task<Void, Never>?

    /// - Parameters:
    ///   - image: the capture as it was taken.
    ///   - scale: pixels per point of the screen it came from.
    ///   - document: marks made on it before.
    ///   - fileURL: the capture's file, or nil until History can retain the picture and its marks.
    public init(image: CGImage, scale: CGFloat, document: AnnotationDocument?, title: String, fileURL: URL?, actions: Actions, presentation: Presentation = .editor) {
        self.presentation = presentation
        session = AnnotationSession(image: image, scale: scale, document: document, tool: presentation == .preview ? .select : nil)
        session.hasUnkeptChanges = fileURL == nil
        content = EditorContentView(session: session, presentation: presentation)
        model = EditorModel()
        self.actions = actions
        self.fileURL = fileURL
        let size = Self.preferredSize(for: session.document.pictureSize, scale: session.document.scale, presentation: presentation)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = title
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = presentation == .preview ? Self.previewMinimumSize : Self.minimumSize
        window.isDocumentEdited = session.hasUnkeptChanges
        super.init(window: window)
        model.controller = self
        model.presentation = presentation
        model.thumbnail = session.picture
        model.locksCanvas = session.locksCanvas
        model.canRevertToOriginal = session.canRevertToOriginal
        model.hasSelection = !session.selection.isEmpty
        let hosting = NSHostingController(rootView: EditorView(model: model, content: content))
        hosting.sceneBridgingOptions = [.toolbars]
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(size)
        window.center()
        window.delegate = self

        content.canvas.onCopy = { [weak self] in self?.copyCapture() }
        content.canvas.onReturn = { [weak self] in self?.copyCapture(thenClose: true) }
        content.canvas.onSave = { [weak self] in self?.save() }
        content.canvas.onSaveProject = { [weak self] in self?.saveProject() }
        if actions.saveAs != nil {
            content.canvas.onSaveAs = { [weak self] in self?.saveAs() }
        }
        content.canvas.onPrint = { [weak self] in self?.printCapture() }
        content.canvas.onImageSize = { [weak self] in self?.presentImageSize() }
        content.canvas.onUndoStateChange = { [weak self] in self?.undoChanged() }
        content.onViewportChange = { [weak self] in self?.updateZoomLabel() }
        content.onClosePreview = { [weak self] in self?.window?.performClose(nil) }
        session.observe { [weak self] event in
            guard let self else { return }
            if event == .history || event == .document { undoChanged() }
            if event == .document {
                updateWindowSubtitle()
                model.canRevertToOriginal = session.canRevertToOriginal
            }
            if event == .selection || event == .document {
                model.hasSelection = !session.selection.isEmpty
            }
            if (event == .document && !session.isInLiveChange) || event == .history {
                scheduleThumbnailRefresh()
            }
            if event == .settings { model.locksCanvas = session.locksCanvas }
            // An advanced tool chosen by its existing keyboard shortcut, or an advanced mark selected
            // in an older capture, opens the full controls without replacing the document.
            if self.presentation == .preview, event == .tool || event == .selection {
                let previewTools = ToolRail.previewGroups.joined()
                if !previewTools.contains(session.tool) || !previewTools.contains(session.currentKind) {
                    expandToFullEditor()
                }
            }
        }
        updateWindowSubtitle()
        if !session.document.isEmpty { scheduleThumbnailRefresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The smallest the window goes: room for the rail (534 pt) above the capsule's resting band (under the
    /// toolbar's 52 pt), and for the widest the style capsule is (the redaction's with a reading that failed
    /// and a full row of kept colors, 884 pt, beside the rail with 8 pt to spare). A test measures them.
    static let minimumSize = CGSize(width: 996, height: 672)
    /// The shorter preview rail and its bottom style band need less vertical space than the editor.
    static let previewMinimumSize = CGSize(width: 880, height: 480)

    /// The window shows the picture at the size it had on screen, with room for the rail and the capsule,
    /// within most of the screen.
    private static func preferredSize(for pixels: CGSize, scale: CGFloat, presentation: Presentation = .editor) -> CGSize {
        let picture = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let width = if presentation == .preview {
            min(max(picture.width + 100, previewMinimumSize.width), max(previewMinimumSize.width, min(960, visible.width * 0.8)))
        } else {
            min(max(picture.width + 72 + 28, minimumSize.width), visible.width * 0.9)
        }
        let height = if presentation == .preview {
            min(max(picture.height + 120, 520), max(previewMinimumSize.height, min(620, visible.height * 0.75)))
        } else {
            min(max(picture.height + 24 + 62 + 52, minimumSize.height), visible.height * 0.9)
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// Positions this editor's window cascaded from `reference` so multiple editors stay clearly visible.
    public func cascade(from reference: NSWindow) {
        guard let window, window !== reference else { return }
        let nextTopLeft = reference.cascadeTopLeft(from: .zero)
        window.cascadeTopLeft(from: nextTopLeft)
    }

    /// Reveals the complete editor in the same window, retaining the canvas, text edit, crop and undo history.
    public func expandToFullEditor() {
        guard presentation == .preview, let window else { return }
        presentation = .editor
        model.presentation = .editor
        content.setPresentation(.editor)
        window.minSize = Self.minimumSize
        let size = Self.preferredSize(for: session.document.pictureSize, scale: session.document.scale)
        let top = window.frame.maxY
        let origin = window.frame.origin
        window.setContentSize(size)
        var frame = window.frame
        frame.origin = CGPoint(x: origin.x, y: top - frame.height)
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
            frame.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        }
        window.setFrame(frame, display: true)
        updateZoomLabel()
    }

    public func show() {
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        model.uploadMenu = actions.uploadMenu()
        showWindow(nil)
        AppActivation.bringForward(window)
        window?.makeFirstResponder(content.canvas)
        updateZoomLabel()
    }

    #if DEBUG
    /// For scripted screenshots that show nothing: the window behind the wallpaper in the middle of the
    /// main display, ordered in without making the app active.
    public func showBehindWallpaper() {
        guard let window else { return }
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        if let screen = NSScreen.screens.first {
            window.setFrameOrigin(CGPoint(x: screen.frame.midX - window.frame.width / 2, y: screen.frame.midY - window.frame.height / 2))
        }
        window.orderFront(nil)
        window.makeFirstResponder(content.canvas)
        updateZoomLabel()
    }

    /// For scripted screenshots: a tool in hand, a mark selected (by its place in the document), a text
    /// mark being edited, the capture at its actual size.
    public func preview(tool: AnnotationTool?, select: Int?, editText: Int?, actualSize: Bool) {
        if let tool { session.tool = tool }
        if let select, session.document.items.indices.contains(select) {
            session.select([session.document.items[select].id])
        }
        if let editText, session.document.items.indices.contains(editText) {
            content.canvas.beginEditing(session.document.items[editText].id, isNew: false)
        }
        if actualSize { content.canvas.zoomToActualSize() }
    }

    /// Drags on the canvas with synthesized events, from and to points in the capture's pixels, as a
    /// pointer would, without moving the real one.
    public func simulateDrag(from start: CGPoint, to end: CGPoint, steps: Int = 8, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
        guard let window else { return }
        let canvas = content.canvas
        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: canvas.windowPoint(forDocument: point), modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clickCount, pressure: 1
            )
        }
        if let down = event(.leftMouseDown, at: start) { canvas.mouseDown(with: down) }
        for step in 1...max(steps, 1) {
            let fraction = CGFloat(step) / CGFloat(max(steps, 1))
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            if let drag = event(.leftMouseDragged, at: point) { canvas.mouseDragged(with: drag) }
        }
        if let up = event(.leftMouseUp, at: end) { canvas.mouseUp(with: up) }
    }

    /// Presses a key on the canvas, or types into the text being edited.
    public func simulateKey(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let window, let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ) else { return }
        if modifiers.contains(.command) {
            if !window.performKeyEquivalent(with: event) {
                // The main menu answers only for the key window, which a scripted run seldom has: send its
                // action down the responder chain the way the menu would.
                let item = NSApp.mainMenu.flatMap { Self.item(in: $0, key: characters.lowercased(), modifiers: modifiers) }
                if let item, let action = item.action, let responder = window.firstResponder {
                    let target = NSApp.target(forAction: action, to: nil, from: item) as? NSResponder ?? Self.responder(for: action, from: responder)
                    if let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) {
                        NSSound.beep()
                    } else {
                        target?.tryToPerform(action, with: item)
                    }
                }
            }
        } else {
            window.firstResponder?.keyDown(with: event)
        }
    }

    private static func item(in menu: NSMenu, key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
        for item in menu.items {
            if let submenu = item.submenu, let found = self.item(in: submenu, key: key, modifiers: modifiers) { return found }
            if item.keyEquivalent.lowercased() == key, item.keyEquivalentModifierMask == modifiers.intersection([.command, .shift, .option, .control]) {
                return item
            }
        }
        return nil
    }

    private static func responder(for action: Selector, from start: NSResponder) -> NSResponder? {
        var responder: NSResponder? = start
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        return nil
    }

    public func simulateZoomIn(_ steps: Int) {
        for _ in 0..<steps { content.canvas.zoomIn() }
    }

    public func simulateUndo(redo: Bool) {
        redo ? self.redo() : undo()
    }

    /// Opens the background's adjustments, as their chip in the capsule does.
    public func showBackdropAdjustments() {
        content.debugShowAdjustments()
    }

    /// Combines picture files into the capture at `point` (pixels), as a drop does.
    public func simulateDrop(_ urls: [URL], at point: CGPoint) {
        content.canvas.place(IncomingPicture.keep(urls), at: point)
    }

    /// Shows the canvas as pictures dragged over it see it.
    public func simulateDropTarget(_ shown: Bool) {
        content.canvas.debugShowDropTarget(shown)
    }

    /// Pastes pictures from `pasteboard`, as ⌘V does from the clipboard.
    public func simulatePaste(from pasteboard: NSPasteboard) {
        content.canvas.pastePictures(from: pasteboard)
    }

    /// Who would receive ⌘Z: each responder from the first responder up, whether it answers undo:,
    /// and the undo manager it would use.
    public var debugUndoChain: String {
        var parts: [String] = []
        var responder = window?.firstResponder
        let undo = Selector(("undo:"))
        while let current = responder {
            let answers = current.responds(to: undo)
            let manager = current.undoManager
            let mark = manager === session.undoManager ? "session" : manager == nil ? "nil" : "other"
            parts.append("\(type(of: current))\(answers ? "*" : "")[\(mark)]")
            responder = current.nextResponder
        }
        return parts.joined(separator: " > ") + " windowUndo=\(window?.undoManager === session.undoManager) modelCanUndo=\(model.canUndo)"
    }

    /// A summary for scripted checks: the marks by kind, the selection, the tool, undo state.
    public var debugSummary: String {
        let kinds = session.document.items.map { item -> String in
            if case .counter(let counter) = item.shape { return "counter(\(counter.label))" }
            if case .image(let image) = item.shape { return "image(\(NSStringFromRect(image.rect)))" }
            if case .textHighlight(let highlight) = item.shape { return "textHighlight(\(highlight.rects.map { NSStringFromRect($0) }.joined(separator: "|")))" }
            return AnnotationSession.tool(for: item).rawValue
        }.joined(separator: ",")
        var backdrop = "none"
        if let current = session.document.backdrop, let layout = session.backdropLayout {
            backdrop = "\(current.fill) pad=\(current.padding) inset=\(current.inset) balanced=\(current.balanced) corners=\(current.cornerRadius) shadow=\(current.shadow) ratio=\(current.ratio.map { "\($0.width):\($0.height)" } ?? "auto") align=\(current.alignment.rawValue) output=\(NSStringFromRect(layout.output)) card=\(NSStringFromRect(layout.card)) matte=\(layout.matte != nil) bare=\(layout.isBare)"
        }
        return "backdrop=[\(backdrop)] marks=[\(kinds)] selected=\(session.selection.count) tool=\(session.tool.rawValue) canvas=\(NSStringFromRect(session.document.canvas)) undo=\(session.undoManager.canUndo ? session.undoManager.undoActionName : "-") redo=\(session.undoManager.canRedo ? session.undoManager.redoActionName : "-") unkept=\(session.hasUnkeptChanges) editing=\(content.canvas.isEditingText) suggestions=\(session.isFindingRedactions ? "finding" : session.couldNotFindRedactions ? "failed" : session.openRedactionSuggestions.map { "\($0.label)@\(NSStringFromRect($0.rect))" }.joined(separator: ";")) textlines=\(session.isFindingTextLines ? "finding" : session.couldNotFindTextLines ? "failed" : "\(session.textLines.count)")"
    }
    #endif

    // MARK: Window

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard closing == nil else { return false }
        content.canvas.endEditing()
        guard session.hasUnkeptChanges else { return true }
        _ = startClosing()
        return false
    }

    public func closeBeforeQuitting() async -> Bool {
        if didClose { return true }
        return await startClosing().value
    }

    private func startClosing() -> Task<Bool, Never> {
        if let closing { return closing }
        let task = Task { () -> Bool in
            defer { closing = nil }
            guard let window, window.attachedSheet == nil else { return false }
            self.content.canvas.endEditing()
            if !self.session.hasUnkeptChanges {
                window.close()
                return true
            }
            if self.confirmsSaveOnClose {
                switch await self.askSaveOnClose(for: window) {
                case .save:
                    break
                case .dontSave:
                    guard window.attachedSheet == nil else { return false }
                    window.close()
                    return true
                case .cancel:
                    return false
                }
            }
            let mayClose = await EditorCloseRecovery.mayClose {
                self.content.canvas.endEditing()
                guard await self.exportAndKeep() != nil else { return .failed }
                self.content.canvas.endEditing()
                return self.session.hasUnkeptChanges ? .changedWhileKeeping : .kept
            } choose: {
                guard window.attachedSheet == nil else { return .keepEditing }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Your edits couldn’t be saved.", bundle: .module)
                alert.informativeText = String(localized: "Try again, save an editable project, or discard these edits.", bundle: .module)
                alert.addButton(withTitle: String(localized: "Retry", bundle: .module))
                alert.addButton(withTitle: String(localized: "Save a Copy as Project…", bundle: .module))
                alert.addButton(withTitle: String(localized: "Discard Edits", bundle: .module)).hasDestructiveAction = true
                alert.addButton(withTitle: String(localized: "Keep Editing", bundle: .module)).keyEquivalent = "\u{1b}"
                AppActivation.bringForward(window)
                switch await alert.beginSheetModal(for: window) {
                case .alertFirstButtonReturn: return .retry
                case .alertSecondButtonReturn: return .saveProject
                case .alertThirdButtonReturn: return .discard
                default: return .keepEditing
                }
            } saveProject: {
                guard let saved = await self.saveProjectCopy() else { return false }
                self.content.canvas.endEditing()
                return self.session.document == saved
            }
            guard mayClose, window.attachedSheet == nil else { return false }
            window.close()
            return true
        }
        closing = task
        return task
    }

    private func askSaveOnClose(for window: NSWindow) async -> CloseChoice {
        if let confirmSaveOnClose {
            return await withCheckedContinuation { continuation in
                confirmSaveOnClose(window.title) { choice in
                    continuation.resume(returning: choice)
                }
            }
        }
        guard window.attachedSheet == nil else { return .cancel }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Do you want to save the changes made to “\(window.title)”?", bundle: .module)
        alert.informativeText = String(localized: "Your changes will be lost if you don’t save them.", bundle: .module)
        alert.addButton(withTitle: String(localized: "Save", bundle: .module))
        let cancelButton = alert.addButton(withTitle: String(localized: "Cancel", bundle: .module))
        cancelButton.keyEquivalent = "\u{1b}"
        let dontSaveButton = alert.addButton(withTitle: String(localized: "Don’t Save", bundle: .module))
        dontSaveButton.hasDestructiveAction = true
        dontSaveButton.keyEquivalent = "d"
        dontSaveButton.keyEquivalentModifierMask = .command
        AppActivation.bringForward(window)
        switch await alert.beginSheetModal(for: window) {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .dontSave
        default: return .cancel
        }
    }

    /// Destinations are set up in Settings, so coming back from there brings the Upload entries up to date.
    public func windowDidBecomeKey(_ notification: Notification) {
        model.uploadMenu = actions.uploadMenu()
    }

    public func windowWillClose(_ notification: Notification) {
        didClose = true
        thumbnailTask?.cancel()
        thumbnailTask = nil
        content.releaseColorPanel()
        model.cancelFlashes()
        windowLease?.end()
        windowLease = nil
        onClose?()
    }

    /// Keeps the edits at once, on this thread, before handing out a drag.
    public func keepNow() {
        content.canvas.endEditing()
        let document = session.document
        guard session.hasUnkeptChanges, let image = AnnotationRenderer.flatten(document, base: session.base), let png = try? ImageExporter.encoded(image, as: .png, pixelsPerPoint: Double(document.scale)),
              let url = actions.keep(document, png, image) else { return }
        fileURL = url
        model.thumbnail = Self.scaledThumbnail(from: image)
        if session.document == document { session.markKept() }
    }

    // MARK: Actions

    /// Copies pending text and crop edits; previews, toolbar Copy and Return close after a successful write.
    /// A distinct name avoids NSObject.copy() winning overload resolution over a default argument.
    @discardableResult
    func copyCapture(thenClose: Bool? = nil) -> Task<Void, Never> {
        let closesAfterCopy = thenClose ?? (presentation == .preview)
        content.canvas.endEditing()
        content.canvas.commitCrop()
        return Task {
            guard let rendered = await render() else {
                NSSound.beep()
                VoiceOver.announce(String(localized: "The picture couldn’t be copied.", bundle: .module), from: content.canvas)
                return
            }
            let copied: Bool
            if let copy = actions.copy {
                copied = await copy(rendered.image, rendered.png, rendered.document.scale)
            } else {
                copied = PasteboardWriter.write(png: rendered.png, image: rendered.image)
            }
            guard copied else {
                NSSound.beep()
                VoiceOver.announce(String(localized: "The picture couldn’t be copied.", bundle: .module), from: content.canvas)
                return
            }
            if !closesAfterCopy { model.flashCopied() }
            VoiceOver.announce(String(localized: "Copied", bundle: .module), from: closesAfterCopy ? nil : content.canvas)
            if !confirmsSaveOnClose { _ = keep(rendered) }
            if closesAfterCopy { window?.performClose(nil) }
        }
    }

    func save() {
        content.canvas.endEditing()
        content.canvas.commitCrop()
        Task {
            guard let file = await exportAndKeep() else {
                NSSound.beep()
                return
            }
            // A save that failed has said why already, and one that was cancelled (Escape in the name alert) did not mean
            // to save: neither is said again here.
            guard await actions.save(file) != nil else { return }
            model.flashSaved()
        }
    }

    var offersSaveAs: Bool { actions.saveAs != nil }

    var offersPin: Bool { actions.pin != nil }

    var offersRecognizeText: Bool { actions.recognizeText != nil }

    /// Pins the picture as it looks now, its edits kept in the capture first, as Copy keeps them. The window stays open.
    @discardableResult
    func pin() -> Task<Void, Never> {
        content.canvas.endEditing()
        return Task {
            guard let pin = actions.pin else { return }
            guard let rendered = await render() else { return NSSound.beep() }
            // A failed keep gives the pin its own picture without the stale capture identity.
            let kept = confirmsSaveOnClose ? false : keep(rendered) != nil
            pin(rendered.image, rendered.document.scale, kept)
        }
    }

    /// Uploads the capture with its edits kept in it, to the default destination (nil) or the one chosen, as a card's
    /// Upload does. Edits that can't be kept upload nothing, since the file would not show them.
    @discardableResult
    func upload(to destination: UUID? = nil) -> Task<Void, Never> {
        content.canvas.endEditing()
        return Task {
            guard let upload = actions.upload else { return }
            guard !actions.isUploading(), let file = await prepareFileForHandOver(applyFormat: false) else { return NSSound.beep() }
            upload(file, destination)
        }
    }

    /// Opens the OCR panel on the rendered capture.
    @discardableResult
    func recognizeText() -> Task<Void, Never> {
        content.canvas.endEditing()
        return Task {
            guard let recognizeAction = actions.recognizeText else { return }
            guard let image = await session.render() else {
                NSSound.beep()
                return
            }
            recognizeAction(image, session.document.scale, window?.title ?? "")
        }
    }

    /// Switches to Background mode and opens the Adjust popover scrolled/focused on Watermark.
    func showWatermark() {
        content.canvas.endEditing()
        content.showWatermarkAdjustments()
    }

    /// Offers the capture to the system's share menu, its edits kept, in the format Settings choose, as a card's
    /// Share… does. It comes down where the pointer is in the window, or from the middle.
    func share() {
        Task {
            guard let file = await fileForSharing() else { return NSSound.beep() }
            guard let window, let view = window.contentView else { return }
            let pointer = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            let anchor = view.bounds.contains(pointer) ? pointer : CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            NSSharingServicePicker(items: [file]).show(relativeTo: CGRect(origin: anchor, size: CGSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
        }
    }

    /// The file to share, with the edits kept in it first (or rendered to the preview file for external projects);
    /// nil when they could not be kept or rendered.
    func fileForSharing() async -> URL? {
        content.canvas.endEditing()
        return await prepareFileForHandOver(applyFormat: true)
    }

    /// Asks where to save a copy of the picture as it looks now, and in what format and how, then saves it there. The
    /// marks are kept first, as Save keeps them.
    func saveAs() {
        guard let saveAs = actions.saveAs else { return }
        content.canvas.endEditing()
        Task {
            guard let file = await exportAndKeep() else {
                NSSound.beep()
                return
            }
            guard await saveAs(file) != nil else { return }
            model.flashSaved()
        }
    }

    /// Saves a copy of the capture as it was taken and every mark as a project file, which the editor
    /// opens again with the marks editable. The window goes on editing what it edited before.
    func saveProject() {
        Task { _ = await saveProjectCopy() }
    }

    private func saveProjectCopy() async -> AnnotationDocument? {
        guard let window, window.attachedSheet == nil else { return nil }
        content.canvas.endEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [AnnotationProject.contentType]
        panel.nameFieldStringValue = (window.title as NSString).appendingPathExtension(AnnotationProject.fileExtension) ?? window.title
        panel.message = String(localized: "A project opens again with every mark still editable.", bundle: .module)
        let project = AnnotationProject(capture: session.base, document: session.document)
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return nil }
        do {
            try await Self.write(project, to: url)
            model.flashSaved()
            VoiceOver.announce(String(localized: "Saved", bundle: .module), from: content.canvas)
            return project.document
        } catch {
            _ = await NSAlert(error: error).beginSheetModal(for: window)
            return nil
        }
    }

    /// Prints the capture as it looks now, the print panel coming down from the window. The edits stay unkept,
    /// as they would were the window left open.
    func printCapture() {
        content.canvas.endEditing()
        Task {
            guard let image = await session.render() else { return NSSound.beep() }
            let title = window?.title ?? ""
            if let printAction = actions.print {
                printAction(image, session.document.scale, title, window)
            } else {
                ImagePrinter.print(image, pixelsPerPoint: session.document.scale, title: title, from: window)
            }
        }
    }

    /// Writes a project off the main actor: its capture is encoded as PNG.
    @concurrent
    private static func write(_ project: AnnotationProject, to url: URL) async throws {
        try project.write(to: url)
    }

    /// Undoes typing while a text mark is edited, else the last change to the marks, as ⌘Z does.
    func undo() {
        content.canvas.undo(nil)
        undoChanged()
    }

    func redo() {
        content.canvas.redo(nil)
        undoChanged()
    }

    // MARK: Picture

    /// Asks for the size to scale the picture to, on a sheet on the window; scaling it, with its marks, is
    /// one undo step.
    private func presentImageSize() {
        guard let window, window.attachedSheet == nil else { return }
        let model = ImageSizeModel(document: content.canvas.documentForImageSize)
        let view = ImageSizeView(
            model: model,
            resize: { [weak self] in self?.finishImageSize(model, resizing: true) },
            cancel: { [weak self] in self?.finishImageSize(model, resizing: false) }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = .preferredContentSize
        let sheet = NSWindow(contentViewController: hosting)
        sheet.title = String(localized: "Image Size", bundle: .module)
        sheet.styleMask = [.titled]
        imageSizeSheet = sheet
        window.beginSheet(sheet)
    }

    private func finishImageSize(_ model: ImageSizeModel, resizing: Bool) {
        guard let sheet = imageSizeSheet else { return }
        imageSizeSheet = nil
        window?.endSheet(sheet)
        if resizing, model.canResize { content.canvas.resizePicture(to: model.sizing.size) }
    }

    /// The file to drag out, with the edits kept in it first (or rendered to the preview file for external projects).
    func fileForDragging() -> URL? {
        content.canvas.endEditing()
        if confirmsSaveOnClose {
            guard let fileURL else { return nil }
            if session.hasUnkeptChanges {
                let document = session.document
                guard let image = AnnotationRenderer.flatten(document, base: session.base),
                      let png = try? ImageExporter.encoded(image, as: .png) else { return nil }
                do {
                    try png.write(to: fileURL, options: .atomic)
                    model.thumbnail = Self.scaledThumbnail(from: image)
                } catch {
                    return nil
                }
            }
            return actions.fileToHandOver(fileURL)
        }
        keepNow()
        // Edits that could not be kept are not in the file: handing it over would drop them.
        guard !session.hasUnkeptChanges, let fileURL else { return nil }
        return actions.fileToHandOver(fileURL)
    }

    private func undoChanged() {
        let manager = content.canvas.activeUndoManager
        model.canUndo = manager.canUndo
        model.canRedo = manager.canRedo
        window?.isDocumentEdited = session.hasUnkeptChanges
    }

    private func updateWindowSubtitle() {
        let output = (session.backdropLayout?.output ?? session.document.canvas.standardized).integral
        window?.subtitle = String(localized: "\(Int(output.width)) × \(Int(output.height)) px", bundle: .module)
    }

    /// Re-renders `DragOutHandle`'s thumbnail off the main actor after edits settle so toolbar and drag previews stay in sync.
    private func scheduleThumbnailRefresh() {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        let document = session.document
        if document.isEmpty {
            if model.thumbnail !== session.picture { model.thumbnail = session.picture }
            return
        }
        let base = session.base
        thumbnailTask = Task { [weak self] in
            guard let thumb = await Self.renderThumbnail(document, base: base) else { return }
            guard !Task.isCancelled, let self, self.session.document == document else { return }
            self.model.thumbnail = thumb
        }
    }

    @concurrent
    private static func renderThumbnail(_ document: AnnotationDocument, base: CGImage) async -> CGImage? {
        guard let image = AnnotationRenderer.flatten(document, base: base) else { return nil }
        return scaledThumbnail(from: image)
    }

    nonisolated private static func scaledThumbnail(from image: CGImage) -> CGImage {
        let maxSide: CGFloat = 128
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let longest = max(width, height)
        guard longest > maxSide, width > 0, height > 0 else { return image }
        let factor = maxSide / longest
        let targetWidth = max(1, Int((width * factor).rounded()))
        let targetHeight = max(1, Int((height * factor).rounded()))
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    /// Returns a file URL reflecting the latest edits for Share / Upload: History captures keep edits first;
    /// external projects render to their cached preview PNG without silently overwriting the `.ohmyshot` file on disk.
    private func prepareFileForHandOver(applyFormat: Bool) async -> URL? {
        if confirmsSaveOnClose {
            guard let fileURL else { return nil }
            if session.hasUnkeptChanges {
                guard let rendered = await render() else { return nil }
                do {
                    try rendered.png.write(to: fileURL, options: .atomic)
                    model.thumbnail = Self.scaledThumbnail(from: rendered.image)
                } catch {
                    return nil
                }
            }
            return applyFormat ? actions.fileToHandOver(fileURL) : fileURL
        }
        guard let file = await exportAndKeep() else { return nil }
        return applyFormat ? actions.fileToHandOver(file) : file
    }

    private func updateZoomLabel() {
        let percent = Int((content.canvas.zoom * session.document.scale * 100).rounded())
        model.zoomLabel = "\(percent)%"
    }

    // MARK: Export

    /// The picture and the marks it was rendered from, which go together through the rendering and the copying: a
    /// mark made meanwhile is kept with a later picture, never as this one's marks.
    private struct RenderedCapture {
        let document: AnnotationDocument
        let image: CGImage
        let png: Data
    }

    private func render() async -> RenderedCapture? {
        let document = session.document
        guard let image = await AnnotationRenderer.render(document, base: session.base),
              let png = try? await ImageExporter.encode(image, as: .png) else { return nil }
        return RenderedCapture(document: document, image: image, png: png)
    }

    /// Renders and keeps the current edits; the capture's file, unchanged when there was nothing to keep, or nil
    /// when they could not be kept.
    private func exportAndKeep() async -> URL? {
        guard session.hasUnkeptChanges else { return fileURL }
        guard let rendered = await render() else { return nil }
        return keep(rendered)
    }

    private func keep(_ rendered: RenderedCapture) -> URL? {
        guard !didClose else { return nil }
        guard session.hasUnkeptChanges else { return fileURL }
        guard let url = actions.keep(rendered.document, rendered.png, rendered.image) else { return nil }
        fileURL = url
        model.thumbnail = Self.scaledThumbnail(from: rendered.image)
        if session.document == rendered.document { session.markKept() }
        return url
    }

    // MARK: File menu

    /// ⇧⌘P, as on a card.
    @objc public func pinToScreen(_ sender: Any?) {
        pin()
    }

    /// ⇧⌘U, as on a card: to the default destination.
    @objc public func uploadCapture(_ sender: Any?) {
        upload()
    }

    @objc public func shareCapture(_ sender: Any?) {
        share()
    }
}

extension AnnotationEditorWindowController: NSMenuItemValidation {
    /// Pin to Screen while the editor offers it, and Upload once a destination is set up, as cards offer it, except while
    /// the capture is uploading.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(pinToScreen(_:)): offersPin
        case #selector(uploadCapture(_:)): actions.upload != nil && !actions.uploadMenu().isHidden && !actions.isUploading()
        default: true
        }
    }
}

@MainActor
@Observable
final class EditorModel {
    var presentation: AnnotationEditorWindowController.Presentation = .editor
    var canUndo = false
    var canRedo = false
    var zoomLabel = "100%"
    var copied = false
    var saved = false
    /// Whether the canvas is locked, for the Picture menu's check.
    var locksCanvas = false
    /// Whether the document has edits that can be reverted back to the original capture.
    var canRevertToOriginal = false
    /// Whether any marks are selected, for the Arrange menu items.
    var hasSelection = false
    /// What Save Options offers for uploading.
    var uploadMenu: UploadMenu = .hidden
    /// The picture the drag-out handle shows.
    var thumbnail: CGImage?
    @ObservationIgnored weak var controller: AnnotationEditorWindowController?
    @ObservationIgnored private var copiedReset: Task<Void, Never>?
    @ObservationIgnored private var savedReset: Task<Void, Never>?

    func flashCopied() {
        copied = true
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    func flashSaved() {
        saved = true
        savedReset?.cancel()
        savedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.saved = false
        }
    }

    func cancelFlashes() {
        copiedReset?.cancel()
        copiedReset = nil
        savedReset?.cancel()
        savedReset = nil
    }
}

struct EditorView: View {
    @Bindable var model: EditorModel
    let content: EditorContentView

    static var copyActionTitle: String { String(localized: "Copy & Close", bundle: .module) }
    static var copyActionHelp: String {
        String(localized: "Copy the edited capture and close this window (Return). Press ⌘C to copy without closing.", bundle: .module)
    }
    static var copyWithoutClosingTitle: String { String(localized: "Copy Without Closing (⌘C)", bundle: .module) }

    var body: some View {
        EditorArea(content: content)
            .background(.background.secondary)
            .toolbar { toolbar }
    }

    /// What the Picture and zoom menus act on, as the canvas's own keys and menu items do.
    private var canvas: AnnotationCanvasView { content.canvas }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.controller?.undo()
            } label: {
                Label { Text("Undo", bundle: .module) } icon: { Image(systemName: "arrow.uturn.backward") }
            }
            .disabled(!model.canUndo)
            .help(Text("Undo (⌘Z)", bundle: .module))
            Button {
                model.controller?.redo()
            } label: {
                Label { Text("Redo", bundle: .module) } icon: { Image(systemName: "arrow.uturn.forward") }
            }
            .disabled(!model.canRedo)
            .help(Text("Redo (⇧⌘Z)", bundle: .module))
        }
        if model.presentation == .editor {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { canvas.showImageSize(nil) } label: { Text("Image Size… (⌥⌘I)", bundle: .module) }
                    Button { model.controller?.showWatermark() } label: { Text("Watermark…", bundle: .module) }
                    Divider()
                    Button { canvas.rotateLeft(nil) } label: { Text("Rotate Left (⌘L)", bundle: .module) }
                    Button { canvas.rotateRight(nil) } label: { Text("Rotate Right (⌘R)", bundle: .module) }
                    Button { canvas.flipHorizontal(nil) } label: { Text("Flip Horizontal", bundle: .module) }
                    Button { canvas.flipVertical(nil) } label: { Text("Flip Vertical", bundle: .module) }
                    Divider()
                    Toggle(isOn: Binding(get: { model.locksCanvas }, set: { _ in canvas.toggleCanvasLock(nil) })) {
                        Text("Lock Canvas", bundle: .module)
                    }
                    Divider()
                    Menu {
                        Button { canvas.bringToFront(nil) } label: { Text("Bring to Front (⇧⌘])", bundle: .module) }
                        Button { canvas.bringForward(nil) } label: { Text("Bring Forward (⌘])", bundle: .module) }
                        Button { canvas.sendBackward(nil) } label: { Text("Send Backward (⌘[)", bundle: .module) }
                        Button { canvas.sendToBack(nil) } label: { Text("Send to Back (⇧⌘[)", bundle: .module) }
                    } label: { Text("Arrange", bundle: .module) }
                    .disabled(!model.hasSelection)
                    Divider()
                    Button { canvas.revertToOriginal(nil) } label: { Text("Revert to Original", bundle: .module) }
                        .disabled(!model.canRevertToOriginal)
                } label: {
                    Label { Text("Picture", bundle: .module) } icon: { Image(systemName: "crop.rotate") }
                }
                .help(Text("Resize, turn, or flip the picture", bundle: .module))
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { canvas.zoomToFit() } label: { Text("Zoom to Fit (⌘0)", bundle: .module) }
                Button { canvas.zoomToActualSize() } label: { Text("Actual Size (⌘1)", bundle: .module) }
                Divider()
                Button { canvas.zoomIn() } label: { Text("Zoom In (⌘+)", bundle: .module) }
                Button { canvas.zoomOut() } label: { Text("Zoom Out (⌘−)", bundle: .module) }
            } label: {
                Text(verbatim: model.zoomLabel).monospacedDigit()
            }
            .fixedSize()
            .help(Text("Zoom", bundle: .module))
            .accessibilityLabel(Text("Zoom, \(model.zoomLabel)", bundle: .module))
        }
        if model.presentation == .editor {
            ToolbarItem(placement: .primaryAction) {
                let size = DragOutHandle.size(of: model.thumbnail)
                DragOutHandle(model: model)
                    .frame(width: size.width, height: size.height)
                    // Room on each side, so the picture clears the group's rounded end and Save's highlight.
                    .padding(.horizontal, 6)
                    .help(Text("Drag the capture into another app", bundle: .module))
                    .accessibilityLabel(Text("Drag Capture", bundle: .module))
            }
            // Save keeps a copy of the picture; the chevron beside it keeps the capture and marks as a project.
            // Two items, not a split button, whose hairline between its halves crowded the chevron.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.controller?.save()
                } label: {
                    Label {
                        model.saved ? Text("Saved", bundle: .module) : Text("Save", bundle: .module)
                    } icon: {
                        // By name, so the toolbar sizes and centers it as its other symbols; a plain button, unlike
                        // a split button's segment, is named by its label, not its picture.
                        Image(systemName: model.saved ? "checkmark" : "square.and.arrow.down")
                    }
                }
                .help(Text("Save a Copy (⌘S)", bundle: .module))
                .accessibilityLabel(model.saved ? Text("Saved", bundle: .module) : Text("Save", bundle: .module))
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if model.controller?.offersSaveAs == true {
                        Button { model.controller?.saveAs() } label: { Text("Save As…", bundle: .module) }
                    }
                    Button {
                        model.controller?.saveProject()
                    } label: {
                        Text("Save a Copy as Project…", bundle: .module)
                    }
                    Divider()
                    Button { model.controller?.copyCapture(thenClose: false) } label: { Text(verbatim: Self.copyWithoutClosingTitle) }
                    Divider()
                    if model.controller?.offersRecognizeText == true {
                        Button { model.controller?.recognizeText() } label: { Text("Recognize Text…", bundle: .module) }
                    }
                    Button { model.controller?.printCapture() } label: { Text("Print… (⌘P)", bundle: .module) }
                    if model.controller?.offersPin == true {
                        Button {
                            model.controller?.pin()
                        } label: {
                            Text("Pin to Screen", bundle: .module)
                        }
                    }
                    Button {
                        model.controller?.share()
                    } label: {
                        Text("Share…", bundle: .module)
                    }
                    // Upload, and Upload To with several destinations, as on a card; nothing before one is set up.
                    switch model.uploadMenu {
                    case .hidden:
                        EmptyView()
                    case .upload:
                        Button {
                            model.controller?.upload()
                        } label: {
                            Text("Upload", bundle: .module)
                        }
                    case .uploadWithChoice(let targets):
                        Button {
                            model.controller?.upload()
                        } label: {
                            Text("Upload to \(model.uploadMenu.defaultTarget?.name ?? "")", bundle: .module)
                        }
                        Menu {
                            ForEach(targets) { target in
                                Button { model.controller?.upload(to: target.id) } label: {
                                    if target.isDefault { Label(target.name, systemImage: "checkmark") } else { Text(verbatim: target.name) }
                                }
                            }
                        } label: {
                            Text("Upload To", bundle: .module)
                        }
                    }
                } label: {
                    Label {
                        Text("Save Options", bundle: .module)
                    } icon: {
                        Image(systemName: "chevron.down")
                    }
                }
                .menuIndicator(.hidden)
                .help(Text("Save Options", bundle: .module))
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.controller?.save()
                } label: {
                    Label {
                        model.saved ? Text("Saved", bundle: .module) : Text("Save", bundle: .module)
                    } icon: {
                        Image(systemName: model.saved ? "checkmark" : "square.and.arrow.down")
                    }
                    .labelStyle(.titleAndIcon)
                }
                .help(Text("Save a Copy (⌘S)", bundle: .module))
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.controller?.copyCapture(thenClose: true)
            } label: {
                Label {
                    model.copied ? Text("Copied", bundle: .module) : Text(verbatim: Self.copyActionTitle)
                } icon: {
                    Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
                }
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .help(Text(verbatim: Self.copyActionHelp))
        }
    }
}

/// Hosts the AppKit working area in the SwiftUI window.
struct EditorArea: NSViewRepresentable {
    let content: EditorContentView

    func makeNSView(context: Context) -> EditorContentView { content }
    func updateNSView(_ nsView: EditorContentView, context: Context) {}
}

/// A small picture of the capture to drag into another app, as Quick Access cards are dragged.
struct DragOutHandle: NSViewRepresentable {
    let model: EditorModel

    /// The whole picture, at its own shape, fitted in 34 × 24 pt: a crop would hide the picture's edges.
    static func size(of picture: CGImage?) -> CGSize {
        let box = CGSize(width: 34, height: 24)
        guard let picture, picture.width > 0, picture.height > 0 else { return box }
        let scale = min(box.width / CGFloat(picture.width), box.height / CGFloat(picture.height))
        return CGSize(width: max(8, (CGFloat(picture.width) * scale).rounded()), height: max(8, (CGFloat(picture.height) * scale).rounded()))
    }

    func makeNSView(context: Context) -> DragOutView {
        let view = DragOutView()
        view.thumbnail = model.thumbnail
        view.prepare = { [weak model] in model?.controller?.fileForDragging() }
        return view
    }

    func updateNSView(_ nsView: DragOutView, context: Context) {
        // The picture turned, flipped, or resized.
        if nsView.thumbnail !== model.thumbnail { nsView.thumbnail = model.thumbnail }
    }
}

final class DragOutView: NSView, NSDraggingSource, CaptureDragSource {
    var thumbnail: CGImage? {
        didSet { layer?.contents = thumbnail }
    }
    var prepare: (() -> URL?)?
    private var mouseDownPoint: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = CGColor(gray: 0, alpha: 0.18)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // The handle sits in the title bar, where a press on a see-through view drags the window instead of reaching it.
    override var mouseDownCanMoveWindow: Bool { false }

    // A press here starts a drag, even when the window is not yet key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        // One try a press: a copy that can't be made is not made again, nor said again, at every move after it.
        mouseDownPoint = nil
        guard let url = prepare?() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = thumbnail.map { NSImage(cgImage: $0, size: bounds.size) } ?? NSImage()
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }
}
