import AppKit
import Foundation
import OMSCapture
import OMSCore
import OMSOCR
import OMSUI
import OSLog

/// Capture Text: drag over text, or pick a window, and the text goes to the clipboard. The selection stays
/// highlighted while the text is read and fades once it is copied; a card with the text is optional.
/// Unlike a screenshot there is no shutter sound and nothing goes to the history.
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
            case .region(let rect, let display):
                self?.highlight.show(rect)
                Task { await self?.recognize(region: rect, on: display, joinLines: joinLines) }
            case .window(let target):
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
    #endif
}
