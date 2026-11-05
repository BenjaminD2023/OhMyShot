import AppKit
import OMSDesign
import Observation
import OMSCore
import OMSOCR
import OSLog
import SwiftUI
// The framework predates strict concurrency; its sessions are handed to the view that asked for them.
@preconcurrency import Translation

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
        let tables: [OCRTable]
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
        /// The image with the translation drawn over its text; nil when nothing was translated.
        let image: CGImage?
    }

    /// What a found item's button does, named for what the item is.
    struct Action {
        let title: Text
        let symbol: String
        let perform: () -> Void
    }

    private(set) var image: CGImage?
    private(set) var scale: CGFloat = 1
    private(set) var phase: Phase = .loading
    private(set) var lines: [OCRLine] = []
    /// The tables Vision read.
    private(set) var visionTables: [OCRTable] = []
    private(set) var codes: [OCRCode] = []
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

    /// The cloud model the toolbar's Read with reads with, when one is set up and can read; looked up as each picture
    /// opens (its key is in the Keychain).
    private(set) var cloudModel: CloudModel?
    /// Whether Read with is on: the text side shows the cloud model's reading once it has come.
    private(set) var cloudOn = false
    /// Where reading with the cloud model stands for this picture.
    private(set) var cloud: CloudState = .idle
    @ObservationIgnored let cloudSetup: TextRecognitionWindowController.Cloud?
    @ObservationIgnored var cloudTask: Task<Void, Never>?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let translator: Translator
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var analyze: (@Sendable (CGImage) async throws -> TextAnalysis)?
    @ObservationIgnored private var analysis: Task<Void, Never>?
    @ObservationIgnored private var copiedReset: Task<Void, Never>?
    @ObservationIgnored private var elements: TextRecognitionWindowController.Elements?
    /// Finds and reads the formulas, tables, and charts, from the time the image is shown, beside Vision's reading.
    @ObservationIgnored private var elementReading: Task<TextRecognitionWindowController.Elements.Found, Never>?
    /// Puts them into the text once both are done.
    @ObservationIgnored private var elementMerge: Task<Void, Never>?
    /// Counts the images loaded, so word from a reading of an earlier one is let go.
    @ObservationIgnored private var generation = 0

    init(settings: SettingsStore, translator: Translator, cloud: TextRecognitionWindowController.Cloud? = nil, pasteboard: NSPasteboard = .general) {
        self.settings = settings
        self.translator = translator
        self.pasteboard = pasteboard
        joinLines = !settings.textRecognitionKeepsLineBreaks
        wrapsText = settings.textRecognitionWrapsText
        cloudSetup = cloud
    }

    func load(
        image: CGImage, scale: CGFloat, analyze: @escaping @Sendable (CGImage) async throws -> TextAnalysis,
        elements: TextRecognitionWindowController.Elements? = nil
    ) {
        analysis?.cancel()
        self.analyze = analyze
        self.elements = elements
        self.image = image
        self.scale = max(scale, 1)
        phase = .loading
        clearResults()
        generation += 1
        let generation = generation
        cloudModel = cloudSetup?.store.usableModel
        // Read with the cloud model from the start, beside Vision, when Settings says every picture is.
        if cloudModel != nil, cloudSetup?.store.readsInPanel == true { readsInCloud = true }
        let reading = elements.map { elements in
            Task { [weak self] in
                await elements.read(image) { counts in
                    Task { @MainActor in self?.elementsFound(counts, generation: generation) }
                }
            }
        }
        elementReading = reading
        analysis = Task { [weak self] in
            let probe = LatencyProbe("ocr.analyze")
            do {
                let result = try await analyze(image)
                probe.end()
                guard !Task.isCancelled, let self else { return }
                lines = result.result.lines
                visionTables = result.tables
                codes = result.codes
                regenerate()
                let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                phase = hasText || !codes.isEmpty || !visionTables.isEmpty || source == .cloud ? .ready : .empty
                if translates, phase == .ready { translate() }
                Log.capture.notice("OCR panel read \(self.lines.count, privacy: .public) lines, \(self.visionTables.count, privacy: .public) tables, \(self.codes.count, privacy: .public) codes, \(self.items.count, privacy: .public) links and contacts")
                if let reading, let elements { putElementsIn(reading, with: elements, image: image) }
            } catch {
                guard !Task.isCancelled else { return }
                reading?.cancel()
                self?.beingRead = nil
                // The details go to the log; the panel says what they mean.
                Log.capture.error("OCR panel failed: \(String(describing: error), privacy: .public)")
                self?.phase = .failed(
                    title: String(localized: "Couldn’t read this image", bundle: .module),
                    message: error as? OCRError == .timedOut
                        ? String(localized: "Reading it took too long.", bundle: .module)
                        : String(localized: "The text in it couldn’t be recognized.", bundle: .module),
                    canRetry: true
                )
            }
        }
    }

    /// Reads the same image again.
    func retry() {
        guard let image, let analyze else { return }
        load(image: image, scale: scale, analyze: analyze, elements: elements)
    }

    func fail(_ failure: TextRecognitionWindowController.OpenFailure) {
        analysis?.cancel()
        analyze = nil
        elements = nil
        image = nil
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
        clearResults()
    }

    private func clearResults() {
        translationTask?.cancel()
        translation = nil
        isTranslating = false
        translationFailed = false
        download = nil
        lines = []
        visionTables = []
        codes = []
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
            var merged = found.formulas.isEmpty ? lines : await elements.merge(lines, found.formulas, image)
            probe.end()
            guard !Task.isCancelled else { return }
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
            Log.capture.notice("OCR panel put \(found.formulas.count, privacy: .public) formulas and \(taken, privacy: .public) of \(found.tables.count, privacy: .public) tables into its text, \(String(describing: ContinuousClock.now - started), privacy: .public) after Vision's reading")
            lines = merged
            if !edited { regenerate() }
            if phase == .empty, !lines.isEmpty { phase = .ready }
            if translates, phase == .ready { translate() }
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
        if cloudOn, case .read(let result) = cloud, !result.reading.text.isEmpty { return .cloud }
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
            // The translation works on this Mac's reading, with its boxes; the cloud model's has none.
            if translates { translates = false }
            switch cloud {
            case .idle, .failed: startCloudReading()
            case .reading, .read: break
            }
        } else if isReadingInCloud {
            cloudTask?.cancel()
            cloudTask = nil
            cloud = .idle
        }
        if source != before { sourceChanged() }
    }

    /// Reads the picture again after a failure.
    func retryCloudReading() {
        guard cloudOn else { return }
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
            announce(String(localized: "\(model.name) found no text", bundle: .module))
            return
        }
        // Vision found nothing, but the model did.
        if phase == .empty { phase = .ready }
        if source != before { sourceChanged() }
        announce(String(localized: "Read by \(model.name)", bundle: .module))
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
            if cloudOn { readsInCloud = false }
            if targets.isEmpty {
                Task { [weak self] in
                    let targets = await Translator.targets()
                    self?.targets = targets
                }
            }
            // Turned off and on again, the same translation is shown again.
            if translation?.choice != settings.translationTarget || translationFailed { translate() }
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

    /// Translates what was read, unit by unit, and draws the translation over the image.
    func translate() {
        guard let image, phase == .ready else { return }
        translationTask?.cancel()
        let lines = lines
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
                let units = TranslationUnits.group(lines)
                let outcome = try await translator.translate(units, to: target)
                let rendering = outcome.translations.isEmpty ? nil : await TranslationOverlay.render(
                    image, lines: lines, units: units, translations: outcome.translations, language: outcome.target, scale: scale
                )
                probe.end()
                guard !Task.isCancelled, let self else { return }
                let (text, translated) = Translator.text(of: units, outcome)
                translation = Translation(choice: choice, outcome: outcome, units: units, text: text, translated: translated, image: rendering?.image)
                isTranslating = false
                Log.capture.notice("OCR panel translated \(outcome.translations.count, privacy: .public) of \(units.count, privacy: .public) units into \(outcome.target.minimalIdentifier, privacy: .public); \(outcome.inTarget.count, privacy: .public) already in it, \(outcome.needsDownload.count, privacy: .public) languages to download, \(rendering?.truncated.count ?? 0, privacy: .public) shortened")
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

    /// Only web links open from a code (`OCRCode.webURL`).
    func action(for code: OCRCode) -> Action? {
        guard let url = code.webURL else { return nil }
        return Action(title: Text("Open Link", bundle: .module), symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
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

    // MARK: Copying

    func copyText() {
        write { $0.setString(self.text, forType: .string) }
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
        guard translates else { return true }
        return translation.map { !$0.outcome.translations.isEmpty } ?? false
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
        write { $0.setString(format == .markdown ? table.markdown : table.csv, forType: .string) }
        flashCopied(String(localized: "Table copied", bundle: .module))
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
