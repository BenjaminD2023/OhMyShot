import AppKit
import OMSCore
import OMSOCR
import OSLog
import SwiftUI

/// The OCR panel: the image on the left with what was read outlined on it, the text on the right,
/// editable and in the line-break style of choice, with tables, links, contacts, codes, and formulas as LaTeX;
/// translated, the image shows the translation in place of its text and the right side the translated text. One
/// window, reused for each new image, created when opened and released when closed.
public final class TextRecognitionWindowController: NSWindowController, NSWindowDelegate {
    /// Why an image never reached the panel. The panel says so instead of a bare beep.
    public enum OpenFailure: Sendable {
        /// The file is not an image that can be decoded.
        case unreadableFile
        /// The clipboard holds no image.
        case noImageOnClipboard
    }

    /// How the formulas, tables, and charts in an image get into its text while the formula pack or the VLM pack is
    /// installed (Docs/ocr.md › Formulas among text, › The VLM pack): found and read in the text reader, starting with
    /// Vision's reading, then put into the lines read; a table or chart read takes the place of Vision's table there.
    public nonisolated struct Elements: Sendable {
        /// How many formulas, and how many tables and charts, there are to read.
        public struct Counts: Sendable, Equatable {
            public var formulas: Int
            public var tables: Int

            public init(formulas: Int, tables: Int) {
                self.formulas = formulas
                self.tables = tables
            }
        }

        /// What was read.
        public struct Found: Sendable {
            public var formulas: [FormulaMerge.Formula]
            public var tables: [TableMerge.Table]

            public init(formulas: [FormulaMerge.Formula] = [], tables: [TableMerge.Table] = []) {
                self.formulas = formulas
                self.tables = tables
            }
        }

        /// The formulas in the image, read as LaTeX, and the tables and charts, as rows; `found` is told how many there
        /// are, before they are read.
        public var read: @Sendable (CGImage, _ found: @escaping @Sendable (Counts) -> Void) async -> Found
        /// The lines with the formulas in them (the tables go in after, by `TableMerge`).
        public var merge: @Sendable ([OCRLine], [FormulaMerge.Formula], CGImage) async -> [OCRLine]

        public init(
            read: @escaping @Sendable (CGImage, _ found: @escaping @Sendable (Counts) -> Void) async -> Found,
            merge: @escaping @Sendable ([OCRLine], [FormulaMerge.Formula], CGImage) async -> [OCRLine]
        ) {
            self.read = read
            self.merge = merge
        }
    }

    /// The cloud model the person set up, and how a picture is read with it (L4, Docs/ocr.md › Cloud models). The
    /// toolbar's Read with sends the picture shown; with "every picture" on in Settings, each picture is read with it
    /// as it opens. With no model set up, the panel never mentions it.
    public struct Cloud {
        public let store: CloudModelStore
        /// Reads a picture with a model, telling how many characters have come so far.
        public let read: @Sendable (CGImage, CloudModel, _ progress: @escaping @Sendable (Int) -> Void) async throws -> CloudReading

        public init(
            store: CloudModelStore,
            read: @escaping @Sendable (CGImage, CloudModel, _ progress: @escaping @Sendable (Int) -> Void) async throws -> CloudReading
        ) {
            self.store = store
            self.read = read
        }
    }

    public var onClose: (() -> Void)?

    private let model: TextRecognitionModel
    private var windowLease: ActiveResources.Lease?

    /// `translator` is shared, so a language pair's model, slow to load, stays ready from image to image.
    public init(settings: SettingsStore, translator: Translator, cloud: Cloud? = nil) {
        model = TextRecognitionModel(settings: settings, translator: translator, cloud: cloud)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = String(localized: "Recognized Text", bundle: .module)
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = NSHostingController(rootView: TextRecognitionView(model: model))
        content.sceneBridgingOptions = [.toolbars]
        content.sizingOptions = [.minSize]
        window.contentViewController = content
        window.setContentSize(CGSize(width: 1040, height: 660))
        let restored = window.setFrameUsingName("TextRecognition")
        window.setFrameAutosaveName("TextRecognition")
        if !restored { window.center() }
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `image` and reads it with `analyze`. `scale` is pixels per point (2 for a Retina capture),
    /// so the image is never drawn larger than it appeared; `source` names it under the title.
    /// `translating` turns the translation on for it (Translate Area's Open in Panel). With `elements`, the formulas in
    /// the image come into its text as LaTeX once they are read, and its tables and charts as rows.
    public func show(
        image: CGImage, scale: CGFloat, source: String, translating: Bool = false, elements: Elements? = nil,
        analyze: @escaping @Sendable (CGImage) async throws -> TextAnalysis
    ) {
        model.load(image: image, scale: scale, analyze: analyze, elements: elements)
        if translating { model.translates = true }
        present(source: source)
    }

    /// Whether the translation is shown; it stays on from image to image until turned off.
    public var translates: Bool {
        get { model.translates }
        set { model.translates = newValue }
    }

    /// Shows why there is nothing to read.
    public func show(_ failure: OpenFailure, source: String) {
        model.fail(failure)
        present(source: source)
    }

    private func present(source: String) {
        window?.subtitle = source
        if windowLease == nil {
            windowLease = ActiveResources.shared.acquire(.window)
        }
        showWindow(nil)
        AppActivation.bringForward(window)
    }

    public func windowWillClose(_ notification: Notification) {
        model.unload()
        windowLease?.end()
        windowLease = nil
        onClose?()
    }

    #if DEBUG
    /// For scripted screenshots: `pane` text or table, joined lines, a selected or hovered line, an
    /// edited text.
    /// `cloud`: on or off (the toolbar's Read with), retry.
    public func preview(
        pane: String?, joinLines: Bool?, selectLine: Int?, hoverLine: Int?, edited: Bool, translate: Bool? = nil, target: String? = nil,
        cloud: String? = nil
    ) {
        switch cloud {
        case "on"?: model.readsInCloud = true
        case "off"?: model.readsInCloud = false
        case "retry"?: model.retryCloudReading()
        default: break
        }
        if let target { model.translationChoice = target == "auto" ? "" : target }
        if let translate { model.translates = translate }
        if let pane { model.pane = pane == "table" ? .table : .text }
        if let joinLines { model.joinLines = joinLines }
        if let selectLine { model.selectLine(selectLine) }
        if let hoverLine { model.hoveredLine = hoverLine }
        if edited { model.textEdited(model.text) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, let window else { return }
            let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            Log.app.notice("debug.panel-focus responder=\(responder, privacy: .public) key=\(window.isKeyWindow, privacy: .public) appActive=\(NSApp.isActive, privacy: .public) editorActive=\(self.model.editorIsActive, privacy: .public)")
        }
    }
    #endif
}
