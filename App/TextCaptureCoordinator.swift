import AppKit
import Foundation
import OMSCapture
import OMSCore
import OMSOCR
import OMSUI
import OSLog
import UniformTypeIdentifiers

/// Capture Text: drag over text, or pick a window, and the text goes to the clipboard. The selection stays
/// highlighted while the text is read and fades once it is copied; a card with the text is optional.
/// Unlike a screenshot there is no shutter sound and nothing goes to the history.
///
/// Also opens the OCR panel, for a closer look at an image's text: Option held when the drag ends, a
/// capture's Recognize Text, an image file, the clipboard, or an image dropped on the menu bar icon.
final class TextCaptureCoordinator {
    private let settings: SettingsStore
    private let displays: DisplayTopology
    private let capturer: ScreenCapturer
    private let overlay: OverlayController
    /// A model's first use can take seconds; the highlight stays on meanwhile.
    private let pipeline: VisionPipeline = {
        var options = VisionPipeline.Options.preferred()
        options.timeout = .seconds(30)
        return VisionPipeline(options: options)
    }()
    /// Shared by the panel and Translate Area: a language pair's first translation loads its model.
    private let translator = Translator()
    private let highlight = TextSelectionHighlight()
    private let lens = TranslationLens()
    private let hud = TextResultHUD()
    private var panel: TextRecognitionWindowController?
    /// The last recognition, so the card can switch between kept and joined line breaks.
    private var last: Recognition?

    private struct Recognition {
        let lines: [OCRLine]
        let selection: CGRect
        var joined: Bool
        let copiesToClipboard: Bool
    }

    init(settings: SettingsStore, displays: DisplayTopology, capturer: ScreenCapturer, overlay: OverlayController) {
        self.settings = settings
        self.displays = displays
        self.capturer = capturer
        self.overlay = overlay
        hud.onToggleJoin = { [weak self] in self?.toggleJoin() }
    }

    /// Shows the overlay for text. `joinLines` joins the lines of each paragraph. `done` is told the text copied, or
    /// nil when none was: cancelled, nothing readable, or Option opened the OCR panel instead.
    func captureText(joinLines: Bool, done: ((String?) -> Void)? = nil) {
        guard !overlay.isActive else { done?(nil); return }
        // The model loads while the person selects, which hides its first-use cost.
        let pipeline = pipeline
        Task {
            let probe = LatencyProbe("ocr.prewarm")
            await pipeline.prewarm()
            probe.end()
        }
        overlay.freezesScreen = settings.freezeScreen
        overlay.begin(mode: .area, purpose: .text) { [weak self] outcome in
            // The highlight appears in the same turn the overlay closes, so no frame goes by without
            // the selection.
            guard let self else { done?(nil); return }
            switch outcome {
            case .region(let rect, _, let modifiers, let frozen) where modifiers.contains(.option):
                done?(nil)
                Task { await self.openPanel(region: rect, frozen: frozen) }
            case .window(let target, let modifiers) where modifiers.contains(.option):
                done?(nil)
                Task { await self.openPanel(window: target) }
            case .region(let rect, _, _, let frozen):
                highlight.show(rect)
                Task { await self.recognize(region: rect, frozen: frozen, joinLines: joinLines, done: done) }
            case .window(let target, _):
                highlight.show(target.frame)
                Task { await self.recognize(window: target, joinLines: joinLines, done: done) }
            case .annotated, .color, .record, .scroll, .allInOne, .cancelled:
                done?(nil)
            }
        }
    }

    /// Reads a region of a display, as the overlay does after a drag. Also used by scripted checks.
    /// - Parameters:
    ///   - frozen: the region as the overlay held it still; nil captures it now.
    ///   - copiesToClipboard: false leaves the clipboard alone, so scripted checks never replace what
    ///     the user copied.
    ///   - done: told the text copied, or nil when there was none.
    func recognize(region rect: CGRect, frozen: CapturedFrame? = nil, joinLines: Bool, copiesToClipboard: Bool = true, done: ((String?) -> Void)? = nil) async {
        highlight.show(rect)
        do {
            let frame = try await capture(rect, frozen: frozen)
            await recognize(frame.image, selection: rect, joinLines: joinLines, copiesToClipboard: copiesToClipboard, done: done)
        } catch {
            Log.capture.error("Capture Text failed to capture: \(error.localizedDescription, privacy: .public)")
            highlight.finish(copied: nil, announces: !settings.showTextResult)
            done?(nil)
        }
    }

    private func recognize(window target: WindowTarget, joinLines: Bool, done: ((String?) -> Void)? = nil) async {
        highlight.show(target.frame)
        do {
            let frame = try await capturer.captureWindow(target, shadow: false, layout: displays.layout)
            await recognize(frame.image, selection: target.frame, joinLines: joinLines, copiesToClipboard: true, done: done)
        } catch {
            Log.capture.error("Capture Text failed to capture the window: \(error.localizedDescription, privacy: .public)")
            highlight.finish(copied: nil, announces: !settings.showTextResult)
            done?(nil)
        }
    }

    /// The URL API's `capture-text` with a file: its text goes to the clipboard as a selection's does, the card (when
    /// it is on) by the pointer. Nothing is highlighted: the picture is not on screen.
    /// - Parameter copiesToClipboard: false for a shortcut's action, which hands the text on instead.
    func recognize(fileAt url: URL, joinLines: Bool, copiesToClipboard: Bool = true, done: ((String?) -> Void)? = nil) async {
        guard let loaded = await Self.load(.file(url), fallbackScale: 1) else {
            Log.capture.error("Could not read \(url.lastPathComponent, privacy: .public) to recognize its text")
            highlight.finish(copied: nil, announces: true)
            done?(nil)
            return
        }
        let pointer = NSEvent.mouseLocation
        await recognize(
            loaded.image, selection: CGRect(origin: pointer, size: .zero), joinLines: joinLines, copiesToClipboard: copiesToClipboard, done: done
        )
    }

    /// A picture's text as Capture Text puts it together, or nil when it has none; nothing is copied or shown. For a
    /// shortcut's Recognize Text in Image.
    func text(in image: CGImage, joinLines: Bool) async -> String? {
        do {
            let lines = try await pipeline.recognize(image).lines
            let text = TextAssembler.assemble(lines, options: .init(joinsWrappedLines: joinLines))
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        } catch {
            Log.capture.error("Recognizing a shortcut's picture failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func recognize(_ image: CGImage, selection: CGRect, joinLines: Bool, copiesToClipboard: Bool, done: ((String?) -> Void)? = nil) async {
        let showsCard = settings.showTextResult
        let probe = LatencyProbe("ocr.recognize")
        let result: OCRResult
        do {
            result = try await pipeline.recognize(image)
        } catch {
            Log.capture.error("Capture Text failed to recognize: \(String(describing: error), privacy: .public)")
            highlight.finish(copied: nil, announces: !showsCard)
            if showsCard { hud.show(.empty, near: selection) }
            done?(nil)
            return
        }
        probe.end()

        var recognition = Recognition(lines: result.lines, selection: selection, joined: joinLines, copiesToClipboard: copiesToClipboard)
        let text = assemble(recognition)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            last = nil
            Log.capture.notice("Capture Text found no text")
            highlight.finish(copied: nil, announces: !showsCard)
            if showsCard { hud.show(.empty, near: selection) }
            done?(nil)
            return
        }
        if copiesToClipboard { copy(text) }
        recognition.joined = joinLines
        last = recognition
        highlight.finish(copied: text, announces: !showsCard)
        Log.capture.notice("Capture Text copied \(text.count, privacy: .public) characters in \(result.lines.count, privacy: .public) lines")
        if showsCard {
            hud.show(.copied(text: text, joined: joinLines, canJoin: canJoin(recognition)), near: selection)
        }
        done?(text)
    }

    /// The card's switch: copies the text again with the other line-break choice.
    private func toggleJoin() {
        guard var recognition = last else { return }
        recognition.joined.toggle()
        let text = assemble(recognition)
        if recognition.copiesToClipboard { copy(text) }
        last = recognition
        hud.show(.copied(text: text, joined: recognition.joined, canJoin: true), near: recognition.selection)
    }

    private func assemble(_ recognition: Recognition) -> String {
        TextAssembler.assemble(recognition.lines, options: .init(joinsWrappedLines: recognition.joined))
    }

    /// Whether joining lines would change the text at all.
    private func canJoin(_ recognition: Recognition) -> Bool {
        var other = recognition
        other.joined.toggle()
        return assemble(other) != assemble(recognition)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Translate Area

    /// Translate Area: drag over text, or pick a window, and its translation covers it where it is.
    /// Option held when the drag ends opens the OCR panel, translated, instead.
    func translateArea() {
        guard !overlay.isActive else { return }
        lens.close(animated: false)
        let pipeline = pipeline
        Task { await pipeline.prewarm() }
        overlay.freezesScreen = settings.freezeScreen
        overlay.begin(mode: .area, purpose: .text) { [weak self] outcome in
            switch outcome {
            case .region(let rect, _, let modifiers, let frozen):
                self?.highlight.show(rect)
                Task { await self?.translate(region: rect, frozen: frozen, inPanel: modifiers.contains(.option)) }
            case .window(let target, let modifiers):
                self?.highlight.show(target.frame)
                Task { await self?.translate(window: target, inPanel: modifiers.contains(.option)) }
            case .annotated, .color, .record, .scroll, .allInOne, .cancelled:
                break
            }
        }
    }

    private func translate(region rect: CGRect, frozen: CapturedFrame?, inPanel: Bool) async {
        do {
            let frame = try await capture(rect, frozen: frozen)
            await translate(frame.image, scale: Self.scale(of: frame), over: rect, source: String(localized: "Screen Area"), inPanel: inPanel)
        } catch {
            Log.capture.error("Translate Area failed to capture: \(error.localizedDescription, privacy: .public)")
            highlight.finish(copied: nil, announces: true)
        }
    }

    private func translate(window target: WindowTarget, inPanel: Bool) async {
        do {
            let frame = try await capturer.captureWindow(target, shadow: false, layout: displays.layout)
            await translate(frame.image, scale: Self.scale(of: frame), over: target.frame, source: target.ownerName, inPanel: inPanel)
        } catch {
            Log.capture.error("Translate Area failed to capture the window: \(error.localizedDescription, privacy: .public)")
            highlight.finish(copied: nil, announces: true)
        }
    }

    /// Reads `image`, translates it, and lays the translation over `frame`. When nothing could be
    /// translated (a language still to download, text already in the target, code), the area opens in
    /// the OCR panel, translated, which says why and offers a download or another language: a beep alone
    /// said nothing anyone could act on.
    func translate(_ image: CGImage, scale: CGFloat, over frame: CGRect, source: String, inPanel: Bool) async {
        if inPanel {
            highlight.hide()
            openPanel(image: image, scale: scale, source: source, translating: true)
            return
        }
        let probe = LatencyProbe("ocr.translate-area")
        let choice = settings.translationTarget
        do {
            let lines = try await pipeline.recognize(image).lines
            let units = TranslationUnits.group(lines)
            let outcome = try await translator.translate(units, to: choice.isEmpty ? nil : Locale.Language(identifier: choice))
            guard !outcome.translations.isEmpty else {
                let skipped = Dictionary(grouping: units.compactMap(\.skip), by: { "\($0)" }).map { "\($1.count) \($0)" }.sorted().joined(separator: ", ")
                Log.capture.notice("Translate Area translated nothing into \(outcome.target.minimalIdentifier, privacy: .public): \(units.count, privacy: .public) units, skipped \(skipped, privacy: .public), \(outcome.inTarget.count, privacy: .public) already in it, to download \(outcome.needsDownload.map(\.minimalIdentifier), privacy: .public); opening the panel")
                highlight.hide()
                openPanel(image: image, scale: scale, source: source, translating: true)
                return
            }
            guard let rendering = await TranslationOverlay.render(
                image, lines: lines, units: units, translations: outcome.translations, language: outcome.target, scale: scale
            ) else {
                highlight.finish(copied: nil, announces: true)
                return
            }
            probe.end()
            let (text, translated) = Translator.text(of: units, outcome)
            let sources = ListFormatter.localizedString(byJoining: outcome.sources.map { Translator.name(of: $0) })
            lens.show(
                rendering.image, original: image, scale: scale, over: frame, text: text, translated: translated,
                language: Translator.identifier(of: outcome.target), summary: "\(sources) → \(Translator.name(of: outcome.target))",
                shortened: !rendering.truncated.isEmpty
            )
            lens.onOpenInPanel = { [weak self] in self?.openPanel(image: image, scale: scale, source: source, translating: true) }
            highlight.hide()
            Log.capture.notice("Translate Area translated \(outcome.translations.count, privacy: .public) of \(units.count, privacy: .public) units into \(outcome.target.minimalIdentifier, privacy: .public), \(rendering.truncated.count, privacy: .public) shortened")
        } catch {
            Log.capture.error("Translate Area failed: \(String(describing: error), privacy: .public)")
            highlight.finish(copied: nil, announces: true)
        }
    }

    #if DEBUG
    func revealLensControls() { lens.revealControls() }

    func closeLens() { lens.close(animated: false) }
    #endif

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    // MARK: OCR panel

    /// Opens the OCR panel on `image`, read in full: text, tables, links, and codes. `scale` is the
    /// image's pixels per point; `source` names it under the title.
    func openPanel(image: CGImage, scale: CGFloat, source: String, translating: Bool = false) {
        let controller = panel ?? makePanel()
        panel = controller
        let pipeline = pipeline
        controller.show(image: image, scale: scale, source: source, translating: translating) { image in
            try await pipeline.analyze(image)
        }
    }

    private func makePanel() -> TextRecognitionWindowController {
        let controller = TextRecognitionWindowController(settings: settings, translator: translator)
        controller.onClose = { [weak self] in
            // Released on the next turn so the window is not deallocated inside its own delegate call.
            Task { @MainActor in
                self?.panel = nil
                // Nothing translates until the next panel: the system's models need not stay loaded.
                await self?.translator.releaseSessions()
                MemoryRelief.returnFreedPages()
            }
        }
        return controller
    }

    /// Option held when a Capture Text drag ends. Also used by scripted checks.
    func openPanel(region rect: CGRect, frozen: CapturedFrame? = nil) async {
        do {
            let frame = try await capture(rect, frozen: frozen)
            openPanel(image: frame.image, scale: Self.scale(of: frame), source: String(localized: "Screen Area"))
        } catch {
            Log.capture.error("Capture Text failed to capture: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func openPanel(window target: WindowTarget) async {
        do {
            let frame = try await capturer.captureWindow(target, shadow: false, layout: displays.layout)
            let title = target.title.flatMap { $0.isEmpty ? nil : $0 }
            openPanel(image: frame.image, scale: Self.scale(of: frame), source: title.map { "\(target.ownerName) – \($0)" } ?? target.ownerName)
        } catch {
            Log.capture.error("Capture Text failed to capture the window: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    /// The region as the overlay held it still when the screen was frozen, else captured now, on one
    /// display or across several.
    private func capture(_ rect: CGRect, frozen: CapturedFrame?) async throws -> CapturedFrame {
        if let frozen { return frozen }
        return try await capturer.captureArea(rect, in: displays.layout)
    }

    private static func scale(of frame: CapturedFrame) -> CGFloat {
        frame.frame.width > 0 ? CGFloat(frame.image.width) / frame.frame.width : 1
    }

    /// Opens an image file. `fallbackScale` applies when the file does not record its resolution.
    func openPanel(forFileAt url: URL, fallbackScale: CGFloat = 1, source: String? = nil) async {
        guard let loaded = await Self.load(.file(url), fallbackScale: fallbackScale) else {
            Log.capture.error("Could not read \(url.lastPathComponent, privacy: .public) to recognize its text")
            showFailure(.unreadableFile, source: source ?? url.lastPathComponent)
            return
        }
        openPanel(image: loaded.image, scale: loaded.scale, source: source ?? url.lastPathComponent)
    }

    private func showFailure(_ failure: TextRecognitionWindowController.OpenFailure, source: String) {
        let controller = panel ?? makePanel()
        panel = controller
        controller.show(failure, source: source)
    }

    /// Opens the image on a pasteboard: an image file, or image data named `source`. Returns whether
    /// there was one; a drop without one is refused, as the drop target already checked.
    @discardableResult
    func openPanel(from pasteboard: NSPasteboard, source: String) -> Bool {
        guard let content = PasteboardImage.read(pasteboard) else { return false }
        Task {
            let fallbackScale = displays.layout.displays.map(\.pixelsPerPoint).max() ?? 1
            guard let loaded = await Self.load(content, fallbackScale: fallbackScale) else {
                Log.capture.error("Could not read the image on the pasteboard to recognize its text")
                if case .file(let url) = content {
                    showFailure(.unreadableFile, source: url.lastPathComponent)
                } else {
                    showFailure(.unreadableFile, source: source)
                }
                return
            }
            if case .file(let url) = content {
                openPanel(image: loaded.image, scale: loaded.scale, source: url.lastPathComponent)
            } else {
                openPanel(image: loaded.image, scale: loaded.scale, source: source)
            }
        }
        return true
    }

    /// The clipboard's image. Read only now that it was asked for; the menu looks at its types alone.
    func openClipboardImage() {
        let source = String(localized: "Clipboard")
        if !openPanel(from: .general, source: source) {
            showFailure(.noImageOnClipboard, source: source)
        }
    }

    /// Asks for an image file to open.
    func openImageFile() {
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [.image]
        chooser.message = String(localized: "Choose an image to recognize its text.")
        chooser.prompt = String(localized: "Recognize Text")
        NSApp.activate()
        chooser.begin { [weak self] response in
            guard response == .OK, let url = chooser.url else { return }
            Task { await self?.openPanel(forFileAt: url) }
        }
        chooser.orderFrontRegardless()
    }

    /// Decodes off the main thread: a large photo takes a while.
    @concurrent private nonisolated static func load(_ content: PasteboardImage.Content, fallbackScale: CGFloat) async -> ImageLoader.Loaded? {
        switch content {
        case .file(let url): ImageLoader.load(contentsOf: url, fallbackScale: fallbackScale)
        case .data(let data): ImageLoader.load(data: data, fallbackScale: fallbackScale)
        }
    }

    // MARK: Debug

    #if DEBUG
    /// Shows the card in a given state with sample text, for screenshots of the card itself.
    func previewCard(_ state: String, near selection: CGRect) {
        switch state {
        case "highlight":
            highlight.show(selection)
        case "empty":
            hud.show(.empty, near: selection)
        case "single":
            hud.show(.copied(text: "7", joined: false, canJoin: false), near: selection)
        default:
            let sample = "截图完成后，卡片会出现在屏幕左下角，可以直接拖到其他应用里。\nPress Copy to put the capture on the clipboard.\n历史记录会保留一周，之后自动删除。\nVersion 0.1.0 (build 42)"
            hud.show(.copied(text: sample, joined: false, canJoin: true), near: selection)
        }
    }

    /// Opens the panel with a stand-in for recognition, to show the loading and failure states.
    func previewPanel(image: CGImage, scale: CGFloat, source: String, analyze: @escaping @Sendable (CGImage) async throws -> TextAnalysis) {
        let controller = panel ?? makePanel()
        panel = controller
        controller.show(image: image, scale: scale, source: source, analyze: analyze)
    }

    /// Sets the open panel's pane, line breaks, selected or hovered line, and whether the text was edited.
    func previewPanelState(pane: String?, joinLines: Bool?, selectLine: Int?, hoverLine: Int?, edited: Bool, translate: Bool?, target: String?) {
        panel?.preview(pane: pane, joinLines: joinLines, selectLine: selectLine, hoverLine: hoverLine, edited: edited, translate: translate, target: target)
    }

    /// Shows a failure to open, as a broken file or an empty clipboard would.
    func previewPanelFailure(_ failure: TextRecognitionWindowController.OpenFailure) {
        showFailure(failure, source: "Demo")
    }
    #endif
}
