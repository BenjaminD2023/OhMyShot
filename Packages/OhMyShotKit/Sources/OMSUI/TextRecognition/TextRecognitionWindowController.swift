import AppKit
import Observation
import OMSCore
import OMSOCR
import OSLog
import SwiftUI
// The framework predates strict concurrency; its sessions are handed to the view that asked for them.
@preconcurrency import Translation

/// The OCR panel: the image on the left with what was read outlined on it, the text on the right,
/// editable and in the line-break style of choice, with tables, links, contacts, and codes; translated,
/// the image shows the translation in place of its text and the right side the translated text. One
/// window, reused for each new image, created when opened and released when closed.
public final class TextRecognitionWindowController: NSWindowController, NSWindowDelegate {
    /// Why an image never reached the panel. The panel says so instead of a bare beep.
    public enum OpenFailure: Sendable {
        /// The file is not an image that can be decoded.
        case unreadableFile
        /// The clipboard holds no image.
        case noImageOnClipboard
    }

    public var onClose: (() -> Void)?

    private let model: TextRecognitionModel
    private var windowLease: ActiveResources.Lease?

    /// `translator` is shared, so a language pair's model, slow to load, stays ready from image to image.
    public init(settings: SettingsStore, translator: Translator) {
        model = TextRecognitionModel(settings: settings, translator: translator)
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
    /// `translating` turns the translation on for it (Translate Area's Open in Panel).
    public func show(
        image: CGImage, scale: CGFloat, source: String, translating: Bool = false,
        analyze: @escaping @Sendable (CGImage) async throws -> TextAnalysis
    ) {
        model.load(image: image, scale: scale, analyze: analyze)
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
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
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
    public func preview(pane: String?, joinLines: Bool?, selectLine: Int?, hoverLine: Int?, edited: Bool, translate: Bool? = nil, target: String? = nil) {
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
    private(set) var tables: [OCRTable] = []
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
    var joinLines = false {
        didSet { if joinLines != oldValue { regenerate() } }
    }

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

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let translator: Translator
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var analyze: (@Sendable (CGImage) async throws -> TextAnalysis)?
    @ObservationIgnored private var analysis: Task<Void, Never>?
    @ObservationIgnored private var copiedReset: Task<Void, Never>?

    init(settings: SettingsStore, translator: Translator) {
        self.settings = settings
        self.translator = translator
    }

    func load(image: CGImage, scale: CGFloat, analyze: @escaping @Sendable (CGImage) async throws -> TextAnalysis) {
        analysis?.cancel()
        self.analyze = analyze
        self.image = image
        self.scale = max(scale, 1)
        phase = .loading
        clearResults()
        analysis = Task { [weak self] in
            let probe = LatencyProbe("ocr.analyze")
            do {
                let result = try await analyze(image)
                probe.end()
                guard !Task.isCancelled, let self else { return }
                lines = result.result.lines
                tables = result.tables
                codes = result.codes
                regenerate()
                let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                phase = hasText || !codes.isEmpty || !tables.isEmpty ? .ready : .empty
                if translates, phase == .ready { translate() }
                Log.capture.notice("OCR panel read \(self.lines.count, privacy: .public) lines, \(self.tables.count, privacy: .public) tables, \(self.codes.count, privacy: .public) codes, \(self.items.count, privacy: .public) links and contacts")
            } catch {
                guard !Task.isCancelled else { return }
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
        load(image: image, scale: scale, analyze: analyze)
    }

    func fail(_ failure: TextRecognitionWindowController.OpenFailure) {
        analysis?.cancel()
        analyze = nil
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
        tables = []
        codes = []
        pane = .text
        tableIndex = 0
        hoveredLine = nil
        hoveredCode = nil
        replaceText(with: TextAssembler.Assembly())
    }

    /// The text again from what was read, in the current line-break style. Undoable in the editor.
    private func regenerate() {
        replaceText(with: TextAssembler.assembly(lines, options: .init(joinsWrappedLines: joinLines)))
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

    var currentTable: OCRTable? {
        tables.indices.contains(tableIndex) ? tables[tableIndex] : tables.first
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

    private func translatesChanged() {
        if translates {
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
        let choice = settings.translationTarget
        let target = choice.isEmpty ? nil : Locale.Language(identifier: choice)
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

    /// Only web links open from a code: a code can carry any URL scheme, and a picture is no reason to
    /// launch whatever app claims it.
    func action(for code: OCRCode) -> Action? {
        guard let url = URL(string: code.payload), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return Action(title: Text("Open Link", bundle: .module), symbol: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
    }

    /// Opens a one-event calendar file, which Calendar offers to add; no calendar access is needed. The
    /// event is named after the line the date is on.
    func addToCalendar(_ item: DetectedItem) {
        guard let date = item.date else { return }
        let string = text as NSString
        let line = NSMaxRange(item.range) <= string.length ? string.substring(with: string.lineRange(for: item.range)) : item.text
        let title = String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let hasTime = item.text.range(of: #"\d\s*[:：]\s*\d|(?i)\b[ap]\.?m\b|[点點时時]"#, options: .regularExpression) != nil
        func stamp(_ date: Date, _ format: String, utc: Bool) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = utc ? TimeZone(identifier: "UTC") : .current
            formatter.dateFormat = format
            return formatter.string(from: date)
        }
        let span = hasTime
            ? ["DTSTART:" + stamp(date, "yyyyMMdd'T'HHmmss'Z'", utc: true), "DTEND:" + stamp(date.addingTimeInterval(3600), "yyyyMMdd'T'HHmmss'Z'", utc: true)]
            : ["DTSTART;VALUE=DATE:" + stamp(date, "yyyyMMdd", utc: false), "DTEND;VALUE=DATE:" + stamp(date.addingTimeInterval(86400), "yyyyMMdd", utc: false)]
        let summary = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
        let calendar = (["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//OhMyShot//OCR Panel//EN", "BEGIN:VEVENT",
                         "UID:\(UUID().uuidString)", "DTSTAMP:" + stamp(.now, "yyyyMMdd'T'HHmmss'Z'", utc: true)]
            + span + ["SUMMARY:\(summary)", "END:VEVENT", "END:VCALENDAR"]).joined(separator: "\r\n") + "\r\n"
        let file = FileManager.default.temporaryDirectory.appending(path: "OhMyShot-\(UUID().uuidString).ics")
        do {
            try calendar.write(to: file, atomically: true, encoding: .utf8)
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
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
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}

struct TextRecognitionView: View {
    @Bindable var model: TextRecognitionModel

    var body: some View {
        Group {
            if model.image == nil {
                // Nothing to show on the left (a file that is no image): the message takes the window.
                TextPane(model: model)
            } else {
                HSplitView {
                    RecognizedImagePane(model: model)
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    TextPane(model: model)
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: 560, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .toolbar { toolbar }
    }

    /// The text side's controls, together over it: what to show, how lines break (text only), Translate
    /// and the language it goes into, and one Copy that is always last.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if model.phase == .ready, !model.tables.isEmpty, !model.translates {
            ToolbarItem(placement: .primaryAction) {
                Picker(selection: $model.pane) {
                    Text("Text", bundle: .module).tag(TextRecognitionModel.Pane.text)
                    Text("Table", bundle: .module).tag(TextRecognitionModel.Pane.table)
                } label: {
                    Text("Show", bundle: .module)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(Text("Show the text, or the table found in the image", bundle: .module))
            }
        }
        if model.phase == .ready, model.pane == .text, !model.translates {
            ToolbarItem(placement: .primaryAction) {
                // Code always keeps its line breaks, whatever was chosen for the last image.
                Picker(selection: Binding(get: { model.joinLines && !model.isCode }, set: { model.joinLines = $0 })) {
                    Text("Keep Line Breaks", bundle: .module).tag(false)
                    Text("Join Lines", bundle: .module).tag(true)
                } label: {
                    Text("Line Breaks", bundle: .module)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help(model.isCode
                    ? Text("Code keeps its line breaks", bundle: .module)
                    : Text("Keep the lines as they are in the image, or join the lines of each paragraph", bundle: .module))
                .disabled(model.isCode)
            }
        }
        // A mode, not an action: the symbol alone, so Copy stays the one titled, filled control.
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.translates) {
                Label {
                    Text("Translate", bundle: .module)
                } icon: {
                    Image(systemName: "translate")
                }
                .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(model.phase != .ready && model.phase != .loading)
            .help(model.translates
                ? Text("Show the text as read (⇧⌘T)", bundle: .module)
                : Text("Translate the text, and show the translation in the image (⇧⌘T)", bundle: .module))
            if model.translates, model.phase == .ready {
                // A short label that never changes under the pointer; the menu names what Automatic chose.
                Menu {
                    Picker(selection: $model.translationChoice) {
                        automaticTarget.tag("")
                        Divider()
                        ForEach(targetOptions, id: \.self) { identifier in
                            Text(verbatim: Translator.name(of: Locale.Language(identifier: identifier))).tag(identifier)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    model.translationChoice.isEmpty
                        ? Text("Automatic", bundle: .module)
                        : Text(verbatim: Translator.name(of: Locale.Language(identifier: model.translationChoice)))
                }
                .fixedSize()
                .help(Text("The language to translate into", bundle: .module))
                .accessibilityLabel(Text("Translate Into", bundle: .module))
            }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            copyControl
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!model.canCopy)
        }
    }

    /// Automatic, with the language it chose once there is a translation.
    private var automaticTarget: Text {
        if let translation = model.translation, translation.choice.isEmpty {
            Text("Automatic: \(Translator.name(of: translation.outcome.target))", bundle: .module)
        } else {
            Text("Automatic", bundle: .module)
        }
    }

    /// The languages to choose from, by identifier; the chosen one even before the list has loaded, so
    /// the menu never shows a choice it does not have.
    private var targetOptions: [String] {
        var options = model.targets.map(Translator.identifier(of:))
        let choice = model.translationChoice
        if !choice.isEmpty, !options.contains(choice) { options.insert(choice, at: 0) }
        return options
    }

    private var copyLabel: some View {
        Label {
            model.copied ? Text("Copied", bundle: .module) : Text("Copy", bundle: .module)
        } icon: {
            Image(systemName: model.copied ? "checkmark" : "doc.on.doc")
        }
        .labelStyle(.titleAndIcon)
    }

    /// One prominent Copy for every pane; the table's other formats sit with the table.
    private var copyControl: some View {
        Button {
            model.copyShown()
        } label: {
            copyLabel
        }
        .buttonStyle(.glassProminent)
        .help(copyHelp)
    }

    private var copyHelp: Text {
        if model.translates {
            Text("Copy the translation (⇧⌘C)", bundle: .module)
        } else if model.pane == .table {
            Text("Copy the table; it pastes into Numbers and Excel as cells (⇧⌘C)", bundle: .module)
        } else {
            Text("Copy all the text (⇧⌘C)", bundle: .module)
        }
    }
}

/// The image as a picture card (12 pt corners, a hairline, the in-window shadow), fitted to the pane
/// and never drawn larger than it appeared on screen, with each line that was read outlined on hover
/// and filled like selected text when its text is selected. Translated, it shows the translation drawn
/// over the text instead, and nothing over it.
struct RecognizedImagePane: View {
    let model: TextRecognitionModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if let original = model.image {
                let translated = model.translates ? model.translation?.image : nil
                let image = original
                let size = CGSize(width: image.width, height: image.height)
                let area = geometry.size
                let factor = max(min((area.width - 48) / size.width, (area.height - 48) / size.height, 1 / model.scale), 0.01)
                // Whole points, so the boxes on it land on whole points too.
                let fitted = CGSize(width: max(1, (size.width * factor).rounded(.down)), height: max(1, (size.height * factor).rounded(.down)))
                let toView = CGAffineTransform(scaleX: fitted.width / size.width, y: fitted.height / size.height)
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                    // The page changing language: the translation fades in over the original.
                    if let translated {
                        Image(decorative: translated, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fitted.width, height: fitted.height)
                            .transition(.opacity)
                    }
                    if model.phase == .ready, !model.translates {
                        overlays(toView)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: translated != nil)
                .frame(width: fitted.width, height: fitted.height)
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(
                        colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10),
                        lineWidth: contrast == .increased ? 1 : 0.5
                    )
                }
                .background { shape.fill(.background).shadow(color: .black.opacity(0.12), radius: 10, y: 4) }
                .offset(x: ((area.width - fitted.width) / 2).rounded(), y: ((area.height - fitted.height) / 2).rounded())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(translated == nil
                    ? Text("The image being read", bundle: .module)
                    : Text("The image, with the translation over its text", bundle: .module))
                .accessibilityValue(model.phase == .ready ? Text("\(model.lines.count) lines of text", bundle: .module) : Text(verbatim: ""))
            }
        }
        .background(.background.secondary)
    }

    /// Lines in the text pane (once the text is edited they no longer match, so they stop reacting) and
    /// codes, which light up while hovered here or in the Found list.
    @ViewBuilder private func overlays(_ toView: CGAffineTransform) -> some View {
        // Snapshots: the closures below run lazily, after a new image may have emptied the model's arrays.
        let lines = model.lines
        let codes = model.codes
        if model.pane == .text {
            let selected = model.selectedLines
            let linked = !model.edited
            ForEach(lines.indices, id: \.self) { index in
                LineBox(
                    rect: lines[index].box.applying(toView).integral,
                    isSelected: selected.contains(index),
                    isHovered: linked && model.hoveredLine == index,
                    isActive: model.editorIsActive
                )
                .onHover { inside in
                    if inside { model.hoveredLine = index } else if model.hoveredLine == index { model.hoveredLine = nil }
                }
                .onTapGesture { model.selectLine(index) }
            }
        }
        ForEach(codes.indices, id: \.self) { index in
            LineBox(rect: codes[index].box.applying(toView).integral, isSelected: false, isHovered: model.hoveredCode == index, isActive: true)
                .onHover { inside in
                    if inside { model.hoveredCode = index } else if model.hoveredCode == index { model.hoveredCode = nil }
                }
        }
    }
}

/// A region read from the image, drawn like selected text (DESIGN.md › Text Selection): the selection
/// color at 0.35 (0.45 in Dark) edged with a 1 pt accent line, 2 pt under Increase Contrast. Hovered,
/// it is only outlined: the accent never fills behind text. When the editor is not active, the box
/// takes the inactive selection color, as the text does.
struct LineBox: View {
    let rect: CGRect
    let isSelected: Bool
    let isHovered: Bool
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let selection = Color(nsColor: isActive ? .selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor)
        Rectangle()
            .fill(isSelected ? selection.opacity(colorScheme == .dark ? 0.45 : 0.35) : Color.clear)
            .overlay {
                if isSelected || isHovered {
                    Rectangle().strokeBorder(isActive || isHovered ? Color.accentColor : Color.secondary, lineWidth: contrast == .increased ? 2 : 1)
                }
            }
            .frame(width: max(rect.width, 2), height: max(rect.height, 2))
            .contentShape(Rectangle())
            .offset(x: rect.minX, y: rect.minY)
    }
}

/// The right side: the text (or a table), then what can be acted on.
struct TextPane: View {
    @Bindable var model: TextRecognitionModel

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .loading:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Recognizing text…", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                PanelPlaceholder(
                    symbol: "text.magnifyingglass",
                    title: Text("No text found", bundle: .module),
                    message: Text("Try an image with larger text or more contrast.", bundle: .module)
                )
            case .failed(let title, let message, let canRetry):
                PanelPlaceholder(symbol: "exclamationmark.triangle", title: Text(verbatim: title), message: Text(verbatim: message)) {
                    if canRetry {
                        Button { model.retry() } label: { Text("Try Again", bundle: .module) }
                            .padding(.top, 6)
                    }
                }
            case .ready:
                if model.translates {
                    TranslationPane(model: model)
                } else if model.pane == .table, let table = model.currentTable {
                    TablePreview(model: model, table: table)
                } else {
                    RecognizedTextEditor(model: model)
                    if model.edited {
                        EditedNotice(model: model)
                    }
                }
                if !model.items.isEmpty || !model.codes.isEmpty {
                    Divider()
                    FoundList(model: model)
                }
            }
        }
        .background(.background)
    }
}

/// The panel's empty, failed, and translation states, as in Capture History: a 40 pt light tertiary
/// symbol, a title3 title, a callout message at most 360 pt wide, then any actions.
struct PanelPlaceholder<Actions: View>: View {
    let symbol: String
    let title: Text
    let message: Text
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            title
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            message
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            actions
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension PanelPlaceholder where Actions == EmptyView {
    init(symbol: String, title: Text, message: Text) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

/// The translated text and where it came from, or why there is none: translating, nothing to
/// translate, a language still to download, or a failure.
struct TranslationPane: View {
    @Bindable var model: TextRecognitionModel

    var body: some View {
        VStack(spacing: 0) {
            if model.translationFailed {
                PanelPlaceholder(
                    symbol: "exclamationmark.triangle",
                    title: Text("Couldn’t translate", bundle: .module),
                    message: Text("Translation isn’t available right now.", bundle: .module)
                ) {
                    Button { model.translate() } label: { Text("Try Again", bundle: .module) }
                        .padding(.top, 6)
                }
            } else if let translation = model.translation {
                if !translation.outcome.translations.isEmpty {
                    TranslatedTextView(
                        text: translation.text, translated: translation.translated,
                        language: Translator.identifier(of: translation.outcome.target)
                    )
                    TranslationStatus(model: model)
                } else if let language = translation.outcome.needsDownload.first {
                    // The pair is what is missing; the system's sheet names the languages it downloads.
                    PanelPlaceholder(
                        symbol: "arrow.down.circle",
                        title: Text("Translating into \(Translator.name(of: translation.outcome.target)) needs a download", bundle: .module),
                        message: Text("Languages are downloaded once. After that, translation runs on this Mac without a connection.", bundle: .module)
                    ) {
                        Button { model.requestDownload(language) } label: { Text("Download…", bundle: .module) }
                            .padding(.top, 6)
                    }
                } else {
                    nothing(translation)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Translating…", bundle: .module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The system's sheet for a download, asked for by a Download button in this window.
        .translationTask(model.download) { session in
            await model.prepare(session)
        }
    }

    @ViewBuilder private func nothing(_ translation: TextRecognitionModel.Translation) -> some View {
        let outcome = translation.outcome
        let target = Translator.name(of: outcome.target)
        if let language = outcome.unsupported.first {
            PanelPlaceholder(
                symbol: "character.bubble",
                title: Text("\(Translator.name(of: language)) can’t be translated into \(target)", bundle: .module),
                message: Text("Choose another language in the toolbar.", bundle: .module)
            )
        } else if !outcome.inTarget.isEmpty {
            PanelPlaceholder(
                symbol: "checkmark.circle",
                title: Text("Already in \(target)", bundle: .module),
                message: Text("Choose another language in the toolbar to translate into.", bundle: .module)
            )
        } else if !translation.units.isEmpty, translation.units.allSatisfy({ $0.skip == .code }) {
            PanelPlaceholder(
                symbol: "chevron.left.forwardslash.chevron.right",
                title: Text("Code isn’t translated", bundle: .module),
                message: Text("Code stays exactly as it was read.", bundle: .module)
            )
        } else {
            PanelPlaceholder(
                symbol: "text.magnifyingglass",
                title: Text("Nothing to translate", bundle: .module),
                message: Text("Links, numbers, and code stay as they are.", bundle: .module)
            )
        }
    }
}

/// Under the translation: the languages it went between, and a language still to download.
struct TranslationStatus: View {
    let model: TextRecognitionModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if let summary = model.translationSummary {
                    Text(verbatim: summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(Text(verbatim: model.spokenTranslationSummary ?? summary))
                }
                Spacer(minLength: 8)
                if let language = model.translation?.outcome.needsDownload.first {
                    Button { model.requestDownload(language) } label: {
                        Text("Download Languages…", bundle: .module)
                    }
                    .controlSize(.small)
                    .help(Text("Text in \(Translator.name(of: language)) is shown as read until its languages are downloaded", bundle: .module))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

/// Once the text is edited, lines on the image no longer select it; this says so and offers the text as
/// read again.
struct EditedNotice: View {
    let model: TextRecognitionModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text("Edited, no longer linked to the image", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { model.revert() } label: { Text("Revert", bundle: .module) }
                    .controlSize(.small)
                    .help(Text("Replace your edits with the text as read (⌘Z undoes it)", bundle: .module))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

/// A recognized table as a grid, the first row as its header, figures right-aligned.
struct TablePreview: View {
    @Bindable var model: TextRecognitionModel
    let table: OCRTable
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.tables.count > 1 {
                Picker(selection: $model.tableIndex) {
                    ForEach(model.tables.indices, id: \.self) { index in
                        Text("Table \(index + 1)", bundle: .module).tag(index)
                    }
                } label: {
                    Text("Table", bundle: .module)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ScrollView([.horizontal, .vertical]) {
                let width = table.rows.map(\.count).max() ?? 0
                let figures = (0..<width).map { Self.holdsFigures(table, column: $0) }
                let hairline = 1 / max(displayScale, 1)
                let separator = Color(nsColor: .separatorColor)
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { row, cells in
                        GridRow {
                            ForEach(0..<width, id: \.self) { column in
                                Text(verbatim: column < cells.count ? cells[column] : "")
                                    .font(row == 0 ? .body.weight(.semibold) : .body)
                                    .monospacedDigit()
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(figures[column] ? .trailing : .leading)
                                    .frame(maxWidth: 260, alignment: figures[column] ? .trailing : .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    // Every cell fills its column, so the rules line up from row to row.
                                    .frame(minWidth: 56, maxWidth: .infinity, maxHeight: .infinity, alignment: figures[column] ? .topTrailing : .topLeading)
                                    .background(row == 0 ? (colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.045)) : Color.clear)
                                    .overlay(alignment: .trailing) {
                                        if column < width - 1 { separator.frame(width: hairline) }
                                    }
                                    .overlay(alignment: .bottom) {
                                        if row < table.rows.count - 1 { separator.frame(height: hairline) }
                                    }
                            }
                        }
                    }
                }
                .clipShape(shape)
                .overlay { shape.strokeBorder(separator, lineWidth: hairline) }
                .padding(1)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button { model.copyTable(as: .markdown) } label: { Text("Copy as Markdown", bundle: .module) }
                Button { model.copyTable(as: .csv) } label: { Text("Copy as CSV", bundle: .module) }
            }
            .controlSize(.small)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A column of figures: every cell below the header starts with a digit, maybe after a sign or a
    /// currency symbol ("$20", "100 GB", "−3%").
    static func holdsFigures(_ table: OCRTable, column: Int) -> Bool {
        let cells = table.rows.dropFirst().compactMap { $0.indices.contains(column) ? $0[column] : nil }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return !cells.isEmpty && cells.allSatisfy { $0.range(of: #"^[\p{Sc}+\-−±]?\s?\d"#, options: .regularExpression) != nil }
    }
}

/// Links, contacts, dates, and codes found in the image, each one click from being used.
struct FoundList: View {
    let model: TextRecognitionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Found in Image", bundle: .module)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(model.codes.enumerated()), id: \.offset) { index, code in
                    FoundRow(
                        symbol: code.kind.isMatrix ? "qrcode" : "barcode",
                        kind: Self.name(of: code.kind),
                        value: code.payload,
                        action: model.action(for: code),
                        model: model,
                        onHover: { inside in
                            if inside { model.hoveredCode = index } else if model.hoveredCode == index { model.hoveredCode = nil }
                        }
                    )
                }
                ForEach(Array(model.items.enumerated()), id: \.offset) { _, item in
                    FoundRow(symbol: Self.symbol(for: item.kind), kind: Self.kind(item.kind), value: item.text, action: model.action(for: item), model: model)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: 176)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func name(of kind: OCRCode.Kind) -> Text {
        switch kind {
        case .qr: Text("QR Code", bundle: .module)
        case .aztec: Text(verbatim: "Aztec")
        case .dataMatrix: Text(verbatim: "Data Matrix")
        case .pdf417: Text(verbatim: "PDF417")
        case .ean13: Text(verbatim: "EAN-13")
        case .ean8: Text(verbatim: "EAN-8")
        case .upce: Text(verbatim: "UPC-E")
        case .code128: Text(verbatim: "Code 128")
        case .code39: Text(verbatim: "Code 39")
        case .other: Text("Barcode", bundle: .module)
        }
    }

    static func symbol(for kind: DetectedItem.Kind) -> String {
        switch kind {
        case .link: "link"
        case .email: "envelope"
        case .phone: "phone"
        case .date: "calendar"
        case .address: "mappin.and.ellipse"
        }
    }

    static func kind(_ kind: DetectedItem.Kind) -> Text {
        switch kind {
        case .link: Text("Link", bundle: .module)
        case .email: Text("Email", bundle: .module)
        case .phone: Text("Phone", bundle: .module)
        case .date: Text("Date", bundle: .module)
        case .address: Text("Address", bundle: .module)
        }
    }
}

/// One found item: what it is shown by its symbol, the value, and quiet buttons for its verb and Copy.
/// VoiceOver hears one element, kind and value, with both verbs as actions.
struct FoundRow: View {
    let symbol: String
    let kind: Text
    let value: String
    let action: TextRecognitionModel.Action?
    let model: TextRecognitionModel
    var onHover: (Bool) -> Void = { _ in }
    @State private var hovering = false
    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .help(kind)
            Text(verbatim: value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let action {
                Button(action: action.perform) {
                    Image(systemName: action.symbol)
                }
                .help(action.title)
            }
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(Text("Copy", bundle: .module))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? (colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.045)) : Color.clear)
        }
        .onHover { inside in
            hovering = inside
            onHover(inside)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind)
        .accessibilityValue(Text(verbatim: value))
        .accessibilityAction { action?.perform() ?? copy() }
        .accessibilityActions {
            if let action {
                Button(action: action.perform) { action.title }
            }
            Button(action: copy) { Text("Copy", bundle: .module) }
        }
    }

    private func copy() {
        model.copy(value)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}
