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
    private let highlight = TextSelectionHighlight()
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

    /// Shows the overlay for text. `joinLines` joins the lines of each paragraph.
    func captureText(joinLines: Bool) {
        guard !overlay.isActive else { return }
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
            switch outcome {
            case .region(let rect, let display, let modifiers) where modifiers.contains(.option):
                Task { await self?.openPanel(region: rect, on: display) }
            case .window(let target, let modifiers) where modifiers.contains(.option):
                Task { await self?.openPanel(window: target) }
            case .region(let rect, let display, _):
                self?.highlight.show(rect)
                Task { await self?.recognize(region: rect, on: display, joinLines: joinLines) }
            case .window(let target, _):
                self?.highlight.show(target.frame)
                Task { await self?.recognize(window: target, joinLines: joinLines) }
            case .cancelled:
                break
            }
        }
    }

    /// Reads a region of a display, as the overlay does after a drag. Also used by scripted checks.
    /// - Parameter copiesToClipboard: false leaves the clipboard alone, so scripted checks never
    ///   replace what the user copied.
    func recognize(region rect: CGRect, on display: DisplayInfo, joinLines: Bool, copiesToClipboard: Bool = true) async {
        highlight.show(rect)
        do {
            let frame = try await capturer.captureRegion(rect, on: display)
            await recognize(frame.image, selection: rect, joinLines: joinLines, copiesToClipboard: copiesToClipboard)
        } catch {
            Log.capture.error("Capture Text failed to capture: \(error.localizedDescription, privacy: .public)")
            highlight.finish(copied: nil, announces: !settings.showTextResult)
        }
    }

    private func recognize(window target: WindowTarget, joinLines: Bool) async {
        highlight.show(target.frame)
        do {
            let frame = try await capturer.captureWindow(target, shadow: false, layout: displays.layout)
            await recognize(frame.image, selection: target.frame, joinLines: joinLines, copiesToClipboard: true)
        } catch {
            Log.capture.error("Capture Text failed to capture the window: \(error.localizedDescription, privacy: .public)")
            highlight.finish(copied: nil, announces: !settings.showTextResult)
        }
    }

    private func recognize(_ image: CGImage, selection: CGRect, joinLines: Bool, copiesToClipboard: Bool) async {
        let showsCard = settings.showTextResult
        let probe = LatencyProbe("ocr.recognize")
        let result: OCRResult
        do {
            result = try await pipeline.recognize(image)
        } catch {
            Log.capture.error("Capture Text failed to recognize: \(String(describing: error), privacy: .public)")
            highlight.finish(copied: nil, announces: !showsCard)
            if showsCard { hud.show(.empty, near: selection) }
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

    // MARK: OCR panel

    /// Opens the OCR panel on `image`, read in full: text, tables, links, and codes. `scale` is the
    /// image's pixels per point; `source` names it under the title.
    func openPanel(image: CGImage, scale: CGFloat, source: String) {
        let controller = panel ?? makePanel()
        panel = controller
        let pipeline = pipeline
        controller.show(image: image, scale: scale, source: source) { image in
            try await pipeline.analyze(image)
        }
    }

    private func makePanel() -> TextRecognitionWindowController {
        let controller = TextRecognitionWindowController()
        controller.onClose = { [weak self] in
            // Released on the next turn so the window is not deallocated inside its own delegate call.
            Task { @MainActor in
                self?.panel = nil
                MemoryRelief.returnFreedPages()
            }
        }
        return controller
    }

    /// Option held when a Capture Text drag ends. Also used by scripted checks.
    func openPanel(region rect: CGRect, on display: DisplayInfo) async {
        do {
            let frame = try await capturer.captureRegion(rect, on: display)
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
    func previewPanelState(pane: String?, joinLines: Bool?, selectLine: Int?, hoverLine: Int?, edited: Bool) {
        panel?.preview(pane: pane, joinLines: joinLines, selectLine: selectLine, hoverLine: hoverLine, edited: edited)
    }

    /// Shows a failure to open, as a broken file or an empty clipboard would.
    func previewPanelFailure(_ failure: TextRecognitionWindowController.OpenFailure) {
        showFailure(failure, source: "Demo")
    }
    #endif
}
