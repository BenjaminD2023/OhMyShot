import AppKit
import ImageIO
import Observation
import OMSCore
import SwiftUI
import UniformTypeIdentifiers

/// The annotation editor: a standard window holding the canvas, its tool rail and style capsule, and a
/// toolbar with Undo and Redo, zoom, a handle to drag the capture out, Save, and Copy.
///
/// Edits are kept in the capture itself (its file shows the marks, and the marks stay editable) when the
/// window closes and whenever the capture leaves it: copied, saved, or dragged out.
public final class AnnotationEditorWindowController: NSWindowController, NSWindowDelegate {
    public struct Actions {
        /// Keeps the marked-up capture in place of the capture: the PNG, the image, and the document that
        /// recreates it. Returns the file that now holds the capture.
        public var keep: (_ document: AnnotationDocument, _ png: Data, _ image: CGImage) -> URL?
        /// Saves a copy of the capture's file to the export location; returns where it went.
        public var save: (_ file: URL) -> URL?

        public init(keep: @escaping (AnnotationDocument, Data, CGImage) -> URL?, save: @escaping (URL) -> URL?) {
            self.keep = keep
            self.save = save
        }
    }

    public var onClose: (() -> Void)?
    public let session: AnnotationSession

    private let model: EditorModel
    private let content: EditorContentView
    private let actions: Actions
    private var fileURL: URL
    private var windowLease: ActiveResources.Lease?

    /// - Parameters:
    ///   - image: the capture as it was taken.
    ///   - scale: pixels per point of the screen it came from.
    ///   - document: marks made on it before.
    ///   - fileURL: the capture's file, which holds the marked-up picture once edits are kept.
    public init(image: CGImage, scale: CGFloat, document: AnnotationDocument?, title: String, fileURL: URL, actions: Actions) {
        session = AnnotationSession(image: image, scale: scale, document: document)
        content = EditorContentView(session: session)
        model = EditorModel()
        self.actions = actions
        self.fileURL = fileURL
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.preferredSize(for: image, scale: scale)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = title
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 720, height: 560)
        super.init(window: window)
        model.controller = self
        model.thumbnail = image
        let hosting = NSHostingController(rootView: EditorView(model: model, content: content))
        hosting.sceneBridgingOptions = [.toolbars]
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(Self.preferredSize(for: image, scale: scale))
        window.center()
        window.delegate = self

        content.canvas.onCopy = { [weak self] in self?.copy() }
        content.canvas.onSave = { [weak self] in self?.save() }
        content.onViewportChange = { [weak self] in self?.updateZoomLabel() }
        session.observe { [weak self] event in
            if event == .history || event == .document { self?.undoChanged() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The window shows the capture at the size it had on screen, with room for the rail and the capsule,
    /// within most of the screen.
    private static func preferredSize(for image: CGImage, scale: CGFloat) -> CGSize {
        let picture = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let width = min(max(picture.width + 72 + 28, 760), visible.width * 0.9)
        let height = min(max(picture.height + 24 + 62 + 52, 560), visible.height * 0.9)
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    public func show() {
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(content.canvas)
        updateZoomLabel()
    }

    #if DEBUG
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
            return AnnotationSession.tool(for: item).rawValue
        }.joined(separator: ",")
        return "marks=[\(kinds)] selected=\(session.selection.count) tool=\(session.tool.rawValue) canvas=\(NSStringFromRect(session.document.canvas)) undo=\(session.undoManager.canUndo ? session.undoManager.undoActionName : "-") redo=\(session.undoManager.canRedo ? session.undoManager.redoActionName : "-") unkept=\(session.hasUnkeptChanges) editing=\(content.canvas.isEditingText)"
    }
    #endif

    // MARK: Window

    public func windowWillClose(_ notification: Notification) {
        content.canvas.endEditing()
        content.releaseColorPanel()
        if session.hasUnkeptChanges {
            // Kept after the window has gone; this task holds the controller until then.
            Task {
                _ = await self.exportAndKeep()
                self.finishClosing()
            }
        } else {
            finishClosing()
        }
    }

    private func finishClosing() {
        windowLease?.end()
        windowLease = nil
        onClose?()
    }

    /// Keeps the edits at once, on this thread: for quitting with the editor open.
    public func keepNow() {
        content.canvas.endEditing()
        guard session.hasUnkeptChanges, let image = AnnotationRenderer.flatten(session.document, base: session.base), let png = Self.png(image) else { return }
        if let url = actions.keep(session.document, png, image) { fileURL = url }
        session.markKept()
    }

    // MARK: Actions

    func copy() {
        content.canvas.endEditing()
        Task {
            guard let (image, png) = await render() else {
                NSSound.beep()
                return
            }
            PasteboardWriter.write(png: png, image: image)
            model.flashCopied()
            NSAccessibility.post(element: content.canvas, notification: .announcementRequested, userInfo: [
                .announcement: String(localized: "Copied", bundle: .module), .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
            keep(png: png, image: image)
        }
    }

    func save() {
        content.canvas.endEditing()
        Task {
            guard let file = await exportAndKeep(), actions.save(file) != nil else {
                NSSound.beep()
                return
            }
            model.flashSaved()
        }
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

    func zoomToFit() { content.canvas.zoomToFit() }
    func zoomToActualSize() { content.canvas.zoomToActualSize() }
    func zoomIn() { content.canvas.zoomIn() }
    func zoomOut() { content.canvas.zoomOut() }

    /// The file to drag out, with the edits kept in it first.
    func fileForDragging() -> URL? {
        content.canvas.endEditing()
        keepNow()
        return fileURL
    }

    private func undoChanged() {
        model.canUndo = session.undoManager.canUndo
        model.canRedo = session.undoManager.canRedo
    }

    private func updateZoomLabel() {
        let percent = Int((content.canvas.zoom * session.document.scale * 100).rounded())
        model.zoomLabel = "\(percent)%"
    }

    // MARK: Export

    private func render() async -> (CGImage, Data)? {
        guard let image = await session.render(), let png = try? await ImageExporter.encode(image, as: .png) else { return nil }
        return (image, png)
    }

    /// Renders and keeps the current edits; the capture's file, unchanged when there was nothing to keep.
    private func exportAndKeep() async -> URL? {
        guard session.hasUnkeptChanges else { return fileURL }
        guard let (image, png) = await render() else { return nil }
        keep(png: png, image: image)
        return fileURL
    }

    private func keep(png: Data, image: CGImage) {
        guard session.hasUnkeptChanges else { return }
        let document = session.document
        if let url = actions.keep(document, png, image) { fileURL = url }
        if session.document == document { session.markKept() }
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

@MainActor
@Observable
final class EditorModel {
    var canUndo = false
    var canRedo = false
    var zoomLabel = "100%"
    var copied = false
    var saved = false
    @ObservationIgnored weak var controller: AnnotationEditorWindowController?
    @ObservationIgnored var thumbnail: CGImage?
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
}

struct EditorView: View {
    @Bindable var model: EditorModel
    let content: EditorContentView

    var body: some View {
        EditorArea(content: content)
            .background(.background.secondary)
            .toolbar { toolbar }
    }

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
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { model.controller?.zoomToFit() } label: { Text("Zoom to Fit (⌘0)", bundle: .module) }
                Button { model.controller?.zoomToActualSize() } label: { Text("Actual Size", bundle: .module) }
                Divider()
                Button { model.controller?.zoomIn() } label: { Text("Zoom In (⌘+)", bundle: .module) }
                Button { model.controller?.zoomOut() } label: { Text("Zoom Out (⌘−)", bundle: .module) }
            } label: {
                Text(verbatim: model.zoomLabel).monospacedDigit()
            }
            .fixedSize()
            .help(Text("Zoom", bundle: .module))
            .accessibilityLabel(Text("Zoom, \(model.zoomLabel)", bundle: .module))
        }
        ToolbarItem(placement: .primaryAction) {
            DragOutHandle(model: model)
                .frame(width: 34, height: 24)
                .help(Text("Drag the capture into another app", bundle: .module))
                .accessibilityLabel(Text("Drag Capture", bundle: .module))
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.controller?.save()
            } label: {
                Label {
                    model.saved ? Text("Saved", bundle: .module) : Text("Save", bundle: .module)
                } icon: {
                    Image(systemName: model.saved ? "checkmark" : "square.and.arrow.down")
                }
            }
            .help(Text("Save a copy to the export folder (⌘S)", bundle: .module))
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.controller?.copy()
            } label: {
                Label {
                    model.copied ? Text("Copied", bundle: .module) : Text("Copy", bundle: .module)
                } icon: {
                    Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
                }
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .help(Text("Copy the capture with its marks (⌘C)", bundle: .module))
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

    func makeNSView(context: Context) -> DragOutView {
        let view = DragOutView()
        view.thumbnail = model.thumbnail
        view.prepare = { [weak model] in model?.controller?.fileForDragging() }
        return view
    }

    func updateNSView(_ nsView: DragOutView, context: Context) {}
}

final class DragOutView: NSView, NSDraggingSource {
    var thumbnail: CGImage? {
        didSet { layer?.contents = thumbnail }
    }
    var prepare: (() -> URL?)?
    private var mouseDownPoint: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
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

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 3, let url = prepare?() else { return }
        mouseDownPoint = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = thumbnail.map { NSImage(cgImage: $0, size: bounds.size) } ?? NSImage()
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }
}
