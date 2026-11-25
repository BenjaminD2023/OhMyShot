import AppKit
import CoreGraphics
import Foundation
import OMSDesign
import Observation
import OMSCore
import OMSOCR
import OSLog
import SwiftUI
// The framework predates strict concurrency; its sessions are handed to the view that asked for them.
@preconcurrency import Translation
import UniformTypeIdentifiers

@MainActor
@Observable
final class TextRecognitionModel {
    enum Phase: Equatable {
        case loading
        case ready
        case empty
        /// `canRetry`: reading again may help, as after a timeout; a file that is no image will not.
        case failed(title: String, message: String, canRetry: Bool)
    }

    enum Pane: Hashable {
        case text
        case table
    }

    enum TableFormat {
        case markdown
        case csv
        case tsv
    }

    /// Whose reading the text side shows.
    enum TextSource: Hashable {
        /// Vision's, with the model packs', on this Mac.
        case device
        /// The cloud model's.
        case cloud
    }

    /// Reading with the cloud model, for the picture shown.
    enum CloudState: Equatable {
        case idle
        /// Sent, and `characters` of the answer have come.
        case reading(characters: Int)
        case read(CloudResult)
        case failed(message: String, canRetry: Bool)
    }

    struct CloudResult: Equatable {
        let reading: CloudReading
        /// The Markdown tables in its text.
        var tables: [OCRTable]
    }

    /// A translation of what was read, for one choice of target.
    struct Translation {
        /// The setting it was made for: a language, or empty for automatic.
        let choice: String
        let outcome: Translator.Outcome
        let units: [TranslationUnit]
        /// Unit by unit, one to a line: translated where it was, as read where not.
        let text: String
        /// The parts of `text` that were translated (UTF-16), in the target language.
        let translated: [NSRange]
        /// The image with the translation drawn over its text; nil when nothing was translated or text-only.
        let image: CGImage?
        /// True when translating Cloud OCR output or manually edited text without bounding-box overlay rendering.
        let isTextOnly: Bool
        /// Snapshot of the text translated when `isTextOnly` is true, so edits invalidate the cache.
        let sourceText: String?

        init(
            choice: String,
            outcome: Translator.Outcome,
            units: [TranslationUnit],
            text: String,
            translated: [NSRange],
            image: CGImage?,
            isTextOnly: Bool = false,
            sourceText: String? = nil
        ) {
            self.choice = choice
            self.outcome = outcome
            self.units = units
            self.text = text
            self.translated = translated
            self.image = image
            self.isTextOnly = isTextOnly
            self.sourceText = sourceText
        }
    }

    /// What a found item's button does, named for what the item is.
    struct Action {
        let title: Text
        let symbol: String
        let perform: () -> Void
    }

    @ObservationIgnored var onTextRecognized: (() -> Void)?
    @ObservationIgnored private var reportedReading = false

    private(set) var image: CGImage?
    /// The uncropped image when the user crops to a sub-region, so Full Image can restore it.
    private(set) var fullImage: CGImage?
    private(set) var isCropped = false
    private(set) var scale: CGFloat = 1
    private(set) var phase: Phase = .loading
    private(set) var lines: [OCRLine] = []
    /// Vision's lines (with formulas merged, before VLM `TableMerge` collapses table cells into wide rows) so
    /// in-place translation can still translate table cells individually.
    @ObservationIgnored private(set) var translationLines: [OCRLine] = []
    /// Local Vision failure deferred while a Cloud reading is active or shown, so cancelling/switching back to
    /// this Mac or a subsequent Cloud failure surfaces the real error instead of sticking on `.loading`.
    @ObservationIgnored private var deviceFailure: Phase?
    /// The tables Vision read.
    private(set) var visionTables: [OCRTable] = []
    private(set) var codes: [OCRCode] = []
    /// The formulas found by the formula pack for the current image.
    private(set) var formulas: [FormulaMerge.Formula] = []
    private(set) var isCode = false
    /// The text in the editor.
    private(set) var text = ""
    /// Bumped whenever the model, not the person, replaces the text; the editor applies it undoably.
    private(set) var revision = 0
    /// Where each line is in `text`, until the person edits it.
    private(set) var lineRanges: [NSRange] = []
    private(set) var edited = false
    private(set) var items: [DetectedItem] = []
    /// Bumped when a line is picked on the image: the editor takes focus, so the selection is live and
    /// ⌘C copies it.
    private(set) var focusRequest = 0
    var selection = NSRange(location: 0, length: 0)
    /// Whether the editor draws its selection as active (first responder in the key window). The boxes
    /// on the image follow it, so the two never disagree.
    var editorIsActive = false
    var hoveredLine: Int?
    var hoveredCode: Int?
    var pane: Pane = .text
    var tableIndex = 0
    var copied = false
    /// A window's actual line-break choice, independent of display wrapping and the saved default.
    var joinLines: Bool {
        didSet { if joinLines != oldValue { regenerate() } }
    }
    /// A window's display choice; changing it never rewrites the text or the saved default.
    var wrapsText: Bool

    /// Whether the translation is shown in place of the text as read.
    var translates = false {
        didSet { if translates != oldValue { translatesChanged() } }
    }
    private(set) var translation: Translation?
    private(set) var isTranslating = false
    private(set) var translationFailed = false
    /// The languages offered as targets, loaded when first needed.
    private(set) var targets: [Locale.Language] = []
    /// A language to download: the view hands it to the system, which asks the person first.
    var download: TranslationSession.Configuration?

    /// How many formulas and tables the packs found and are reading, once they said; nil when none are being read.
    private(set) var beingRead: TextRecognitionWindowController.Elements.Counts?

    /// The cloud model the toolbar's Read with reads with, read dynamically from `CloudModelStore` so
    /// changes made in Settings apply immediately even while this window is already open.
    var cloudModel: CloudModel? {
        cloudSetup?.store.usableModel
    }
    /// Whether Read with is on: the text side shows the cloud model's reading once it has come.
    private(set) var cloudOn = false
    /// Where reading with the cloud model stands for this picture.
    private(set) var cloud: CloudState = .idle
    @ObservationIgnored let cloudSetup: TextRecognitionWindowController.Cloud?
    @ObservationIgnored var cloudTask: Task<Void, Never>?
    /// Optional async L2 refiner (for tests; runtime uses `TextRecognitionWindowController.secondReadingRefiner`).
    @ObservationIgnored var secondReadingRefiner: (@Sendable (CGImage, [OCRLine]) async -> [OCRLine])?
    /// Optional pin callback for rendered translated images (for tests; runtime uses `TextRecognitionWindowController.onPinImage`).
    @ObservationIgnored var onPinImage: ((CGImage, CGFloat) -> Void)?
    /// Returns the delimiter used to format recognized LaTeX formulas when copied.
    @ObservationIgnored var formulaDelimiter: () -> FormulaDelimiter
    /// Optional hook wired by the app to open a newly pasted or dropped image with full coordinator setup.
    @ObservationIgnored var onOpenImage: ((CGImage, CGFloat, String) -> Void)?
    /// Optional hook wired by the app to create a fresh analyzer (without cached lines or screen place) after rotating or cropping.
    @ObservationIgnored var freshAnalyzer: (() -> (@Sendable (CGImage) async throws -> TextAnalysis))?
    /// Prompts before replacing edited text when a new image is loaded into this singleton window.
    @ObservationIgnored var confirmDiscardEdits: @MainActor () -> Bool = { TextRecognitionModel.defaultConfirmDiscardEdits() }

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let translator: Translator
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var analyze: (@Sendable (CGImage) async throws -> TextAnalysis)?
    @ObservationIgnored private var analysis: Task<Void, Never>?
    @ObservationIgnored private var secondReadingTask: Task<Void, Never>?
    @ObservationIgnored private var copiedReset: Task<Void, Never>?
    @ObservationIgnored private var elements: TextRecognitionWindowController.Elements?
    /// Finds and reads the formulas, tables, and charts, from the time the image is shown, beside Vision's reading.
    @ObservationIgnored private var elementReading: Task<TextRecognitionWindowController.Elements.Found, Never>?
    /// Puts them into the text once both are done.
    @ObservationIgnored private var elementMerge: Task<Void, Never>?
    @ObservationIgnored private var elementsMerged = false
    /// Counts the images loaded, so word from a reading of an earlier one is let go.
    @ObservationIgnored private var generation = 0

    init(settings: SettingsStore, translator: Translator, cloud: TextRecognitionWindowController.Cloud? = nil, pasteboard: NSPasteboard = .general) {
        self.settings = settings
        self.translator = translator
        self.pasteboard = pasteboard
        joinLines = !settings.textRecognitionKeepsLineBreaks
        wrapsText = settings.textRecognitionWrapsText
        cloudSetup = cloud
        formulaDelimiter = { settings.formulaDelimiter }
    }

    func load(
        image: CGImage, scale: CGFloat, analyze: @escaping @Sendable (CGImage) async throws -> TextAnalysis,
        elements: TextRecognitionWindowController.Elements? = nil
    ) {
        loadInternal(image: image, scale: scale, analyze: analyze, elements: elements, preservesFullImage: false)
    }

    private func loadInternal(
        image: CGImage, scale: CGFloat, analyze: @escaping @Sendable (CGImage) async throws -> TextAnalysis,
        elements: TextRecognitionWindowController.Elements?, preservesFullImage: Bool
    ) {
        let seededCloud = preservesFullImage ? nil : TextRecognitionWindowController.consumePendingCloudReading()
        if self.image != nil, edited, !confirmDiscardEdits() {
            return
        }
        analysis?.cancel()
        self.analyze = analyze
        self.elements = elements
        if preservesFullImage {
            fullImage = fullImage ?? self.image
            isCropped = true
        } else {
            fullImage = image
            isCropped = false
        }
        self.image = image
        self.scale = max(scale, 1)
        phase = .loading
        clearResults()
        generation += 1
        let generation = generation
        if let seededCloud, cloudModel != nil {
            cloudOn = true
            cloud = .read(CloudResult(reading: seededCloud, tables: MarkdownTables.tables(in: seededCloud.text)))
            if !seededCloud.text.isEmpty {
                phase = .ready
                regenerate()
                reportReading()
                if translates { translate() }
            }
        } else if cloudModel != nil, cloudSetup?.store.readsInPanel == true {
            // Read with the cloud model from the start, beside Vision, when Settings says every picture is.
            readsInCloud = true
        }
        let reading = elements.map { elements in
            Task { [weak self] in
                await elements.read(image) { counts in
                    Task { @MainActor in self?.elementsFound(counts, generation: generation) }
                }
            }
        }
        elementReading = reading
        let refiner = secondReadingRefiner ?? TextRecognitionWindowController.secondReadingRefiner
        analysis = Task { [weak self] in
            let probe = LatencyProbe("ocr.analyze")
            do {
                let result = try await analyze(image)
                probe.end()
                guard !Task.isCancelled, let self else { return }
                deviceFailure = nil
                lines = result.result.lines
                translationLines = result.result.lines
                visionTables = result.tables
                codes = result.codes
                if source == .device {
                    regenerate()
                }
                let hasDeviceText = !result.result.lines.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasText || hasDeviceText || !visionTables.isEmpty { reportReading() }
                phase = hasText || hasDeviceText || !codes.isEmpty || !visionTables.isEmpty || source == .cloud ? .ready : .empty
                if translates, phase == .ready, source == .device { translate() }
                Log.capture.notice("OCR panel read \(self.lines.count, privacy: .public) lines, \(self.visionTables.count, privacy: .public) tables, \(self.codes.count, privacy: .public) codes, \(self.items.count, privacy: .public) links and contacts")
                if let refiner, !result.result.lines.isEmpty {
                    startSecondReading(refiner: refiner, image: image, initialLines: result.result.lines, generation: generation)
                }
                if let reading, let elements { putElementsIn(reading, with: elements, image: image) }
            } catch {
                guard !Task.isCancelled, let self else { return }
                reading?.cancel()
                beingRead = nil
                // The details go to the log; the panel says what they mean.
                Log.capture.error("OCR panel failed: \(String(describing: error), privacy: .public)")
                let failure: Phase = .failed(
                    title: String(localized: "Couldn’t read this image", bundle: .module),
                    message: error as? OCRError == .timedOut
                        ? String(localized: "Reading it took too long.", bundle: .module)
                        : String(localized: "The text in it couldn’t be recognized.", bundle: .module),
                    canRetry: true
                )
                deviceFailure = failure
                if source != .cloud, !isReadingInCloud {
                    phase = failure
                }
            }
        }
    }

    private func startSecondReading(
        refiner: @escaping @Sendable (CGImage, [OCRLine]) async -> [OCRLine],
        image: CGImage,
        initialLines: [OCRLine],
        generation: Int
    ) {
        secondReadingTask?.cancel()
        secondReadingTask = Task { [weak self] in
            let refined = await refiner(image, initialLines)
            guard !Task.isCancelled, let self, self.generation == generation, !self.elementsMerged else { return }
            guard refined != initialLines else { return }
            self.lines = refined
            self.translationLines = refined
            if !self.edited, self.source == .device {
                self.regenerate()
                if self.translates, self.phase == .ready { self.translate() }
            }
            if self.phase == .empty, !refined.isEmpty {
                self.phase = .ready
                self.reportReading()
            }
        }
    }

    private static func defaultConfirmDiscardEdits() -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Replace edited text?", bundle: .module)
        alert.informativeText = String(localized: "Opening a new image will replace your edits in Recognized Text.", bundle: .module)
        alert.addButton(withTitle: String(localized: "Replace", bundle: .module))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .module))
        NSApp?.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Reads the same image again.
    func retry() {
        guard let image, let analyze else { return }
        loadInternal(image: image, scale: scale, analyze: analyze, elements: elements, preservesFullImage: isCropped)
    }

    func fail(_ failure: TextRecognitionWindowController.OpenFailure) {
        analysis?.cancel()
        analyze = nil
        elements = nil
        image = nil
        fullImage = nil
        isCropped = false
        clearResults()
        phase = switch failure {
        case .unreadableFile:
            .failed(
                title: String(localized: "Couldn’t open this file", bundle: .module),
                message: String(localized: "It isn’t an image OhMyShot can read.", bundle: .module),
                canRetry: false
            )
        case .noImageOnClipboard:
            .failed(
                title: String(localized: "No image on the clipboard", bundle: .module),
                message: String(localized: "Copy an image or an image file, then choose Recognize Text in Clipboard Image again.", bundle: .module),
                canRetry: false
            )
        }
    }

    func unload() {
        analysis?.cancel()
        analyze = nil
        elements = nil
        image = nil
        fullImage = nil
        isCropped = false
        clearResults()
    }

    // MARK: Image transform, crop, drop & paste

    /// Rotates the current image 90° clockwise or counterclockwise and re-runs OCR cleanly.
    func rotateImage(clockwise: Bool) {
        guard let current = image else { return }
        let change: PictureChange = clockwise ? .rotateRight : .rotateLeft
        guard let rotated = change.apply(to: current) else { return }
        let nextAnalyze = freshAnalyzer?() ?? analyze ?? makeFreshAnalyzer()
        loadInternal(image: rotated, scale: scale, analyze: nextAnalyze, elements: elements, preservesFullImage: false)
        announce(clockwise
            ? String(localized: "Rotated image right", bundle: .module)
            : String(localized: "Rotated image left", bundle: .module))
    }

    /// Crops the current image to `pixelRect` (in top-left pixel coordinates) and re-runs OCR on just that region.
    func cropImage(to pixelRect: CGRect) {
        guard let current = image else { return }
        let bounds = CGRect(x: 0, y: 0, width: current.width, height: current.height)
        let clamped = pixelRect.integral.intersection(bounds)
        guard !clamped.isNull, clamped.width >= 8, clamped.height >= 8,
              let cropped = current.cropping(to: clamped) else { return }
        let nextAnalyze = freshAnalyzer?() ?? analyze ?? makeFreshAnalyzer()
        loadInternal(image: cropped, scale: scale, analyze: nextAnalyze, elements: elements, preservesFullImage: true)
        announce(String(localized: "Recognizing selected area", bundle: .module))
    }

    /// Restores the full uncropped image and re-runs OCR on it.
    func restoreFullImage() {
        guard isCropped, let full = fullImage else { return }
        let nextAnalyze = freshAnalyzer?() ?? analyze ?? makeFreshAnalyzer()
        loadInternal(image: full, scale: scale, analyze: nextAnalyze, elements: elements, preservesFullImage: false)
        announce(String(localized: "Restored full image", bundle: .module))
    }

    /// Recognizes an image from `pasteboard` directly in this window. Returns whether the pasteboard held an image.
    @discardableResult
    func pasteImage(from pasteboard: NSPasteboard = .general) -> Bool {
        guard let content = PasteboardImage.read(pasteboard) else { return false }
        let source: String = if case .file(let url) = content {
            url.lastPathComponent
        } else {
            String(localized: "Clipboard", bundle: .module)
        }
        Task { [weak self] in
            let fallbackScale = NSScreen.main?.backingScaleFactor ?? 1
            guard let loaded = await Self.decodeImage(content, fallbackScale: fallbackScale) else {
                self?.fail(.unreadableFile)
                return
            }
            self?.openIncomingImage(loaded.image, scale: loaded.scale, source: source)
        }
        return true
    }

    /// Recognizes a dropped image file directly in this window.
    @discardableResult
    func openDroppedFile(at url: URL) -> Bool {
        guard ImageLoader.canLoad(url) else { return false }
        let source = url.lastPathComponent
        Task { [weak self] in
            guard let loaded = await Self.decodeImage(.file(url), fallbackScale: 1) else {
                self?.fail(.unreadableFile)
                return
            }
            self?.openIncomingImage(loaded.image, scale: loaded.scale, source: source)
        }
        return true
    }

    /// Recognizes dropped image data directly in this window.
    func openDroppedImageData(_ data: Data, source: String) {
        Task { [weak self] in
            let fallbackScale = NSScreen.main?.backingScaleFactor ?? 1
            guard let loaded = await Self.decodeImage(.data(data), fallbackScale: fallbackScale) else {
                self?.fail(.unreadableFile)
                return
            }
            self?.openIncomingImage(loaded.image, scale: loaded.scale, source: source)
        }
    }

    func openIncomingImage(_ image: CGImage, scale: CGFloat, source: String) {
        if let onOpenImage {
            onOpenImage(image, scale, source)
        } else {
            load(image: image, scale: scale, analyze: freshAnalyzer?() ?? makeFreshAnalyzer(), elements: elements)
        }
    }

    private func makeFreshAnalyzer() -> @Sendable (CGImage) async throws -> TextAnalysis {
        var options = VisionPipeline.Options.configured(settings.ocrLanguages)
        options.timeout = .seconds(60)
        options.overallTimeout = .seconds(60)
        let pipeline = VisionPipeline(options: options)
        return { image in try await pipeline.analyze(image) }
    }

    @concurrent private nonisolated static func decodeImage(_ content: PasteboardImage.Content, fallbackScale: CGFloat) async -> ImageLoader.Loaded? {
        switch content {
        case .file(let url): ImageLoader.load(contentsOf: url, fallbackScale: fallbackScale)
        case .data(let data): ImageLoader.load(data: data, fallbackScale: fallbackScale)
        }
    }

    private func clearResults() {
        reportedReading = false
        secondReadingTask?.cancel()
        secondReadingTask = nil
        elementsMerged = false
        translationTask?.cancel()
        translation = nil
        isTranslating = false
        translationFailed = false
        download = nil
        lines = []
        translationLines = []
        deviceFailure = nil
        visionTables = []
        codes = []
        formulas = []
        pane = .text
        tableIndex = 0
        hoveredLine = nil
        hoveredCode = nil
        // Cancelled, the reading ends its run of the text reader.
        elementReading?.cancel()
        elementReading = nil
        elementMerge?.cancel()
        elementMerge = nil
        beingRead = nil
        // Cancelled, the request stops: nothing more of the picture is sent.
        cloudTask?.cancel()
        cloudTask = nil
        cloud = .idle
        cloudOn = false
        replaceText(with: TextAssembler.Assembly())
    }

    /// The text again from what was read, in the current line-break style; the cloud model's text as it gave it while
    /// that is shown. Undoable in the editor.
    func regenerate() {
        if source == .cloud, case .read(let result) = cloud {
            replaceText(with: TextAssembler.Assembly(text: result.reading.text))
        } else {
            replaceText(with: TextAssembler.assembly(lines, options: .init(joinsWrappedLines: joinLines)))
        }
    }

    /// Drops the person's edits: the text as read, linked to the image again. Undoable in the editor.
    func revert() {
        regenerate()
    }

    private func replaceText(with assembly: TextAssembler.Assembly) {
        text = assembly.text
        lineRanges = assembly.lineRanges
        isCode = assembly.isCode
        edited = false
        selection = NSRange(location: 0, length: 0)
        items = TextDetector.items(in: text)
        revision += 1
    }

    /// The person typed: the text no longer lines up with the image, so lines stop selecting text.
    func textEdited(_ newText: String) {
        text = newText
        edited = true
        items = TextDetector.items(in: newText)
    }

    /// Lines the text selection touches; none once the text was edited.
    var selectedLines: Set<Int> {
        guard !edited, selection.length > 0 else { return [] }
        return Set(lineRanges.indices.filter { NSIntersectionRange(lineRanges[$0], selection).length > 0 })
    }

    func selectLine(_ index: Int) {
        guard !edited, lineRanges.indices.contains(index) else { return }
        selection = lineRanges[index]
        focusRequest += 1
    }

    /// The tables of the reading shown.
    var tables: [OCRTable] {
        if source == .cloud, case .read(let result) = cloud { return result.tables }
        return visionTables
    }

    var currentTable: OCRTable? {
        tables.indices.contains(tableIndex) ? tables[tableIndex] : tables.first
    }

    /// Updates a single cell in the currently displayed table (device or cloud reading).
    func updateTableCell(row: Int, column: Int, value: String) {
        guard row >= 0, column >= 0 else { return }
        let activeIndex = tables.indices.contains(tableIndex) ? tableIndex : 0
        if source == .cloud, case .read(var result) = cloud, result.tables.indices.contains(activeIndex),
           result.tables[activeIndex].rows.indices.contains(row) {
            if result.tables[activeIndex].rows[row].count <= column {
                result.tables[activeIndex].rows[row].append(contentsOf: Array(repeating: "", count: column - result.tables[activeIndex].rows[row].count + 1))
            }
            guard result.tables[activeIndex].rows[row][column] != value else { return }
            result.tables[activeIndex].rows[row][column] = value
            cloud = .read(result)
            return
        }
        guard visionTables.indices.contains(activeIndex),
              visionTables[activeIndex].rows.indices.contains(row) else { return }
        if visionTables[activeIndex].rows[row].count <= column {
            visionTables[activeIndex].rows[row].append(contentsOf: Array(repeating: "", count: column - visionTables[activeIndex].rows[row].count + 1))
        }
        guard visionTables[activeIndex].rows[row][column] != value else { return }
        visionTables[activeIndex].rows[row][column] = value
    }

    /// The panes the toolbar offers; none when there is only one.
    var panes: [Pane] {
        guard !translates, phase == .ready, !tables.isEmpty else { return [] }
        return [.text, .table]
    }

    // MARK: Formulas, tables, and charts

    /// The text reader said how many formulas and tables it found: while it reads them, the panel says so.
    private func elementsFound(_ counts: TextRecognitionWindowController.Elements.Counts, generation: Int) {
        guard generation == self.generation, elementReading != nil else { return }
        beingRead = counts.formulas + counts.tables > 0 ? counts : nil
    }

    /// Once Vision's reading is shown and the formulas, tables, and charts are read, puts them into the lines, and the
    /// text: formulas as LaTeX (`FormulaMerge`), tables and charts a row a line in place of Vision's lines and tables there
    /// where they bear themselves out (`TableMerge`). Text the person edited meanwhile stays as it is; Revert brings the
    /// text with them.
    private func putElementsIn(
        _ reading: Task<TextRecognitionWindowController.Elements.Found, Never>, with elements: TextRecognitionWindowController.Elements, image: CGImage
    ) {
        elementMerge = Task { [weak self] in
            let probe = LatencyProbe("ocr.panel-formulas")
            let started = ContinuousClock.now
            let found = await reading.value
            guard !Task.isCancelled, let self else { return }
            guard !found.formulas.isEmpty || !found.tables.isEmpty else {
                elementReading = nil
                beingRead = nil
                return
            }
            let withFormulas = found.formulas.isEmpty ? lines : await elements.merge(lines, found.formulas, image)
            probe.end()
            guard !Task.isCancelled else { return }
            translationLines = withFormulas
            var merged = withFormulas
            var taken = 0
            if !found.tables.isEmpty {
                let tables = TableMerge.merged(merged, with: found.tables, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                merged = tables.lines
                visionTables = TableMerge.tables(visionTables, after: tables)
                taken = tables.taken.count
                if tables.cutRows > 0 {
                    Log.capture.notice("OCR panel left \(tables.cutRows, privacy: .public) table rows the picture's edge cut as Vision read them")
                }
                for (index, refusal) in tables.refused {
                    Log.capture.notice("OCR panel kept Vision's reading of \(found.tables[index].kind.rawValue, privacy: .public) \(index, privacy: .public): \(refusal.rawValue, privacy: .public)")
                }
            }
            elementReading = nil
            beingRead = nil
            elementsMerged = true
            formulas = found.formulas
            Log.capture.notice("OCR panel put \(found.formulas.count, privacy: .public) formulas and \(taken, privacy: .public) of \(found.tables.count, privacy: .public) tables into its text, \(String(describing: ContinuousClock.now - started), privacy: .public) after Vision's reading")
            lines = merged
            if !edited, source == .device { regenerate() }
            if !lines.isEmpty || !visionTables.isEmpty { reportReading() }
            let wasEmpty = phase == .empty
            if wasEmpty, !lines.isEmpty { phase = .ready }
            if translates, source == .device, !edited, phase == .ready, !found.formulas.isEmpty || wasEmpty || (translation == nil && !isTranslating) {
                translate()
            }
            switch (found.formulas.isEmpty, taken == 0) {
            case (false, true): announce(String(localized: "Formulas read", bundle: .module))
            case (true, false): announce(String(localized: "Tables read", bundle: .module))
            case (false, false): announce(String(localized: "Formulas and tables read", bundle: .module))
            case (true, true): break
            }
        }
    }

    // MARK: Cloud model

    /// Whose reading the text side shows: the cloud model's while Read with is on and it found text.
    var source: TextSource {
        if cloudOn, cloudModel != nil, case .read(let result) = cloud, !result.reading.text.isEmpty { return .cloud }
        return .device
    }

    /// The toolbar's Read with. On, the picture is sent the first time (its reading is kept for the picture); off, this
    /// Mac's reading shows again, and a reading still running stops.
    var readsInCloud: Bool {
        get { cloudOn }
        set { setReadsInCloud(newValue) }
    }

    var isReadingInCloud: Bool {
        if case .reading = cloud { return true }
        return false
    }

    private func setReadsInCloud(_ on: Bool) {
        guard on != cloudOn else { return }
        guard !on || cloudModel != nil else { return }
        let before = source
        cloudOn = on
        if on {
            switch cloud {
            case .idle, .failed: startCloudReading()
            case .reading: break
            case .read:
                if source == .cloud {
                    switch phase {
                    case .empty, .failed, .loading: phase = .ready
                    case .ready: break
                    }
                }
            }
        } else if isReadingInCloud {
            cloudTask?.cancel()
            cloudTask = nil
            cloud = .idle
            if let failure = deviceFailure, phase == .loading {
                phase = failure
            }
        }
        if source != before {
            sourceChanged()
            if source == .device {
                if let failure = deviceFailure {
                    phase = failure
                } else if lines.isEmpty, codes.isEmpty, visionTables.isEmpty, phase == .ready {
                    phase = .empty
                }
            }
            if translates, phase == .ready { translate() }
        }
    }

    /// Reads the picture again with the cloud model (after a failure, truncation, empty answer, or completion).
    func retryCloudReading() {
        guard cloudOn, cloudModel != nil else { return }
        startCloudReading()
    }

    private func startCloudReading() {
        guard let setup = cloudSetup, let model = cloudModel, let image else { return }
        cloudTask?.cancel()
        cloud = .reading(characters: 0)
        let generation = generation
        cloudTask = Task { [weak self] in
            let probe = LatencyProbe("ocr.cloud")
            do {
                let reading = try await setup.read(image, model) { characters in
                    Task { @MainActor in self?.cloudProgress(characters, generation: generation) }
                }
                probe.end()
                guard !Task.isCancelled, let self, generation == self.generation else { return }
                cloudDone(reading, with: model)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self, generation == self.generation else { return }
                cloudTask = nil
                cloud = .failed(message: error.localizedDescription, canRetry: (error as? CloudReadingError)?.isWorthRetrying ?? true)
                if let failure = deviceFailure, phase == .loading {
                    phase = failure
                }
                announce(String(localized: "Couldn’t read with \(model.name)", bundle: .module))
            }
        }
    }

    private func cloudProgress(_ characters: Int, generation: Int) {
        guard generation == self.generation, isReadingInCloud else { return }
        cloud = .reading(characters: characters)
    }

    private func cloudDone(_ reading: CloudReading, with model: CloudModel) {
        cloudTask = nil
        let before = source
        cloud = .read(CloudResult(reading: reading, tables: MarkdownTables.tables(in: reading.text)))
        Log.capture.notice("OCR panel read with a cloud model: \(reading.text.count, privacy: .public) characters, \(self.tables.count, privacy: .public) tables, complete \(reading.isComplete, privacy: .public)")
        guard source == .cloud else {
            if let failure = deviceFailure, phase == .loading {
                phase = failure
            }
            announce(String(localized: "\(model.name) found no text", bundle: .module))
            return
        }
        reportReading()
        // Vision found nothing, failed, or is still running, and the cloud model succeeded.
        switch phase {
        case .empty, .failed, .loading: phase = .ready
        case .ready: break
        }
        if source != before { sourceChanged() }
        if translates, phase == .ready { translate() }
        announce(String(localized: "Read by \(model.name)", bundle: .module))
    }

    /// Device, cloud, and model-pack results for one image are one recognition.
    private func reportReading() {
        guard !reportedReading else { return }
        reportedReading = true
        onTextRecognized?()
    }

    /// The text side changed hands: the other reading's text, undoably; edits to the one shown give way.
    private func sourceChanged() {
        Log.capture.notice("OCR panel shows the text read \(self.source == .cloud ? "by the cloud model" : "on this Mac", privacy: .public)")
        tableIndex = 0
        if tables.isEmpty { pane = .text }
        hoveredLine = nil
        regenerate()
    }

    // MARK: Translation

    /// The target setting: a language as "zh-Hans", or empty for automatic. Changing it translates again.
    var translationChoice: String {
        get { settings.translationTarget }
        set {
            guard newValue != settings.translationTarget else { return }
            settings.translationTarget = newValue
            if translates { translate() }
        }
    }

    /// The same as a language, nil for automatic.
    var translationLanguage: Locale.Language? { settings.translationLanguage }

    private func translatesChanged() {
        if translates {
            if targets.isEmpty {
                Task { [weak self] in
                    let targets = await Translator.targets()
                    self?.targets = targets
                }
            }
            let wantsTextOnly = source == .cloud || edited
            let needsTranslate = translation == nil
                || translation?.choice != settings.translationTarget
                || translation?.isTextOnly != wantsTextOnly
                || (wantsTextOnly && translation?.sourceText != text)
                || translationFailed
            // Turned off and on again, the same translation is shown again when source and target are unchanged.
            if needsTranslate { translate() }
        } else {
            // A download asked for and not finished is dropped with the view that hands it to the
            // system, so turning translation on again never brings back the system's sheet unasked.
            download = nil
            if isTranslating {
                translationTask?.cancel()
                isTranslating = false
            }
        }
    }

    /// Splits text into paragraph-level units with `.zero` boxes for text-only translation (Cloud OCR / edited text).
    static func textOnlyUnits(from text: String) -> [TranslationUnit] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var paragraphs: [String] = []
        var current: [String] = []
        for rawLine in normalized.components(separatedBy: "\n") {
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(rawLine)
            }
        }
        if !current.isEmpty {
            paragraphs.append(current.joined(separator: "\n"))
        }
        return paragraphs.enumerated().map { index, paragraph in
            TranslationUnit(lines: [index], text: paragraph, box: .zero)
        }
    }

    /// Translates what was read, unit by unit. For unedited on-device readings, also draws the translation
    /// over the image; for Cloud OCR or manually edited text, runs text-only paragraph translation.
    func translate() {
        guard let image, phase == .ready else { return }
        translationTask?.cancel()
        let textOnly = source == .cloud || edited
        let snapshotText = text
        let lines = translationLines.isEmpty ? self.lines : translationLines
        let scale = scale
        // The choice as kept, so turning translation off and on again finds the same one; and as a language.
        let choice = settings.translationTarget
        let target = settings.translationLanguage
        let translator = translator
        translation = nil
        isTranslating = true
        translationFailed = false
        translationTask = Task { [weak self] in
            let probe = LatencyProbe("ocr.translate")
            do {
                let units = textOnly ? Self.textOnlyUnits(from: snapshotText) : TranslationUnits.group(lines, image: image)
                let outcome = try await translator.translate(units, to: target)
                let rendering: TranslationOverlay.Rendering? = (textOnly || outcome.translations.isEmpty) ? nil : await TranslationOverlay.render(
                    image, lines: lines, units: units, translations: outcome.translations, language: outcome.target, scale: scale
                )
                probe.end()
                guard !Task.isCancelled, let self else { return }
                let (text, translated) = Translator.text(of: units, outcome)
                translation = Translation(
                    choice: choice, outcome: outcome, units: units, text: text, translated: translated,
                    image: rendering?.image, isTextOnly: textOnly, sourceText: textOnly ? snapshotText : nil
                )
                isTranslating = false
                Log.capture.notice("OCR panel translated \(outcome.translations.count, privacy: .public) of \(units.count, privacy: .public) units into \(outcome.target.minimalIdentifier, privacy: .public) (textOnly: \(textOnly, privacy: .public)); \(outcome.inTarget.count, privacy: .public) already in it, \(outcome.needsDownload.count, privacy: .public) languages to download, \(rendering?.truncated.count ?? 0, privacy: .public) shortened")
                if !outcome.translations.isEmpty {
                    announce(String(localized: "Translated into \(Translator.name(of: outcome.target))", bundle: .module))
                }
            } catch {
                guard !Task.isCancelled else { return }
                Log.capture.error("OCR panel translation failed: \(String(describing: error), privacy: .public)")
                self?.isTranslating = false
                self?.translationFailed = true
            }
        }
    }

    /// Asks the system to download `language` for the current target. It shows its own sheet first.
    func requestDownload(_ language: Locale.Language) {
        download = TranslationSession.Configuration(source: language, target: translation?.outcome.target)
    }

    /// The session the system made for a download: once the language is in, translates again. Declined
    /// or failed, the Download button stays.
    func prepare(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            download = nil
            translate()
        } catch {
            Log.capture.notice("Language download not completed: \(String(describing: error), privacy: .public)")
            download = nil
        }
    }

    /// "English → Chinese, Simplified".
    var translationSummary: String? {
        guard let outcome = translation?.outcome, !outcome.sources.isEmpty else { return nil }
        let sources = ListFormatter.localizedString(byJoining: outcome.sources.map { Translator.name(of: $0) })
        return "\(sources) → \(Translator.name(of: outcome.target))"
    }

    /// The same for VoiceOver, which reads the arrow as "right arrow".
    var spokenTranslationSummary: String? {
        guard let outcome = translation?.outcome, !outcome.sources.isEmpty else { return nil }
        let sources = ListFormatter.localizedString(byJoining: outcome.sources.map { Translator.name(of: $0) })
        return String(localized: "Translated from \(sources) to \(Translator.name(of: outcome.target))", bundle: .module)
    }

    // MARK: Found items

    func action(for item: DetectedItem) -> Action? {
        switch item.kind {
        case .link:
            item.url.map { url in Action(title: Text("Open Link", bundle: .module), symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(url) } }
        case .email:
            item.url.map { url in Action(title: Text("New Email", bundle: .module), symbol: "square.and.pencil") { NSWorkspace.shared.open(url) } }
        case .phone:
            item.url.map { url in Action(title: Text("Call", bundle: .module), symbol: "phone.arrow.up.right") { NSWorkspace.shared.open(url) } }
        case .address:
            item.url.map { url in Action(title: Text("Show in Maps", bundle: .module), symbol: "map") { NSWorkspace.shared.open(url) } }
        case .date:
            item.date == nil ? nil : Action(title: Text("Add to Calendar", bundle: .module), symbol: "calendar.badge.plus") { [weak self] in
                self?.addToCalendar(item)
            }
        }
    }

    /// Action for a recognized QR/barcode based on its structured payload (`FoundCode.structured`).
    /// Only allowlisted safe schemes (`http`, `https`, `mailto`, `tel`) are opened.
    func action(for code: OCRCode) -> Action? {
        let found = FoundCode(payload: code.payload, isMatrix: code.kind.isMatrix, box: code.box)
        switch found.structured {
        case .web(let url):
            return Action(title: Text("Open Link", bundle: .module), symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
        case .mailto(_, _, let url):
            return Action(title: Text("Open Mail", bundle: .module), symbol: "envelope") { NSWorkspace.shared.open(url) }
        case .phone(_, let url):
            return Action(title: Text("Call", bundle: .module), symbol: "phone.arrow.up.right") { NSWorkspace.shared.open(url) }
        case .wifi(_, let password?, _, _) where !password.isEmpty:
            return Action(title: Text("Copy Password", bundle: .module), symbol: "key") { [weak self] in
                self?.copy(password)
            }
        case .wifi, .contact, nil:
            return nil
        }
    }

    /// Opens a one-event calendar file (`CalendarEvent`), which Calendar offers to add; no calendar access is needed.
    func addToCalendar(_ item: DetectedItem) {
        guard let event = CalendarEvent(for: item, in: text) else { return }
        let file = FileManager.default.temporaryDirectory.appending(path: "OhMyShot-\(UUID().uuidString).ics")
        do {
            try event.iCalendar().write(to: file, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(file)
        } catch {
            Log.capture.error("Could not write the calendar event: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    // MARK: Copying and translated image export

    /// Rendered translated overlay image when showing an image translation.
    var translatedImage: CGImage? {
        translates ? translation?.image : nil
    }

    var canPinImage: Bool {
        onPinImage != nil || TextRecognitionWindowController.onPinImage != nil
    }

    func copyTranslatedImage() {
        guard let image = translatedImage,
              let png = try? ImageExporter.encoded(image, as: .png, pixelsPerPoint: Double(scale))
        else {
            NSSound.beep()
            return
        }
        PasteboardWriter.write(png: png, image: image, to: pasteboard)
        flashCopied(String(localized: "Translated image copied", bundle: .module))
    }

    func saveTranslatedImage() {
        guard let image = translatedImage else { return }
        let scale = scale
        let directory = settings.exportDirectory
        Task { [weak self] in
            let url = await SavePanel.ask(
                name: String(localized: "Translated Image", bundle: .module),
                types: [.png, .jpeg, .heic],
                directory: directory
            )
            guard let url else { return }
            let format: ImageExporter.Format = switch url.pathExtension.lowercased() {
            case "jpg", "jpeg": .jpeg
            case "heic", "heif": .heic
            default: .png
            }
            do {
                try await ImageExporter.write(image, to: url, format: format, pixelsPerPoint: Double(scale))
                self?.announce(String(localized: "Translated image saved", bundle: .module))
            } catch {
                NSSound.beep()
            }
        }
    }

    func pinTranslatedImage() {
        guard let image = translatedImage, let pin = onPinImage ?? TextRecognitionWindowController.onPinImage else { return }
        pin(image, scale)
    }

    /// Formats a LaTeX formula with the configured `formulaDelimiter` and copies it to the clipboard.
    func copyFormula(_ latex: String) {
        let wrapped = formulaDelimiter().wrap(latex)
        guard !wrapped.isEmpty else { return }
        write { $0.setString(wrapped, forType: .string) }
        flashCopied(String(localized: "Copied", bundle: .module))
    }

    /// Returns `text` formatted for clipboard copy, applying `formulaDelimiter` consistently to recognized math lines.
    func formattedTextForCopy() -> String {
        Self.formatFormulas(in: text, lines: lines, edited: edited || source == .cloud, delimiter: formulaDelimiter())
    }

    static func formatFormulas(in text: String, lines: [OCRLine], edited: Bool, delimiter: FormulaDelimiter) -> String {
        guard !edited, lines.contains(where: { $0.math != nil }) else { return text }
        let nonEmpty = text.split(separator: "\n", omittingEmptySubsequences: true)
        let pureFormulaLines = !nonEmpty.isEmpty && nonEmpty.allSatisfy { Self.unwrappedMath(String($0)) != nil }
        if pureFormulaLines {
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { segment -> String in
                    if let inner = Self.unwrappedMath(String(segment)) {
                        return delimiter.wrap(inner)
                    }
                    return String(segment)
                }
                .joined(separator: "\n")
        }
        guard delimiter != .raw else { return text }
        guard let regex = try? NSRegularExpression(pattern: #"\$\$(.+?)\$\$|\$([^$\n]+?)\$"#) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            let innerRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            let inner = ns.substring(with: innerRange)
            result += delimiter.wrap(inner)
            cursor = NSMaxRange(match.range)
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    private static func unwrappedMath(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count >= 4 {
            return String(trimmed.dropFirst(2).dropLast(2))
        }
        if trimmed.hasPrefix("$"), trimmed.hasSuffix("$"), trimmed.count >= 2,
           !trimmed.dropFirst().dropLast().contains("$") {
            return String(trimmed.dropFirst().dropLast())
        }
        if trimmed.hasPrefix(#"\("#), trimmed.hasSuffix(#"\)"#), trimmed.count >= 4 {
            return String(trimmed.dropFirst(2).dropLast(2))
        }
        return nil
    }

    func copyText() {
        guard !text.isEmpty else { return }
        let output = formattedTextForCopy()
        write { $0.setString(output, forType: .string) }
        flashCopied(String(localized: "Copied", bundle: .module))
    }

    func copyTranslation() {
        guard let translation, !translation.outcome.translations.isEmpty else { return }
        write { $0.setString(translation.text, forType: .string) }
        flashCopied(String(localized: "Translation copied", bundle: .module))
    }

    /// What the toolbar's Copy does now: the translation, the table, or the text.
    var canCopy: Bool {
        guard phase == .ready else { return false }
        if translates {
            return translation.map { !$0.outcome.translations.isEmpty } ?? false
        }
        if pane == .table {
            return currentTable != nil
        }
        return !text.isEmpty
    }

    func copyShown() {
        if translates {
            copyTranslation()
        } else if pane == .table {
            copyTable()
        } else {
            copyText()
        }
    }

    /// The table as spreadsheets paste it (tab-separated and HTML), with Markdown as its plain text.
    func copyTable() {
        guard let table = currentTable else { return }
        write { item in
            item.setString(table.tsv, forType: NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text"))
            item.setString(table.html, forType: .html)
            item.setString(table.markdown, forType: .string)
        }
        flashCopied(String(localized: "Table copied", bundle: .module))
    }

    func copyTable(as format: TableFormat) {
        guard let table = currentTable else { return }
        let output: String = switch format {
        case .markdown: table.markdown
        case .csv: table.csv
        case .tsv: table.tsv
        }
        write { item in
            if format == .tsv {
                item.setString(output, forType: NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text"))
            }
            item.setString(output, forType: .string)
        }
        flashCopied(String(localized: "Table copied", bundle: .module))
    }

    /// Exports the current table as an RFC-4180 CSV file via `NSSavePanel`.
    func exportTableCSV() {
        guard let table = currentTable else { return }
        let csv = table.csv
        let directory = settings.exportDirectory
        Task { [weak self] in
            let url = await SavePanel.ask(
                name: String(localized: "Table", bundle: .module),
                types: [.commaSeparatedText],
                directory: directory
            )
            guard let url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                self?.announce(String(localized: "Table exported as CSV", bundle: .module))
            } catch {
                Log.capture.error("Could not export table as CSV: \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    func copy(_ string: String) {
        write { $0.setString(string, forType: .string) }
        announce(String(localized: "Copied", bundle: .module))
    }

    private func write(_ fill: (NSPasteboardItem) -> Void) {
        let item = NSPasteboardItem()
        fill(item)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    private func flashCopied(_ announcement: String) {
        copied = true
        announce(announcement)
        copiedReset?.cancel()
        copiedReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }

    /// Copying changes nothing on screen but a symbol; VoiceOver hears it.
    private func announce(_ message: String) {
        guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        VoiceOver.announce(message, from: window)
    }
}

public extension TextRecognitionWindowController {
    /// Optional async L2 refinement run after Vision returns, so the panel shows Vision immediately and
    /// swaps in L2's refined lines without blocking initial display.
    @MainActor static var secondReadingRefiner: (@Sendable (CGImage, [OCRLine]) async -> [OCRLine])?
    /// Optional pin action wired by the app to float a rendered translated image.
    @MainActor static var onPinImage: ((CGImage, CGFloat) -> Void)?
    @MainActor private static var pendingCloudReading: CloudReading?

    /// Seeds a Cloud OCR reading already fetched by Capture Text for the next image loaded into the panel,
    /// avoiding a duplicate cloud API request.
    @MainActor static func seedNextCloudReading(_ reading: CloudReading?) {
        pendingCloudReading = reading
    }

    @MainActor internal static func consumePendingCloudReading() -> CloudReading? {
        defer { pendingCloudReading = nil }
        return pendingCloudReading
    }
}
