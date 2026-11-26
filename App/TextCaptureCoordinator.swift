import AppKit
import CoreText
import Foundation
import Observation
import OMSCapture
import OMSCore
import OMSOCR
import OMSUI
import OSLog
import UniformTypeIdentifiers
import Vision

/// Capture Text: drag over text, or pick a window, and the text goes to the clipboard, any formula in it as LaTeX while
/// the formula pack is installed. The selection stays highlighted while the text is read and fades once it is copied; a
/// card with the text is optional. Unlike a screenshot there is no shutter sound and nothing goes to the history.
///
/// Also opens the OCR panel, for a closer look at an image's text: Option held when the drag ends, a
/// capture's Recognize Text, an image file, the clipboard, or an image dropped on the menu bar icon. And Capture
/// Formula: the same, for a formula, whose LaTeX goes to the clipboard.
final class TextCaptureCoordinator {
    private let settings: SettingsStore
    private let displays: DisplayTopology
    private let capturer: ScreenCapturer
    private let overlay: OverlayController
    /// A process's first reading after its compiled models are gone (a cache cleaner, a macOS update, a fresh install)
    /// compiles them on the Neural Engine first: about 18 s for each of the two passes, one after the other, so about
    /// 37 s in all, and longer while other apps compile. The highlight stays on meanwhile, and Escape stops the reading
    /// (Docs/ocr.md › Escape stops a reading); at 30 s nearly every such reading failed and copied nothing.
    private var pipeline: VisionPipeline {
        var options = VisionPipeline.Options.configured(settings.ocrLanguages)
        options.timeout = .seconds(60)
        options.overallTimeout = .seconds(60)
        options.trace = { step in Log.performance.notice("ocr.pipeline \(step, privacy: .public)") }
        return VisionPipeline(options: options)
    }
    /// Shared by the panel and Translate Area: a language pair's first translation loads its model.
    private let translator = Translator()
    private let highlight = TextSelectionHighlight()
    private let lens = TranslationLens()
    /// Keep the compatibility choice after the current isolated recognizer stops answering.
    /// This is process state, not a saved preference; a relaunch tries the current recognizer again.
    private var usesCompatibilityTextReader = false
    /// Keep models resident across idle periods. A separate worker keeps optional layout work out
    /// of the text reader's queue; neither runs or polls while idle.
    private let primaryTextReader = Bundle.main.url(forAuxiliaryExecutable: "OhMyShot Text Reader")
        .map { TextReaderWorker(helper: $0, idleTimeout: nil) }
    private let recoveryTextReader = Bundle.main.url(forAuxiliaryExecutable: "OhMyShot Text Reader")
        .map { TextReaderWorker(helper: $0, idleTimeout: nil) }
    private let elementTextReader = Bundle.main.url(forAuxiliaryExecutable: "OhMyShot Text Reader")
        .map { TextReaderWorker(helper: $0, idleTimeout: nil) }
    private var readerPreparation: Task<Bool, Never>?
    private var recoveryPreparation: Task<Void, Never>?
    private var recoveryLastUsed: ContinuousClock.Instant?
    private var elementPreparation: Task<Void, Never>?
    private let selection = TextSelectionSession()
    private var hud: TextResultHUD { selection.resultCard }
    private var panel: TextRecognitionWindowController?
    /// The last recognition, so the card can switch between kept and joined line breaks.
    private var last: Recognition?
    /// The text reader and the model packs installed for it, asked as each reading starts (as each panel opens): the
    /// pack the OCR panel reads with beside Vision (L2 beside L1, Docs/ocr.md › L2 beside L1), the formula pack (Capture
    /// Formula, and the formulas among text; Docs/ocr.md › The formula pack), and the VLM pack (the tables and charts
    /// among text; Docs/ocr.md › Formulas among text, › The VLM pack). Nil while the reader isn't in the app.
    var readers: (() -> TextReaderPacks.Installed?)?
    /// The text reader with the packs that read the formulas, tables, and charts among text, the formula pack and the
    /// VLM pack, whichever are installed; nil while neither is.
    private var elementReader: TextReaderPacks.Installed? {
        guard let reader = readers?(), reader.formula != nil || reader.vlm != nil else { return nil }
        return reader
    }
    /// How long Capture Text lets the VLM read tables and charts before it copies Vision's reading of what is left: a
    /// table takes 0.2–1.2 s once the model's files are in memory, the first after a restart about 7 s
    /// (Docs/ocr.md › The VLM pack).
    nonisolated static let tableWait: Double = 10
    /// The same in the OCR panel, which shows Vision's reading meanwhile.
    nonisolated static let panelTableWait: Double = 60
    /// The cloud model the panel's Read with sends a picture to, and how; asked as each panel window opens.
    var cloud: (() -> TextRecognitionWindowController.Cloud?)?
    /// The cloud model Capture Text reads with while Settings says so, and how (joining lines or not); nil otherwise.
    /// Asked at each capture.
    var captureTextCloud: (() -> (model: CloudModel, read: @Sendable (CGImage, _ joinsLines: Bool) async throws -> CloudReading)?)?
    /// How long Capture Text waits for the cloud model before it copies this Mac's reading instead.
    nonisolated static let cloudWait: Duration = .seconds(60)
    /// Counts Capture Text's readings: one still waiting for the cloud model when another starts is let go, and leaves
    /// the clipboard and the highlight to the newer one.
    private var readings = 0
    /// The cloud model's reading Capture Text waits for, cancelled when another Capture Text starts.
    private var waitingForCloud: Task<CloudReading, any Error>?
    /// Text read but left off the clipboard, which changed while the cloud model read it; the card's Copy puts it there.
    private var uncopied: (text: String, note: String?, selection: CGRect)?
    private let resultSetting: Task<Void, Never>
    /// Cached translation target languages for `TranslationLens`'s quick language switcher.
    private var cachedTranslationTargets: [Locale.Language] = []
    /// Active in-place re-translation triggered from `TranslationLens`'s quick language switcher.
    private var lensRetranslation: Task<Void, Never>?
    /// Monotonic counter so stale `TranslationLens` re-translations never replace a newer lens.
    private var lensGeneration: UInt = 0

    /// Optional hook wired by CompositionRoot to pin a rendered translated image from TranslationLens or the panel.
    var onPinImage: ((CGImage, CGFloat) -> Void)? {
        didSet {
            lens.onPinImage = onPinImage
            TextRecognitionWindowController.onPinImage = onPinImage
        }
    }

    /// The image read by Capture Text or Capture Formula, with any already-computed OCR / Cloud reading so
    /// Open in Panel reuses them without redundant re-OCR or duplicate cloud requests. Owned only by the
    /// active result card's `onOpenInPanel` closure so it is released as soon as the card closes or is disabled.
    private struct CapturedSnapshot {
        let image: CGImage
        let scale: CGFloat
        let source: String
        let place: AppTextPlace?
        var cachedLines: [OCRLine]?
        var cachedCloud: CloudReading?
        var secondReadingDone: Bool = false
    }

    private struct Recognition {
        let lines: [OCRLine]
        let selection: CGRect
        var joined: Bool
        let copiesToClipboard: Bool
        /// The card's line under the text: why this Mac's reading was copied instead of the cloud model's.
        var note: String?
    }

    init(settings: SettingsStore, displays: DisplayTopology, capturer: ScreenCapturer, overlay: OverlayController) {
        self.settings = settings
        self.displays = displays
        self.capturer = capturer
        self.overlay = overlay
        resultSetting = Task { [weak hud = selection.resultCard] in
            for await shows in Observations({ settings.showTextResult }) where !shows {
                hud?.setPanelAction(nil, showsResult: false)
            }
        }
        hud.onToggleJoin = { [weak self] in self?.toggleJoin() }
        hud.onCopy = { [weak self] in self?.copyUncopied() }
        highlight.onCancel = { [weak self] in self?.cancelReading() }
    }

    deinit { resultSetting.cancel() }

    /// Escape while the highlight showed (it has gone, without a sound): the reading stops, and nothing is copied or
    /// shown. A wait on Vision ends at once, a run of the text reader is ended, and the cloud model is no longer waited
    /// for; each reading's `done` is told nil, as for any reading cancelled.
    private func cancelReading() {
        guard selection.cancel() else { return }
        waitingForCloud?.cancel()
        waitingForCloud = nil
        Log.capture.notice("Escape stopped the reading behind the highlight")
    }

    /// Test model readiness before a shortcut selection. A failed startup request is killed with its
    /// process, so it cannot hold the app's native recognition slot or block the OCR panel.
    func prepareCaptureText(refreshIdleRecovery: Bool = true) {
        guard let primaryTextReader, let recoveryTextReader else { return }
        // Native contexts can expire while their process is idle. Check only on capture intent,
        // while the user selects text; a recently used reader needs no extra job or idle heartbeat.
        if (refreshIdleRecovery || readerPreparation == nil), recoveryPreparation == nil,
           recoveryLastUsed.map({ ContinuousClock.now - $0 >= .seconds(60) }) ?? true {
            recoveryPreparation = Task { [weak self] in
                let probe = LatencyProbe("ocr.prepare.recovery")
                defer {
                    probe.end()
                    self?.recoveryPreparation = nil
                }
                guard let image = Self.preparationImage() else { return }
                // The same bounded recovery as a real selection replaces an expired native context
                // while the user selects, without repeating a failed primary probe.
                if (try? await Self.isolatedTextLines(in: image, worker: recoveryTextReader, timeout: .seconds(30))) != nil {
                    self?.recoveryLastUsed = .now
                }
            }
        }
        guard readerPreparation == nil else { return }
        readerPreparation = Task { [weak self] in
            let probe = LatencyProbe("ocr.prepare")
            defer { probe.end() }
            guard let image = Self.preparationImage(), let file = Self.readerPicture(image, in: "Formula Readings") else { return false }
            defer { try? FileManager.default.removeItem(at: file) }
            let current = try? await primaryTextReader.visionLines(ofPictureAt: file, compatibility: false, timeout: .seconds(3))
            guard !Task.isCancelled else { return false }
            if current != nil { return false }
            // An early capture must not spend another three seconds probing the same backend;
            // its recovery job can queue behind the independent preparation within its deadline.
            self?.usesCompatibilityTextReader = true
            return true
        }
        if let reader = elementReader, let elementTextReader {
            elementPreparation = Task {
                guard let image = Self.preparationImage(), let file = Self.readerPicture(image, in: "Formula Readings") else { return }
                defer { try? FileManager.default.removeItem(at: file) }
                _ = try? await elementTextReader.elements(
                    ofPictureAt: file, formulas: reader.formula, vlm: reader.vlm, seconds: Self.tableWait, timeout: .seconds(2)
                )
            }
        }
    }

    func stop() {
        selection.cancel()
        waitingForCloud?.cancel()
        readerPreparation?.cancel()
        recoveryPreparation?.cancel()
        elementPreparation?.cancel()
        let workers = [primaryTextReader, recoveryTextReader, elementTextReader].compactMap { $0 }
        Task { for worker in workers { await worker.stop() } }
    }

    /// A few real glyphs reach the recognizer, unlike a blank warmup. Nothing on screen is captured.
    private static func preparationImage() -> CGImage? {
        guard let context = CGContext(data: nil, width: 320, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 80))
        let font = CTFontCreateUIFontForLanguage(.system, 28, "zh-Hans" as CFString) ?? CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let text = NSAttributedString(string: "文字 Text", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: 16, y: 24)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return context.makeImage()
    }
    var onTextRecognized: (() -> Void)?

    /// Where Quick Access's cards stand, for the result card to keep clear of in the bottom-left corner.
    var cardsInTheWay: () -> CGRect? {
        get { hud.cardsInTheWay }
        set { hud.cardsInTheWay = newValue }
    }

    /// Shows a result card by `selection`. The Close text card choice applies to a card the user asked for (Show the
    /// copied text); one shown only to say something (a note, or text left off the clipboard) keeps its own time.
    private func presentCard(_ state: TextResultHUD.State, near selection: CGRect, note: String? = nil, openInPanel: (() -> Void)? = nil) {
        hud.setPanelAction(openInPanel, showsResult: settings.showTextResult)
        hud.show(state, near: selection, position: settings.textResultPosition,
                 closeAfter: settings.showTextResult ? settings.textResultCloseAfter : nil, note: note,
                 canOpenInPanel: openInPanel != nil)
    }

    private func panelAction(for snapshot: CapturedSnapshot) -> () -> Void {
        return { [weak self] in
            guard let self else { return }
            TextRecognitionWindowController.seedNextCloudReading(snapshot.cachedCloud)
            self.openPanel(
                image: snapshot.image, scale: snapshot.scale, source: snapshot.source,
                place: snapshot.place, cachedLines: snapshot.cachedLines,
                secondReadingDone: snapshot.secondReadingDone
            )
        }
    }

    private func openInPanel(for snapshot: CapturedSnapshot) -> (() -> Void)? {
        settings.showTextResult ? panelAction(for: snapshot) : nil
    }

    /// Shows the overlay for text. `joinLines` joins the lines of each paragraph. `done` is told the text copied, or
    /// nil when none was: cancelled, nothing readable, or Option opened the OCR panel instead. `allowsCloud` false
    /// keeps the reading on this Mac, for the URL API and Shortcuts.
    func captureText(joinLines: Bool, allowsCloud: Bool = true, done: ((String?) -> Void)? = nil) {
        guard !overlay.isActive else { done?(nil); return }
        selection.cancel()
        waitingForCloud?.cancel()
        highlight.hide()
        prepareCaptureText()
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
                Task { await self.openPanel(windows: [target]) }
            case .windows(let targets, let modifiers) where modifiers.contains(.option):
                done?(nil)
                Task { await self.openPanel(windows: targets) }
            case .region(let rect, _, _, let frozen):
                highlight.show(rect)
                Task { await self.recognize(region: rect, frozen: frozen, joinLines: joinLines, allowsCloud: allowsCloud, done: done) }
            case .window(let target, _):
                highlight.show(target.frame)
                Task { await self.recognize(windows: [target], joinLines: joinLines, allowsCloud: allowsCloud, done: done) }
            case .windows(let targets, _):
                if let union = targets.combinedFrame {
                    highlight.show(union)
                    Task { await self.recognize(windows: targets, joinLines: joinLines, allowsCloud: allowsCloud, done: done) }
                } else {
                    done?(nil)
                }
            case .annotated, .color, .record, .scroll, .allInOne, .allInOneWindows, .cancelled:
                done?(nil)
            }
        }
    }

    /// Reads a region of a display, as the overlay does after a drag. Also used by scripted checks.
    /// - Parameters:
    ///   - frozen: the region as the overlay held it still; nil captures it now.
    ///   - copiesToClipboard: false leaves the clipboard alone, so scripted checks never replace what
    ///     the user copied.
    ///   - allowsCloud: true for a person's own drag: it reads with the cloud model while Settings says Capture Text
    ///     does. The URL API never sends a capture to one.
    ///   - done: told the text copied, or nil when there was none (also when Escape stopped the reading).
    func recognize(
        region rect: CGRect, frozen: CapturedFrame? = nil, joinLines: Bool, copiesToClipboard: Bool = true, allowsCloud: Bool = false,
        done: ((String?) -> Void)? = nil
    ) async {
        guard !Task.isCancelled else { done?(nil); return }
        await selection.run { [self] in
            guard !Task.isCancelled else { done?(nil); return }
            highlight.show(rect)
            do {
                let frame = try await capture(rect, frozen: frozen)
                try Task.checkCancellation()
                await recognize(
                    frame.image, selection: rect, place: Self.place(of: frame), joinLines: joinLines, copiesToClipboard: copiesToClipboard,
                    allowsCloud: allowsCloud, done: done
                )
            } catch {
                guard !Task.isCancelled else { done?(nil); return }
                Log.capture.error("Capture Text failed to capture: \(error.localizedDescription, privacy: .public)")
                highlight.finish(copied: nil, announces: !settings.showTextResult)
                done?(nil)
            }
        }
    }

    /// Reads the windows picked, each captured on its own: with several, nothing between or around them is read, or
    /// sent to a cloud model.
    private func recognize(windows targets: [WindowTarget], joinLines: Bool, allowsCloud: Bool, done: ((String?) -> Void)? = nil) async {
        guard !Task.isCancelled, let area = targets.combinedFrame else { done?(nil); return }
        await selection.run { [self] in
            guard !Task.isCancelled else { done?(nil); return }
            highlight.show(area)
            do {
                let frame = try await capturer.captureWindows(targets, shadow: false, layout: displays.layout)
                try Task.checkCancellation()
                await recognize(
                    frame.image, selection: area, place: Self.place(of: frame, windows: targets), joinLines: joinLines, copiesToClipboard: true,
                    allowsCloud: allowsCloud, done: done
                )
            } catch {
                guard !Task.isCancelled else { done?(nil); return }
                Log.capture.error("Capture Text failed to capture the windows: \(error.localizedDescription, privacy: .public)")
                highlight.finish(copied: nil, announces: !settings.showTextResult)
                done?(nil)
            }
        }
    }

    #if DEBUG
    /// How long Vision's reading takes longer than it does, as when the Neural Engine compiles its models first: a
    /// reading to stop with Escape. For scripted checks.
    var debugStall: Duration?

    /// Whether the highlight takes Escape now, and a press of it as its hot key delivers one. For scripted checks.
    var takesEscape: Bool { highlight.takesEscape }
    @discardableResult
    func pressEscape() -> Bool { highlight.simulateEscape() }

    /// Where a window is on screen, for asking its app for its text (the scale taken from the window's display). For
    /// scripted checks.
    func place(ofWindow target: WindowTarget) -> AppTextPlace? {
        let scale = displays.layout.display(at: CGPoint(x: target.frame.midX, y: target.frame.midY))?.pixelsPerPoint ?? 2
        guard let owner = WindowCatalog.owner(of: target.id), owner != ProcessInfo.processInfo.processIdentifier else { return nil }
        return AppTextPlace(frame: target.frame, scale: scale, pid: owner)
    }

    /// Capture Text over one window, as when it is picked, without touching the clipboard. For scripted checks.
    func previewRecognition(ofWindow target: WindowTarget, joinLines: Bool, done: @escaping (String?) -> Void) async {
        do {
            let frame = try await capturer.captureWindow(target, shadow: false, layout: displays.layout)
            await recognize(
                frame.image, selection: target.frame, place: Self.place(of: frame, window: target), joinLines: joinLines, copiesToClipboard: false,
                done: done
            )
        } catch {
            done(nil)
        }
    }
    #endif

    /// The URL API's `capture-text` with a file: its text goes to the clipboard as a selection's does, the card (when
    /// it is on) by the pointer. Nothing is highlighted: the picture is not on screen.
    /// - Parameter copiesToClipboard: false for a shortcut's action, which hands the text on instead.
    func recognize(fileAt url: URL, joinLines: Bool, copiesToClipboard: Bool = true, done: ((String?) -> Void)? = nil) async {
        guard let loaded = await Self.load(.file(url), fallbackScale: 1) else {
            Log.capture.error("Could not read \(url.lastPathComponent, privacy: .private) to recognize its text")
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
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            if !Task.isCancelled { onTextRecognized?() }
            return text
        } catch {
            Log.capture.error("Recognizing a shortcut's picture failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A picture file's text as Capture Text puts it together, or nil when it has none; nothing is copied or shown. It is
    /// read on this Mac, never by the cloud model: in the text reader, with the second reading, formula, and VLM packs
    /// installed, so the app is no larger after it (Docs/perf.md, M5 — power gate), or here while the reader isn't in
    /// the app. For a shortcut's Recognize Text in Image, and Copy Text on a Quick Access card or in Capture History.
    func text(ofPictureAt url: URL, joinLines: Bool) async throws -> String? {
        guard let reader = readers?() else {
            guard let loaded = await Self.load(.file(url), fallbackScale: 1) else { return nil }
            return await text(in: loaded.image, joinLines: joinLines)
        }
        do {
            let text = try await TextReaderTool.text(
                ofPictureAt: url, joinsWrappedLines: joinLines, pack: reader.second?.folder,
                formulas: reader.formula, vlm: reader.vlm, seconds: reader.vlm != nil ? Self.panelTableWait : nil,
                helper: reader.helper
            )
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        } catch let failure as TextReaderTool.Failure {
            // As Capture Text's own reading does: no text, rather than an error.
            Log.capture.error("Recognizing a picture's text failed: \(String(describing: failure), privacy: .public)")
            return nil
        }
    }

    /// With the formula pack installed, the formulas in the picture are found and read in the text reader beside Vision's
    /// reading, and the text copied holds each as LaTeX (Docs/ocr.md › Formulas among text); with the VLM pack, its tables
    /// and charts, a row a line, where they bear themselves out (Docs/ocr.md › The VLM pack); the highlight stays on until
    /// they are in. While Settings has Capture Text read with the cloud model (and `allowsCloud`), the picture goes
    /// to it beside them, and its text is copied once it comes; when it can't read the picture (or takes over
    /// `cloudWait`), this Mac's reading is copied, and the card says so even when it is off.
    ///
    /// While Settings says so, the app under `place` (where the picture was on screen) is asked for the text it shows
    /// where Vision read its lines, and the lines it shows alike take its characters (L0, Docs/ocr.md › Text from apps);
    /// the card then says the text came from that app. The cloud model's text, when it comes, is copied as it reads.
    private func recognize(
        _ image: CGImage, selection: CGRect, place: AppTextPlace? = nil, joinLines: Bool, copiesToClipboard: Bool, allowsCloud: Bool = false,
        done: ((String?) -> Void)? = nil
    ) async {
        guard !Task.isCancelled else { done?(nil); return }
        let capturedScale = selection.width > 0 ? CGFloat(image.width) / selection.width : 1
        var snapshot = CapturedSnapshot(image: image, scale: capturedScale, source: String(localized: "Screen Area"), place: place)
        var showsCard: Bool { settings.showTextResult }
        let probe = LatencyProbe("ocr.recognize")
        defer { probe.end() }
        let localDeadline = ContinuousClock.now + .seconds(60)
        readings += 1
        let reading = readings
        waitingForCloud?.cancel()
        waitingForCloud = nil
        let clipboard = NSPasteboard.general.changeCount
        let cloud = allowsCloud ? captureTextCloud?() : nil
        if let cloud, !cloud.model.isLocal, selection.width > 0, selection.height > 0 {
            let host = cloud.model.host ?? cloud.model.displayName
            highlight.updateStatus(String(localized: "Sending to \(host)… · Esc"))
        }
        let cloudReading = cloud.map { cloud in Task { try await cloud.read(image, joinLines) } }
        waitingForCloud = cloudReading
        let second = settings.usesSecondReadingInCaptureText
            ? readers?().flatMap { reader in reader.second.map { (pack: $0, helper: reader.helper) } }
            : nil
        let reader = elementReader
        let vlm = reader?.vlm.flatMap { isTerminal(place) ? nil : $0 }
        if reader?.vlm != nil, vlm == nil { Log.capture.notice("Capture Text leaves the tables to Vision: the picture is of a terminal") }
        let formulas = reader.map { reader in
            let worker = elementTextReader
            return Task { await Self.elements(in: image, formulas: reader.formula, vlm: vlm, seconds: vlm != nil ? Self.tableWait : nil, helper: reader.helper, worker: worker) }
        }
        defer {
            cloudReading?.cancel()
            formulas?.cancel()
        }
        let currentPipeline = pipeline
        let visionLines: [OCRLine]?
        var visionReader: (worker: TextReaderWorker, compatibility: Bool)?
        var visionFailure: String?
        let vision = LatencyProbe("ocr.vision")
        do {
            #if DEBUG
            if let stall = debugStall { try await Task.sleep(for: stall) }
            #endif
            let result = try await captureTextLines(in: image, deadline: localDeadline)
            visionLines = result.lines
            visionReader = result.reader
        } catch {
            Log.capture.error("Capture Text failed to recognize: \(String(describing: error), privacy: .public)")
            if error as? OCRError == .timedOut || error as? TextReaderTool.Failure == .timedOut {
                visionFailure = String(localized: "Text recognition took too long. Try the selection again.")
            } else if !(error is CancellationError) {
                visionFailure = String(localized: "Text recognition failed. Try the selection again.")
            }
            visionLines = nil
        }
        vision.end()
        guard !Task.isCancelled, reading == readings else {
            cloudReading?.cancel()
            formulas?.cancel()
            done?(nil)
            return
        }
        if let visionLines {
            snapshot.cachedLines = visionLines
        }
        // Asked at once, while the screen still shows what the picture does: before any wait for the cloud model.
        let appText = Self.appText(for: visionLines, in: settings.readsAppText ? place : nil, layout: displays.layout)

        var note: String?
        if let cloud, let cloudReading {
            if cloud.model.isLocal, selection.width > 0, selection.height > 0 {
                let host = cloud.model.host ?? cloud.model.displayName
                highlight.updateStatus(String(localized: "Sending to \(host)… · Esc"))
            }
            let started = ContinuousClock.now
            let outcome = await Self.first(cloudReading, within: Self.cloudWait)
            guard !Task.isCancelled, reading == readings else {
                // Another Capture Text started meanwhile: the clipboard and the highlight are its.
                formulas?.cancel()
                Log.capture.notice("Capture Text let go of a reading another one replaced")
                done?(nil)
                return
            }
            waitingForCloud = nil
            switch outcome {
            case .success(let cloudText)?:
                snapshot.cachedCloud = cloudText
                let text = cloudText.text
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onTextRecognized?()
                    formulas?.cancel()
                    last = nil
                    let readBy = String(localized: "Read by \(cloud.model.displayName)")
                    Log.capture.notice("Capture Text read \(text.count, privacy: .public) characters with the cloud model, \(String(describing: ContinuousClock.now - started), privacy: .public) after Vision's reading")
                    if copiesToClipboard, NSPasteboard.general.changeCount != clipboard {
                        keepUncopied(text, note: readBy, near: selection, openInPanel: openInPanel(for: snapshot))
                        done?(nil)
                        return
                    }
                    if copiesToClipboard { copy(text) }
                    highlight.finish(copied: text, announces: !showsCard)
                    if showsCard { presentCard(.copied(text: text, joined: joinLines, canJoin: false), near: selection, note: readBy, openInPanel: openInPanel(for: snapshot)) }
                    done?(text)
                    return
                }
                note = String(localized: "\(cloud.model.displayName) found no text, so this Mac’s reading was copied.")
            case .failure(let error)?:
                note = String(localized: "\(cloud.model.displayName) couldn’t read it, so this Mac’s reading was copied: \(error.localizedDescription)")
            case nil:
                cloudReading.cancel()
                note = String(localized: "\(cloud.model.displayName) took too long, so this Mac’s reading was copied.")
            }
            highlight.updateStatus(nil)
            Log.capture.notice("Capture Text falls back to this Mac's reading: the cloud model gave no text")
        }

        guard var lines = visionLines else {
            formulas?.cancel()
            note = note ?? visionFailure
            highlight.finish(copied: nil, announces: !showsCard)
            if showsCard || note != nil { presentCard(.empty, near: selection, note: note, openInPanel: openInPanel(for: snapshot)) }
            done?(nil)
            return
        }
        if let second, SecondReading.wanted(lines), PPOCRReader.reads(width: image.width, height: image.height) {
            if let secondLines = await Self.secondReading(of: image, with: second.pack, helper: second.helper) {
                lines = SecondReading.merged(lines, with: secondLines)
                snapshot.secondReadingDone = true
            }
        }
        var appNote: String?
        if let appText {
            let reading = await appText.value
            let merge = AppTextMerge.merged(lines, with: reading.lines.map { AppTextLine(box: $0.box, pieces: $0.pieces, app: $0.app) })
            Self.log(reading, merge, of: lines.count, in: "Capture Text")
            appNote = merge.source.map { String(localized: "Text from \($0)") }
            lines = merge.lines
        }
        if let formulas {
            let started = ContinuousClock.now
            let found = await withTaskCancellationHandler {
                await formulas.value
            } onCancel: {
                formulas.cancel()
            }
            if !found.formulas.isEmpty, !Task.isCancelled {
                let remaining = ContinuousClock.now.duration(to: localDeadline)
                if remaining > .zero {
                    if let visionReader {
                        // Formula repair must also stay outside the failed native instance.
                        if let repaired = try? await Self.isolatedTextLines(in: image, worker: visionReader.worker, compatibility: visionReader.compatibility, timeout: remaining, formulas: found.formulas, inputLines: lines) {
                            lines = repaired
                        }
                    } else {
                        var repair = pipeline
                        repair.options.overallTimeout = remaining
                        lines = await repair.lines(lines, with: found.formulas, in: image)
                    }
                }
                Log.capture.notice("Capture Text put \(found.formulas.count, privacy: .public) formulas into its text, \(String(describing: ContinuousClock.now - started), privacy: .public) after Vision's reading")
            }
            if !found.tables.isEmpty {
                let merge = TableMerge.merged(lines, with: found.tables, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                lines = merge.lines
                Self.log(merge, of: found.tables, in: "Capture Text", after: ContinuousClock.now - started)
            }
        }
        snapshot.cachedLines = lines

        guard !Task.isCancelled, reading == readings else { done?(nil); return }

        // The card says where the text came from only when it shows anyway.
        var recognition = Recognition(lines: lines, selection: selection, joined: joinLines, copiesToClipboard: copiesToClipboard, note: note ?? (showsCard ? appNote : nil))
        let text = assemble(recognition)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let detectedCodes = (try? await VisionPipeline.selectionCodes(in: image)) ?? []
            guard !Task.isCancelled, reading == readings else { done?(nil); return }
            var seenPayloads = Set<String>()
            let uniqueCodes = detectedCodes.filter { seenPayloads.insert($0.payload).inserted }
            if !uniqueCodes.isEmpty {
                let copiedText = uniqueCodes.map(\.payload).joined(separator: "\n")
                let foundCodes = uniqueCodes.map { FoundCode(payload: $0.payload, isMatrix: $0.kind.isMatrix, box: $0.box) }
                let codeSummary: String
                if foundCodes.count == 1 {
                    let code = foundCodes[0]
                    let summary = code.displaySummary
                    codeSummary = summary == code.payload
                        ? (code.isMatrix ? String(localized: "Copied QR code") : String(localized: "Copied barcode"))
                        : summary
                } else {
                    codeSummary = String(localized: "Copied \(foundCodes.count) codes")
                }
                onTextRecognized?()
                if cloud != nil, copiesToClipboard, NSPasteboard.general.changeCount != clipboard {
                    last = nil
                    keepUncopied(copiedText, note: note ?? codeSummary, near: selection, openInPanel: openInPanel(for: snapshot))
                    done?(nil)
                    return
                }
                if copiesToClipboard { copy(copiedText) }
                last = nil
                let announcement = foundCodes.count == 1
                    ? String(localized: "Copied \(foundCodes[0].displaySummary)")
                    : codeSummary
                highlight.finish(copied: copiedText, announces: !showsCard, announcement: announcement)
                Log.capture.notice("Capture Text fell back to \(uniqueCodes.count, privacy: .public) code(s), copied \(copiedText.count, privacy: .public) characters")
                if showsCard || note != nil {
                    presentCard(.copied(text: copiedText, joined: false, canJoin: false), near: selection, note: note ?? codeSummary, openInPanel: openInPanel(for: snapshot))
                }
                done?(copiedText)
                return
            }
            last = nil
            Log.capture.notice("Capture Text found no text")
            highlight.finish(copied: nil, announces: !showsCard)
            if showsCard || note != nil { presentCard(.empty, near: selection, note: note, openInPanel: openInPanel(for: snapshot)) }
            done?(nil)
            return
        }
        onTextRecognized?()
        // After a wait for the cloud model, something copied meanwhile stays on the clipboard.
        if cloud != nil, copiesToClipboard, NSPasteboard.general.changeCount != clipboard {
            last = nil
            keepUncopied(text, note: note, near: selection, openInPanel: openInPanel(for: snapshot))
            done?(nil)
            return
        }
        if copiesToClipboard { copy(text) }
        recognition.joined = joinLines
        last = recognition
        highlight.finish(copied: text, announces: !showsCard)
        Log.capture.notice("Capture Text copied \(text.count, privacy: .public) characters in \(lines.count, privacy: .public) lines")
        // The cloud model's failure is said even with the card off: Capture Text would otherwise read differently
        // without a word.
        if showsCard || note != nil {
            presentCard(.copied(text: text, joined: joinLines, canJoin: canJoin(recognition)), near: selection, note: recognition.note, openInPanel: openInPanel(for: snapshot))
        }
        done?(text)
    }

    /// Short selections reuse isolated models, answering as soon as the reader writes its result.
    /// Waiting for process exit adds seconds while Apple's native resources finish shutting down.
    private func captureTextLines(in image: CGImage, deadline: ContinuousClock.Instant) async throws -> (lines: [OCRLine], reader: (worker: TextReaderWorker, compatibility: Bool)?) {
        // Revision 2 loses vertical text and too much detail on large selections. Keep the current
        // recognizer's full budget there; recovery is for the short horizontal selections it reads well.
        guard image.height <= 1024, image.width >= image.height,
              let primaryTextReader, let recoveryTextReader else {
            return (try await pipeline.recognize(image).lines, nil)
        }
        let layout = Task { try await Self.allowsTextRecovery(in: image) }
        defer { layout.cancel() }
        // Geometry of the picture alone cannot distinguish vertical text drawn on a wide canvas.
        // Unknown layout keeps the current recognizer, including its remaining full-image budget.
        let orientation = await Self.first(layout, within: .milliseconds(250))
        try Task.checkCancellation()
        guard case .success(true)? = orientation else { return (try await pipeline.recognize(image).lines, nil) }
        // The image already exists: only first-use setup belongs ahead of it, not an idle probe.
        prepareCaptureText(refreshIdleRecovery: false)
        if let readerPreparation,
           case .success(let recovery)? = await Self.first(readerPreparation, within: .seconds(4)) {
            usesCompatibilityTextReader = usesCompatibilityTextReader || recovery
        }
        try Task.checkCancellation()
        if !usesCompatibilityTextReader {
            let remaining = min(.seconds(3), ContinuousClock.now.duration(to: deadline))
            guard remaining > .zero else { throw OCRError.timedOut }
            do {
                let lines = try await Self.isolatedTextLines(in: image, worker: primaryTextReader, compatibility: false, timeout: remaining)
                return (lines, (primaryTextReader, false))
            } catch {
                try Task.checkCancellation()
            }
            usesCompatibilityTextReader = true
            Log.capture.notice("Capture Text is retrying in an isolated text reader: Vision did not answer promptly")
        }
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw OCRError.timedOut }
        let lines = try await Self.isolatedTextLines(in: image, worker: recoveryTextReader, timeout: remaining)
        recoveryLastUsed = .now
        try Task.checkCancellation()
        usesCompatibilityTextReader = true
        return (lines, (recoveryTextReader, true))
    }

    @concurrent
    private nonisolated static func allowsTextRecovery(in image: CGImage) async throws -> Bool {
        let size = CGSize(width: image.width, height: image.height)
        let regions = try await DetectTextRectanglesRequest().perform(on: image)
            .map { $0.boundingBox.toImageCoordinates(size, origin: .upperLeft) }
        return OCRRecoveryLayout.allows(size: size, textRegions: regions)
    }

    @concurrent
    private nonisolated static func isolatedTextLines(
        in image: CGImage, worker: TextReaderWorker, compatibility: Bool = true, timeout: Duration, formulas: [FormulaMerge.Formula]? = nil, inputLines: [OCRLine]? = nil
    ) async throws -> [OCRLine] {
        let deadline = ContinuousClock.now + timeout
        try Task.checkCancellation()
        guard let file = readerPicture(image, in: "Formula Readings") else { throw OCRError.unreadableImage }
        defer { try? FileManager.default.removeItem(at: file) }
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw OCRError.timedOut }
        let found = formulas.map { $0.map { TextReaderTool.FoundFormula(kind: $0.kind == .display ? .display : .inline, box: $0.box, latex: $0.latex) } }
        let base = try inputLines.map { try JSONEncoder().encode($0) }
        let data: Data
        do {
            data = try await worker.visionLines(ofPictureAt: file, compatibility: compatibility, formulas: found, inputLines: base, timeout: remaining)
        } catch TextReaderTool.Failure.unreadable(let reason) {
            // Apple's cached native context can become invalid after idle. The worker discards an
            // erroring process; retry this picture once with a fresh context, within the same budget.
            try Task.checkCancellation()
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw OCRError.timedOut }
            Log.capture.notice("Capture Text is replacing a failed native text reader: \(reason, privacy: .public)")
            data = try await worker.visionLines(ofPictureAt: file, compatibility: compatibility, formulas: found, inputLines: base, timeout: remaining)
        }
        return try JSONDecoder().decode([OCRLine].self, from: data)
    }

    /// Where a picture of the screen was, for asking the apps there for their text; a window's own app for a window.
    /// Nil for a window of OhMyShot's own (Settings, History, an editor): it isn't asked about its own text.
    private static func place(of frame: CapturedFrame, window: WindowTarget? = nil) -> AppTextPlace? {
        let owner = window.flatMap { WindowCatalog.owner(of: $0.id) }
        if window != nil, owner == nil || owner == ProcessInfo.processInfo.processIdentifier { return nil }
        return AppTextPlace(frame: frame.frame, scale: scale(of: frame), pid: owner)
    }

    /// Picked windows' place: their app's, when they all belong to one. Windows of several apps ask no app for its text,
    /// since the app in front at a line could be one whose window wasn't picked.
    private static func place(of frame: CapturedFrame, windows targets: [WindowTarget]) -> AppTextPlace? {
        guard let first = targets.first else { return nil }
        let owner = WindowCatalog.owner(of: first.id)
        guard targets.dropFirst().allSatisfy({ WindowCatalog.owner(of: $0.id) == owner }) else { return nil }
        return place(of: frame, window: first)
    }

    /// The apps' text at the lines' places (L0), being read for `budget` at most; nil while Settings leaves it off (no
    /// `place`), while Accessibility is off for OhMyShot, or with no lines to ask about.
    private nonisolated static func appText(
        for lines: [OCRLine]?, in place: AppTextPlace?, layout: DisplayLayout, within budget: Duration = .milliseconds(150)
    ) -> Task<AppTextReading, Never>? {
        guard let place, let lines, !lines.isEmpty, AppText.isAllowed else { return nil }
        let boxes = lines.map(\.box)
        return Task { await AppText.read(boxes, in: place, layout: layout, within: budget) }
    }

    /// What the apps said, in numbers alone: never their text.
    private nonisolated static func log(_ reading: AppTextReading, _ merge: AppTextMerge.Merged, of count: Int, in reader: String) {
        let apps = Set(reading.lines.map(\.app)).count
        var extra = ""
        if merge.dropped > 0 { extra += ", \(merge.dropped) scraps dropped" }
        if reading.outOfTime { extra += ", out of time after \(reading.asked) lines" }
        if reading.secure > 0 { extra += ", \(reading.secure) over password fields" }
        Log.capture.notice("\(reader, privacy: .public) took \(merge.taken.count, privacy: .public) of \(count, privacy: .public) lines from \(apps, privacy: .public) apps (\(merge.changed, privacy: .public) changed); \(reading.lines.count, privacy: .public) answered at \(reading.points, privacy: .public) points in \(String(describing: reading.duration), privacy: .public)\(extra, privacy: .public)")
    }

    /// The task's outcome, or nil when it takes longer than `limit` (the task goes on; the caller may cancel it).
    nonisolated static func first<Value: Sendable, Failure: Error>(_ task: Task<Value, Failure>, within limit: Duration) async -> Result<Value, Failure>? {
        let (outcomes, outcome) = AsyncStream.makeStream(of: Result<Value, Failure>?.self)
        let waiting = Task {
            outcome.yield(await task.result)
            outcome.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            outcome.yield(nil)
            outcome.finish()
        }
        defer {
            waiting.cancel()
            timer.cancel()
        }
        for await first in outcomes { return first }
        return nil
    }

    /// Shows text read but not copied, because the clipboard changed while the cloud model read it: the card, with Copy,
    /// shows even while it is off.
    private func keepUncopied(_ text: String, note: String?, near selection: CGRect, openInPanel: (() -> Void)?) {
        uncopied = (text, note, selection)
        highlight.finish(copied: text, announces: false)
        presentCard(.notCopied(text: text), near: selection, note: String(localized: "You copied something else while it was read."), openInPanel: openInPanel)
        Log.capture.notice("Capture Text left \(text.count, privacy: .public) characters off the clipboard, which changed meanwhile")
    }

    /// The card's Copy, for text that wasn't copied.
    private func copyUncopied() {
        guard let uncopied else { return }
        copy(uncopied.text)
        self.uncopied = nil
        presentCard(.copied(text: uncopied.text, joined: false, canJoin: false), near: uncopied.selection, note: uncopied.note, openInPanel: hud.onOpenInPanel)
    }

    /// The card's switch: copies the text again with the other line-break choice.
    private func toggleJoin() {
        guard var recognition = last else { return }
        recognition.joined.toggle()
        let text = assemble(recognition)
        if recognition.copiesToClipboard { copy(text) }
        last = recognition
        presentCard(.copied(text: text, joined: recognition.joined, canJoin: true), near: recognition.selection, note: recognition.note, openInPanel: hud.onOpenInPanel)
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

    // MARK: Capture Formula

    /// Capture Formula: drag over a formula, or pick a window, and its LaTeX goes to the clipboard, as it is (no `$`
    /// around it). The selection stays highlighted while the formula pack reads it in the text reader, on the CPU, and
    /// fades once the LaTeX is copied; the card, when it is on, shows it. Option held as the drag ends opens the area
    /// in the OCR panel instead, its text with each formula in it as LaTeX. Without the pack there is nothing to read
    /// with: a beep. `done` is told the LaTeX copied, or nil. Scripted checks leave the clipboard alone
    /// (`copiesToClipboard`) and choose whether the screen freezes (`freezes`, else Settings').
    func captureFormula(copiesToClipboard: Bool = true, freezes: Bool? = nil, done: ((String?) -> Void)? = nil) {
        guard !overlay.isActive else { done?(nil); return }
        guard readers?()?.formula != nil else {
            Log.capture.error("Capture Formula needs the formula pack, which isn't installed")
            NSSound.beep()
            done?(nil)
            return
        }
        overlay.freezesScreen = freezes ?? settings.freezeScreen
        overlay.begin(mode: .area, purpose: .text) { [weak self] outcome in
            guard let self else { done?(nil); return }
            switch outcome {
            case .region(let rect, _, let modifiers, let frozen) where modifiers.contains(.option):
                done?(nil)
                Task { await self.openPanel(region: rect, frozen: frozen) }
            case .window(let target, let modifiers) where modifiers.contains(.option):
                done?(nil)
                Task { await self.openPanel(windows: [target]) }
            case .region(let rect, _, _, let frozen):
                highlight.show(rect)
                Task { await self.readFormula(region: rect, frozen: frozen, copiesToClipboard: copiesToClipboard, done: done) }
            case .window(let target, _):
                highlight.show(target.frame)
                Task { await self.readFormula(windows: [target], copiesToClipboard: true, done: done) }
            case .windows(let targets, let modifiers):
                if let union = targets.combinedFrame {
                    if modifiers.contains(.option) {
                        done?(nil)
                        Task { await self.openPanel(windows: targets) }
                    } else {
                        highlight.show(union)
                        Task { await self.readFormula(windows: targets, copiesToClipboard: copiesToClipboard, done: done) }
                    }
                } else {
                    done?(nil)
                }
            case .annotated, .color, .record, .scroll, .allInOne, .allInOneWindows, .cancelled:
                done?(nil)
            }
        }
    }

    /// Reads the formula in a region of a display, as the overlay does after a drag; from the frozen frame, at its
    /// pixels (a formula drawn at 2x reads better than at 1x: Docs/ocr.md › L3 spike). Also the URL API's
    /// `capture-formula` with an area. `copiesToClipboard` false leaves the clipboard alone, for scripted checks.
    func readFormula(region rect: CGRect, frozen: CapturedFrame? = nil, copiesToClipboard: Bool = true, done: ((String?) -> Void)? = nil) async {
        await selection.run { [self] in
            highlight.show(rect)
            do {
                let frame = try await capture(rect, frozen: frozen)
                try Task.checkCancellation()
                await readFormula(frame.image, selection: rect, copiesToClipboard: copiesToClipboard, done: done)
            } catch {
                guard !Task.isCancelled else { done?(nil); return }
                Log.capture.error("Capture Formula failed to capture: \(error.localizedDescription, privacy: .public)")
                highlight.finish(copied: nil, announces: !settings.showTextResult, formula: true)
                done?(nil)
            }
        }
    }

    private func readFormula(windows targets: [WindowTarget], copiesToClipboard: Bool, done: ((String?) -> Void)?) async {
        guard let area = targets.combinedFrame else { done?(nil); return }
        await selection.run { [self] in
            highlight.show(area)
            do {
                let frame = try await capturer.captureWindows(targets, shadow: false, layout: displays.layout)
                try Task.checkCancellation()
                await readFormula(frame.image, selection: area, copiesToClipboard: copiesToClipboard, done: done)
            } catch {
                guard !Task.isCancelled else { done?(nil); return }
                Log.capture.error("Capture Formula failed to capture the windows: \(error.localizedDescription, privacy: .public)")
                highlight.finish(copied: nil, announces: !settings.showTextResult, formula: true)
                done?(nil)
            }
        }
    }

    /// The URL API's `capture-formula` with a file: its LaTeX goes to the clipboard, the card (when it is on) by the
    /// pointer.
    func readFormula(fileAt url: URL, copiesToClipboard: Bool = true, done: ((String?) -> Void)? = nil) async {
        guard let loaded = await Self.load(.file(url), fallbackScale: 1) else {
            Log.capture.error("Could not read \(url.lastPathComponent, privacy: .private) to read its formula")
            highlight.finish(copied: nil, announces: true, formula: true)
            done?(nil)
            return
        }
        await readFormula(loaded.image, selection: CGRect(origin: NSEvent.mouseLocation, size: .zero), copiesToClipboard: copiesToClipboard, done: done)
    }

    private func readFormula(_ image: CGImage, selection: CGRect, copiesToClipboard: Bool, done: ((String?) -> Void)?) async {
        guard !Task.isCancelled else { done?(nil); return }
        let capturedScale = selection.width > 0 ? CGFloat(image.width) / selection.width : 1
        let snapshot = CapturedSnapshot(image: image, scale: capturedScale, source: String(localized: "Screen Area"), place: nil)
        var showsCard: Bool { settings.showTextResult }
        guard let reader = readers?(), let pack = reader.formula else {
            highlight.finish(copied: nil, announces: !showsCard, formula: true)
            if showsCard { presentCard(.noFormula, near: selection, openInPanel: openInPanel(for: snapshot)) }
            done?(nil)
            return
        }
        let probe = LatencyProbe("ocr.formula")
        let started = ContinuousClock.now
        let formula = await Self.formula(in: image, pack: pack, helper: reader.helper)
        probe.end()
        // Escape stopped it: the highlight has gone, and nothing is said.
        guard !Task.isCancelled else { done?(nil); return }
        guard let formula, formula.isFormula else {
            Log.capture.notice("Capture Formula found no formula (\(formula?.ended.rawValue ?? "failed", privacy: .public)) in \(String(describing: ContinuousClock.now - started), privacy: .public)")
            highlight.finish(copied: nil, announces: !showsCard, formula: true)
            if showsCard { presentCard(.noFormula, near: selection, openInPanel: openInPanel(for: snapshot)) }
            done?(nil)
            return
        }
        onTextRecognized?()
        let formatted = settings.formulaDelimiter.wrap(formula.latex)
        if copiesToClipboard { copy(formatted) }
        highlight.finish(copied: formatted, announces: !showsCard, formula: true)
        Log.capture.notice("Capture Formula \(copiesToClipboard ? "copied" : "read", privacy: .public) \(formatted.count, privacy: .public) characters of LaTeX in \(String(describing: ContinuousClock.now - started), privacy: .public)")
        if showsCard { presentCard(.copiedFormula(latex: formatted), near: selection, openInPanel: openInPanel(for: snapshot)) }
        done?(formatted)
    }

    /// Warms both of Capture Text's models again, as its first reading would, for `TextModelWarmup`.
    func warmModelsAgain() async -> Bool {
        await VisionPipeline.forgetWarmups()
        return await pipeline.prewarm()
    }

    // MARK: Translate Area

    /// Translate Area: drag over text, or pick a window, and its translation covers it where it is.
    /// Option held when the drag ends opens the OCR panel, translated, instead.
    func translateArea() {
        guard !overlay.isActive else { return }
        lensRetranslation?.cancel()
        lensRetranslation = nil
        lensGeneration &+= 1
        lens.close(animated: false)
        overlay.freezesScreen = settings.freezeScreen
        overlay.begin(mode: .area, purpose: .text) { [weak self] outcome in
            switch outcome {
            case .region(let rect, _, let modifiers, let frozen):
                self?.highlight.show(rect)
                Task { await self?.translate(region: rect, frozen: frozen, inPanel: modifiers.contains(.option)) }
            case .window(let target, let modifiers):
                self?.highlight.show(target.frame)
                Task { await self?.translate(windows: [target], inPanel: modifiers.contains(.option)) }
            case .windows(let targets, let modifiers):
                if let union = targets.combinedFrame {
                    self?.highlight.show(union)
                    Task { await self?.translate(windows: targets, inPanel: modifiers.contains(.option)) }
                }
            case .annotated, .color, .record, .scroll, .allInOne, .allInOneWindows, .cancelled:
                break
            }
        }
    }

    func translate(region rect: CGRect, frozen: CapturedFrame? = nil, inPanel: Bool = false) async {
        await selection.run { [self] in
            do {
                let frame = try await capture(rect, frozen: frozen)
                try Task.checkCancellation()
                await translate(frame.image, scale: Self.scale(of: frame), over: rect, source: String(localized: "Screen Area"), inPanel: inPanel)
            } catch {
                guard !Task.isCancelled else { return }
                Log.capture.error("Translate Area failed to capture: \(error.localizedDescription, privacy: .public)")
                highlight.finish(copied: nil, announces: true)
            }
        }
    }

    private func translate(windows targets: [WindowTarget], inPanel: Bool) async {
        guard let area = targets.combinedFrame else { return }
        await selection.run { [self] in
            do {
                let frame = try await capturer.captureWindows(targets, shadow: false, layout: displays.layout)
                try Task.checkCancellation()
                await translate(frame.image, scale: Self.scale(of: frame), over: area, source: targets.ownerNames, inPanel: inPanel)
            } catch {
                guard !Task.isCancelled else { return }
                Log.capture.error("Translate Area failed to capture the windows: \(error.localizedDescription, privacy: .public)")
                highlight.finish(copied: nil, announces: true)
            }
        }
    }

    /// Reads `image`, translates it, and lays the translation over `frame`. When nothing could be
    /// translated (a language still to download, text already in the target, code), the area opens in
    /// the OCR panel, translated, which says why and offers a download or another language: a beep alone
    /// said nothing anyone could act on.
    func translate(_ image: CGImage, scale: CGFloat, over frame: CGRect, source: String, inPanel: Bool) async {
        lensRetranslation?.cancel()
        lensRetranslation = nil
        lensGeneration &+= 1
        let place = AppTextPlace(frame: frame, scale: scale)
        if inPanel {
            highlight.hide()
            openPanel(image: image, scale: scale, source: source, translating: true, place: place)
            return
        }
        let probe = LatencyProbe("ocr.translate-area")
        do {
            async let targetOptionsTask = availableTranslationTargets()
            let lines = try await pipeline.recognize(image).lines
            try Task.checkCancellation()
            let units = TranslationUnits.group(lines, image: image)
            let targetOptions = await targetOptionsTask
            try Task.checkCancellation()
            await presentTranslation(
                image: image, lines: lines, units: units, scale: scale, over: frame,
                source: source, place: place, targetOptions: targetOptions, probe: probe, isInitial: true
            )
        } catch {
            guard !Task.isCancelled else { return }
            Log.capture.error("Translate Area failed: \(String(describing: error), privacy: .public)")
            highlight.finish(copied: nil, announces: true)
        }
    }

    private func presentTranslation(
        image: CGImage, lines: [OCRLine], units: [TranslationUnit], scale: CGFloat, over frame: CGRect,
        source: String, place: AppTextPlace, targetOptions: [(id: String, name: String)],
        probe: LatencyProbe?, isInitial: Bool
    ) async {
        let generation = lensGeneration
        let target = settings.translationLanguage
        do {
            let outcome = try await translator.translate(units, to: target)
            // Escape stopped it (the highlight has gone): nothing is laid over the area, nor the panel opened.
            try Task.checkCancellation()
            guard lensGeneration == generation else { return }
            if !isInitial, lens.onOpenInPanel == nil { return }
            guard !outcome.translations.isEmpty else {
                let skipped = Dictionary(grouping: units.compactMap(\.skip), by: { "\($0)" }).map { "\($1.count) \($0)" }.sorted().joined(separator: ", ")
                Log.capture.notice("Translate Area translated nothing into \(outcome.target.minimalIdentifier, privacy: .public): \(units.count, privacy: .public) units, skipped \(skipped, privacy: .public), \(outcome.inTarget.count, privacy: .public) already in it, to download \(outcome.needsDownload.map(\.minimalIdentifier), privacy: .public); opening the panel")
                if isInitial { highlight.hide() } else { lens.close(animated: false) }
                openPanel(image: image, scale: scale, source: source, translating: true, place: place, cachedLines: lines)
                return
            }
            let rendering = await TranslationOverlay.render(
                image, lines: lines, units: units, translations: outcome.translations, language: outcome.target, scale: scale
            )
            try Task.checkCancellation()
            guard lensGeneration == generation else { return }
            if !isInitial, lens.onOpenInPanel == nil { return }
            guard let rendering else {
                if isInitial { highlight.finish(copied: nil, announces: true) } else { NSSound.beep() }
                return
            }
            probe?.end()
            if isInitial { onTextRecognized?() }
            let (text, translated) = Translator.text(of: units, outcome)
            let sources = ListFormatter.localizedString(byJoining: outcome.sources.map { Translator.name(of: $0) })
            let options = resolvedTargetOptions(base: targetOptions)
            lens.saveDirectory = settings.exportDirectory
            lens.show(
                rendering.image, original: image, scale: scale, over: frame, text: text, translated: translated,
                language: Translator.identifier(of: outcome.target), summary: "\(sources) → \(Translator.name(of: outcome.target))",
                shortened: !rendering.truncated.isEmpty, needsDownload: !outcome.needsDownload.isEmpty,
                targetLanguage: settings.translationLanguage,
                availableTargetLanguages: options,
                onChangeTargetLanguage: { [weak self] identifier in
                    self?.changeLensTargetLanguage(
                        to: identifier, image: image, lines: lines, units: units,
                        scale: scale, over: frame, source: source, place: place, targetOptions: targetOptions
                    )
                }
            )
            lens.onOpenInPanel = { [weak self] in
                self?.lensRetranslation?.cancel()
                self?.lensRetranslation = nil
                self?.openPanel(image: image, scale: scale, source: source, translating: true, place: place, cachedLines: lines)
            }
            if isInitial { highlight.hide() }
            Log.capture.notice("Translate Area translated \(outcome.translations.count, privacy: .public) of \(units.count, privacy: .public) units into \(outcome.target.minimalIdentifier, privacy: .public), \(rendering.truncated.count, privacy: .public) shortened")
        } catch {
            guard !Task.isCancelled else { return }
            Log.capture.error("Translate Area failed: \(String(describing: error), privacy: .public)")
            if isInitial {
                highlight.finish(copied: nil, announces: true)
            } else {
                NSSound.beep()
            }
        }
    }

    private func changeLensTargetLanguage(
        to identifier: String, image: CGImage, lines: [OCRLine], units: [TranslationUnit],
        scale: CGFloat, over frame: CGRect, source: String, place: AppTextPlace,
        targetOptions: [(id: String, name: String)]
    ) {
        guard identifier != settings.translationTarget else { return }
        settings.translationTarget = identifier
        lensRetranslation?.cancel()
        lensGeneration &+= 1
        lensRetranslation = Task { [weak self] in
            await self?.presentTranslation(
                image: image, lines: lines, units: units, scale: scale, over: frame,
                source: source, place: place, targetOptions: targetOptions, probe: nil, isInitial: false
            )
        }
    }

    private func availableTranslationTargets() async -> [(id: String, name: String)] {
        if cachedTranslationTargets.isEmpty {
            cachedTranslationTargets = await Translator.targets()
        }
        return cachedTranslationTargets.map {
            (id: Translator.identifier(of: $0), name: Translator.name(of: $0))
        }
    }

    private func resolvedTargetOptions(base: [(id: String, name: String)]) -> [(id: String, name: String)] {
        var options = base
        let current = settings.translationTarget
        if !current.isEmpty, !options.contains(where: { $0.id.caseInsensitiveCompare(current) == .orderedSame }) {
            let language = Locale.Language(identifier: current)
            options.insert((id: Translator.identifier(of: language), name: Translator.name(of: language)), at: 0)
        }
        return options
    }

    #if DEBUG
    func revealLensControls() { lens.revealControls() }

    func closeLens() {
        lensRetranslation?.cancel()
        lensRetranslation = nil
        lensGeneration &+= 1
        lens.close(animated: false)
    }
    #endif

    // MARK: OCR panel

    /// Opens the OCR panel on `image`, read in full: text, tables, links, and codes. `scale` is the
    /// image's pixels per point; `source` names it under the title.
    ///
    /// With a model pack installed, a picture whose text holds Chinese or Japanese is read again with it in the text
    /// reader asynchronously (`TextRecognitionWindowController.secondReadingRefiner`) once Vision's reading shows.
    ///
    /// With the formula pack installed, the formulas in the picture are found and read in the text reader beside
    /// Vision's reading, and come into the text as LaTeX once read.
    ///
    /// A picture of the screen (`place`) takes the characters of the apps there for the lines they show alike, while
    /// Settings says so (L0, Docs/ocr.md › Text from apps); they are asked as soon as Vision has read, and their
    /// characters go over the second reading's.
    func openPanel(
        image: CGImage, scale: CGFloat, source: String, translating: Bool = false, place: AppTextPlace? = nil,
        cachedLines: [OCRLine]? = nil, secondReadingDone: Bool = false
    ) {
        let controller = panel ?? makePanel()
        panel = controller
        let second = (cachedLines?.isEmpty == false && secondReadingDone)
            ? nil
            : readers?().flatMap { reader in reader.second.map { (pack: $0, helper: reader.helper) } }
        let placeForL2 = settings.readsAppText ? place : nil
        let layout = displays.layout
        TextRecognitionWindowController.secondReadingRefiner = second.map { second in
            { @Sendable image, visionLines in
                guard SecondReading.wanted(visionLines), PPOCRReader.reads(width: image.width, height: image.height) else {
                    return visionLines
                }
                let started = ContinuousClock.now
                guard let l2Lines = await Self.secondReading(of: image, with: second.pack, helper: second.helper) else {
                    return visionLines
                }
                var merged = SecondReading.merged(visionLines, with: l2Lines)
                if let asking = Self.appText(for: merged, in: placeForL2, layout: layout, within: .milliseconds(500)) {
                    let reading = await asking.value
                    let appMerge = AppTextMerge.merged(merged, with: reading.lines.map { AppTextLine(box: $0.box, pieces: $0.pieces, app: $0.app) })
                    merged = appMerge.lines
                }
                Log.capture.notice("Second reading (async): \(l2Lines.count, privacy: .public) lines merged in \(String(describing: ContinuousClock.now - started), privacy: .public)")
                return merged
            }
        }
        controller.show(
            image: image, scale: scale, source: source, translating: translating, elements: panelElements(readsTables: !isTerminal(place)),
            analyze: analyzer(for: place, cachedLines: cachedLines)
        )
    }

    /// The terminals whose windows keep their text as the program printed it: a listing in columns there (`ls -l`) isn't
    /// read as a table, which the layout model takes it for (Docs/ocr.md › The VLM pack).
    nonisolated static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.raphaelamorim.rio", "dev.commandline.waveterm",
        "com.termius-dmg.mac", "org.tabby",
    ]

    /// Whether the picture at `place` (of the screen; none for a file or the clipboard) is of a terminal: a picked
    /// window's own app, else the app whose standard window is in front at the middle of the area, OhMyShot's own left out.
    func isTerminal(_ place: AppTextPlace?) -> Bool {
        guard let place else { return false }
        let pid = place.pid ?? Optional(place.frame).flatMap { area -> pid_t? in
            let middle = displays.layout.flipped(CGPoint(x: area.midX, y: area.midY))
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            return list.lazy.compactMap { info -> pid_t? in
                guard (info[kCGWindowLayer as String] as? Int) == 0,
                      let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != ProcessInfo.processInfo.processIdentifier,
                      let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                      CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0).contains(middle)
                else { return nil }
                return owner
            }.first
        }
        guard let pid, let identifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return Self.terminals.contains(identifier)
    }

    /// How the panel reads a picture: Vision (or cached OCR lines from Capture Text) and, for a picture of the
    /// screen (`place`), the apps' characters while Settings says so. L2 runs asynchronously via
    /// `TextRecognitionWindowController.secondReadingRefiner` so Vision shows immediately without a 3 s block.
    func analyzer(for place: AppTextPlace?, cachedLines: [OCRLine]? = nil) -> @Sendable (CGImage) async throws -> TextAnalysis {
        let pipeline = pipeline
        let place = settings.readsAppText ? place : nil
        let layout = displays.layout
        return { image in
            if let cachedLines, !cachedLines.isEmpty {
                return try await pipeline.analysis(reusing: cachedLines, in: image)
            }
            let analysis = try await pipeline.analyze(image)
            // Longer than Capture Text: the window shows Vision's reading meanwhile.
            let asking = Self.appText(for: analysis.result.lines, in: place, layout: layout, within: .milliseconds(500))
            var shown = analysis
            if let asking {
                let reading = await asking.value
                let (merged, merge) = shown.withAppText(
                    reading.lines.map { AppTextLine(box: $0.box, pieces: $0.pieces, app: $0.app) }, assembly: pipeline.options.assembly
                )
                Self.log(reading, merge, of: shown.result.lines.count, in: "The Recognized Text window")
                shown = merged
            }
            return shown
        }
    }

    /// How the panel gets the formulas, tables, and charts into its text; nil while neither the formula pack nor the VLM
    /// pack is installed. Asked as each panel opens.
    private func panelElements(readsTables: Bool = true) -> TextRecognitionWindowController.Elements? {
        guard let found = elementReader else { return nil }
        let reader = (formula: found.formula, vlm: readsTables ? found.vlm : nil, helper: found.helper)
        guard reader.formula != nil || reader.vlm != nil else { return nil }
        let pipeline = pipeline
        return .init(
            read: { image, found in
                await Self.elements(
                    in: image, formulas: reader.formula, vlm: reader.vlm, seconds: reader.vlm != nil ? Self.panelTableWait : nil, helper: reader.helper, found: found
                )
            },
            merge: { lines, formulas, image in await pipeline.lines(lines, with: formulas, in: image) }
        )
    }

    private func makePanel() -> TextRecognitionWindowController {
        let controller = TextRecognitionWindowController(settings: settings, translator: translator, cloud: cloud?())
        controller.onTextRecognized = { [weak self] in self?.onTextRecognized?() }
        controller.onOpenImage = { [weak self] image, scale, source in
            self?.openPanel(image: image, scale: scale, source: source)
        }
        controller.freshAnalyzer = { [weak self] in
            self?.analyzer(for: nil, cachedLines: nil) ?? { image in
                try await VisionPipeline().analyze(image)
            }
        }
        controller.formulaDelimiter = { [weak self] in
            self?.settings.formulaDelimiter ?? .raw
        }
        controller.onClose = MemoryRelief.releasingOnNextTurn { [weak self] in
            self?.panel = nil
            // Nothing translates until the next panel: the system's models need not stay loaded.
            await self?.translator.releaseSessions()
        }
        return controller
    }

    /// Option held when a Capture Text or Capture Formula drag ends. Also used by scripted checks.
    func openPanel(region rect: CGRect, frozen: CapturedFrame? = nil) async {
        do {
            let frame = try await capture(rect, frozen: frozen)
            openPanel(image: frame.image, scale: Self.scale(of: frame), source: String(localized: "Screen Area"), place: Self.place(of: frame))
        } catch {
            Log.capture.error("Capture Text failed to capture: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    /// Opens the OCR panel on the windows picked, each captured on its own, so a cloud model chosen there never gets
    /// what lies between them.
    private func openPanel(windows targets: [WindowTarget]) async {
        do {
            let frame = try await capturer.captureWindows(targets, shadow: false, layout: displays.layout)
            let title = targets.count == 1 ? targets[0].title.flatMap { $0.isEmpty ? nil : $0 } : nil
            openPanel(
                image: frame.image, scale: Self.scale(of: frame), source: title.map { "\(targets.ownerNames) – \($0)" } ?? targets.ownerNames,
                place: Self.place(of: frame, windows: targets)
            )
        } catch {
            Log.capture.error("Capture Text failed to capture the windows: \(error.localizedDescription, privacy: .public)")
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
    func openPanel(forFileAt url: URL, fallbackScale: CGFloat = 1, source: String? = nil, translating: Bool = false) async {
        guard let loaded = await Self.load(.file(url), fallbackScale: fallbackScale) else {
            Log.capture.error("Could not read \(url.lastPathComponent, privacy: .private) to recognize its text")
            showFailure(.unreadableFile, source: source ?? url.lastPathComponent)
            return
        }
        openPanel(image: loaded.image, scale: loaded.scale, source: source ?? url.lastPathComponent, translating: translating)
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
            let fallbackScale = displays.layout.sharpestPixelsPerPoint ?? 1
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

    /// Alias for `openClipboardImage()`, used by the Recognize Text from Clipboard shortcut.
    func recognizeClipboard() {
        openClipboardImage()
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
    @concurrent nonisolated static func load(_ content: PasteboardImage.Content, fallbackScale: CGFloat) async -> ImageLoader.Loaded? {
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
            presentCard(.empty, near: selection)
        case "single":
            presentCard(.copied(text: "7", joined: false, canJoin: false), near: selection)
        case "formula":
            presentCard(.copiedFormula(latex: #"\mathrm{Attention}(Q,K,V)=\mathrm{softmax}\left(\frac{QK^{T}}{\sqrt{d_{k}}}\right)V"#), near: selection)
        case "no-formula":
            presentCard(.noFormula, near: selection)
        case "not-copied":
            presentCard(.notCopied(text: "OhMyShot Release Notes\nCapture text from anything on screen."), near: selection, note: String(localized: "You copied something else while it was read."))
        case "cloud":
            presentCard(.copied(text: "OhMyShot Release Notes\nCapture text from anything on screen.", joined: false, canJoin: false), near: selection, note: String(localized: "Read by \("Claude")"))
        default:
            let sample = "截图完成后，卡片会出现在屏幕左下角，可以直接拖到其他应用里。\nPress Copy to put the capture on the clipboard.\n历史记录会保留一周，之后自动删除。\nVersion 0.1.0 (build 42)"
            presentCard(.copied(text: sample, joined: false, canJoin: true), near: selection)
        }
    }

    /// Opens the panel with a stand-in for recognition, to show the loading and failure states.
    func previewPanel(image: CGImage, scale: CGFloat, source: String, analyze: @escaping @Sendable (CGImage) async throws -> TextAnalysis) {
        let controller = panel ?? makePanel()
        panel = controller
        controller.show(image: image, scale: scale, source: source, elements: panelElements(), analyze: analyze)
    }

    /// Sets the open panel's pane, line breaks, selected or hovered line, and whether the text was edited.
    func previewPanelState(
        pane: String?, joinLines: Bool?, selectLine: Int?, hoverLine: Int?, edited: Bool, translate: Bool?, target: String?, cloud: String? = nil
    ) {
        panel?.preview(
            pane: pane, joinLines: joinLines, selectLine: selectLine, hoverLine: hoverLine, edited: edited, translate: translate, target: target,
            cloud: cloud
        )
    }

    /// Closes the panel, so the next one is made anew (with the cloud model then in place).
    func closePanel() {
        panel?.close()
    }

    /// Capture Text's reading of a picture, as after a person's drag over `selection` (the cloud model too, while
    /// Settings says so, with `allowsCloud`), without touching the clipboard.
    func previewRecognition(of image: CGImage, near selection: CGRect, joinLines: Bool, allowsCloud: Bool, done: ((String?) -> Void)? = nil) async {
        await recognize(image, selection: selection, joinLines: joinLines, copiesToClipboard: false, allowsCloud: allowsCloud, done: done)
    }

    /// Shows a failure to open, as a broken file or an empty clipboard would.
    func previewPanelFailure(_ failure: TextRecognitionWindowController.OpenFailure) {
        showFailure(failure, source: "Demo")
    }
    #endif
}

private extension [WindowTarget] {
    /// The windows' apps, each named once, as a list in the reader's language ("Safari and Notes").
    var ownerNames: String {
        var named = Set<String>()
        return ListFormatter.localizedString(byJoining: map(\.ownerName).filter { named.insert($0).inserted })
    }
}
