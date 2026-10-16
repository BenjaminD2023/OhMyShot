import AppKit
import Foundation
import Observation

/// One capture being marked up: the document, the tool in hand, what is selected, and every tool's
/// settings. The canvas, the tool rail, and the style capsule all read and change it, and every change
/// to the document goes through here so it can be undone.
@MainActor
@Observable
public final class AnnotationSession {
    public enum Event {
        /// The marks or the canvas changed.
        case document
        case selection
        case tool
        /// A tool's settings, or the selected marks' style, changed.
        case settings
        /// What Undo and Redo would do changed.
        case history
        /// Redaction suggestions came in, or started being looked for.
        case suggestions
        /// The capture's lines of text came in, or started being looked for.
        case textLines
    }

    /// Reads a capture's text for the tools that use it: what the redaction tool suggests covering, and the
    /// lines the highlighter snaps to. Set once by the app, which reads text. Nil leaves the redaction tool
    /// without suggestions and the highlighter drawing freely.
    public static var readText: (@Sendable (CGImage) -> CaptureReading)?

    /// The capture, as it was taken.
    public let base: CGImage
    public private(set) var document: AnnotationDocument
    /// The picture the marks lie on: the capture turned, flipped, and resized as the document says, in the
    /// document's own pixels. `base` itself until the capture is changed that way. Made once for each
    /// turn and size; every reading of pixels by the document's coordinates goes through it. Turning and
    /// resizing make it before they are kept (`apply`), so this makes it only for a document opened that
    /// way or an edit undone or redone; if memory then fails it, the capture stands in.
    public var picture: CGImage {
        let transform = document.transform
        if let pictureCache, pictureCache.transform == transform { return pictureCache.image }
        let image = document.picture(from: base) ?? base
        keepPicture(image, for: transform)
        return image
    }

    /// Remembers the picture `transform` makes, and lets go of what was read from the one before it.
    private func keepPicture(_ image: CGImage, for transform: CaptureTransform?) {
        pictureCache = (transform, image)
        edgeCache = nil
        blurCache = nil
        redactionCache = nil
    }

    /// Whether the canvas stays the size it is when pictures are combined past its edges, which are then
    /// cut off, instead of growing to hold them. Kept for the next editor.
    public var locksCanvas: Bool {
        didSet {
            guard locksCanvas != oldValue else { return }
            defaults.set(locksCanvas, forKey: Self.lockCanvasKey)
            notify(.settings)
        }
    }
    /// The shape the crop frame keeps while the crop tool is in hand.
    public private(set) var cropRatio: CropRatio = .free
    public var tool: AnnotationTool {
        didSet {
            guard tool != oldValue else { return }
            // Cropping and the background are passing modes; the next capture opens with a drawing tool.
            if !tool.isPictureMode, remembersTool { defaults.set(tool.rawValue, forKey: Self.toolKey) }
            if tool.isPictureMode, !oldValue.isPictureMode { toolBeforeMode = oldValue }
            if tool == .redact { findRedactionsIfNeeded() }
            if tool == .highlighter { findTextLinesIfNeeded() }
            notify(.tool)
        }
    }
    /// The tool in hand before cropping or the background, to go back to when done.
    public private(set) var toolBeforeMode: AnnotationTool = .arrow
    /// Whether the tool in hand is the one the next editor opens with. In-place annotation starts with
    /// no tool and keeps its choices to itself.
    @ObservationIgnored private let remembersTool: Bool
    /// The selected marks, in the order they were selected.
    public private(set) var selection: [Annotation.ID] = []
    /// Whether the document changed since it was last kept.
    public private(set) var hasUnkeptChanges = false
    /// What reading found better covered, once the redaction tool has been in hand.
    public private(set) var redactionSuggestions: [RedactionSuggestion] = []
    /// Whether the capture is being read for them.
    public private(set) var isFindingRedactions = false
    /// Whether the last reading for them failed, so the capture could not be read: it is read again on
    /// request, or the next time the tool is in hand.
    public private(set) var couldNotFindRedactions = false
    @ObservationIgnored private var hasLookedForRedactions = false
    @ObservationIgnored private var findTask: Task<Void, Never>?
    /// The capture's lines of text, once the highlighter has been in hand.
    public private(set) var textLines: [TextLine] = []
    /// Whether the capture is being read for them.
    public private(set) var isFindingTextLines = false
    /// Whether the last reading for them failed, as for the suggestions.
    public private(set) var couldNotFindTextLines = false
    @ObservationIgnored private var hasLookedForTextLines = false
    @ObservationIgnored private var textLinesTask: Task<Void, Never>?
    /// The combined images each reading saw: one made before an image was combined, moved, or removed
    /// describes a picture that is gone.
    @ObservationIgnored private var redactionsReadOver: [Annotation]?
    @ObservationIgnored private var textLinesReadOver: [Annotation]?
    /// The capture's text as the tools read it, one reading for both: the part of the picture it looks at,
    /// in the document, and the combined images it saw.
    @ObservationIgnored private var reading: (text: CaptureReading, region: CGRect, images: [Annotation])?
    /// Reads this session's capture in place of `readText`, so tests running side by side each read their
    /// own way.
    @ObservationIgnored var textReader: (@Sendable (CGImage) -> CaptureReading)?

    @ObservationIgnored public let undoManager = UndoManager()
    @ObservationIgnored private var settings: [AnnotationTool: ToolSettings]
    @ObservationIgnored private var listeners: [(Event) -> Void] = []
    @ObservationIgnored private var liveChangeStart: (document: AnnotationDocument, selection: [Annotation.ID])?
    /// The background last set, which the next one starts from.
    @ObservationIgnored public private(set) var lastBackdrop: Backdrop
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pictureCache: (transform: CaptureTransform?, image: CGImage)?
    @ObservationIgnored private var edgeCache: (canvas: CGRect, picture: CGImage, edges: EdgeAnalysis)?
    @ObservationIgnored private var blurCache: (canvas: CGRect, picture: CGImage, image: CGImage?)?
    @ObservationIgnored private var redactionCache: (images: [Annotation], picture: CGImage, source: (image: CGImage, origin: CGPoint)?)?
    /// How the capture was turned and sized when the readings were made; a different one makes them stale.
    @ObservationIgnored private var readingsTransform: CaptureTransform?

    private static let toolKey = "annotation.tool"
    private static let settingsKey = "annotation.toolSettings"
    private static let backdropKey = "annotation.backdrop"
    private static let lockCanvasKey = "annotation.lockCanvas"

    /// - Parameters:
    ///   - image: the capture.
    ///   - scale: pixels per point of the screen it came from.
    ///   - document: marks made earlier, when a capture is opened again.
    ///   - tool: the tool to start with, which is then not remembered for the editor; nil starts with the
    ///     editor's last tool.
    ///   - defaults: where the editor remembers its tool, tool settings, background, and canvas lock.
    public init(image: CGImage, scale: CGFloat, document: AnnotationDocument? = nil, tool startingTool: AnnotationTool? = nil, defaults: UserDefaults = .standard) {
        base = image
        self.defaults = defaults
        locksCanvas = defaults.bool(forKey: Self.lockCanvasKey)
        let size = CGSize(width: image.width, height: image.height)
        if let document, document.pixelSize == size {
            self.document = document
        } else {
            self.document = AnnotationDocument(pixelSize: size, scale: scale)
        }
        remembersTool = startingTool == nil
        let stored = defaults.string(forKey: Self.toolKey).flatMap(AnnotationTool.init(rawValue:))
        tool = startingTool ?? stored.flatMap { $0.isPictureMode ? nil : $0 } ?? .arrow
        settings = Self.loadSettings(from: defaults)
        lastBackdrop = defaults.data(forKey: Self.backdropKey).flatMap { try? JSONDecoder().decode(Backdrop.self, from: $0) } ?? Backdrop()
        undoManager.levelsOfUndo = 100
    }

    /// Calls `handler` after every change, for views that redraw on their own terms.
    public func observe(_ handler: @escaping (Event) -> Void) {
        listeners.append(handler)
    }

    private func notify(_ event: Event) {
        listeners.forEach { $0(event) }
    }

    // MARK: Settings

    /// The settings the controls show: the selected mark's when one is selected, else the tool's.
    public var currentSettings: ToolSettings {
        if let id = selection.first, let item = document.item(id) {
            var shown = settings(for: Self.tool(for: item))
            shown.adopt(item)
            return shown
        }
        return settings(for: tool)
    }

    /// The tool whose settings the controls show: the selected mark's kind, or the tool in hand.
    public var currentKind: AnnotationTool {
        if let id = selection.first, let item = document.item(id) { return Self.tool(for: item) }
        return tool
    }

    public func settings(for tool: AnnotationTool) -> ToolSettings {
        settings[tool] ?? .defaults(for: tool)
    }

    /// Changes a setting: on the selected marks (undoably) when there are any, and in every case for
    /// the next marks of their kind.
    public func changeSettings(_ actionName: String, _ change: (inout ToolSettings) -> Void) {
        if selection.isEmpty {
            var updated = settings(for: tool)
            change(&updated)
            settings[tool] = updated
        } else {
            var document = self.document
            for id in selection {
                guard let index = document.index(of: id) else { continue }
                let item = document.items[index]
                let kind = Self.tool(for: item)
                var updated = settings(for: kind)
                updated.adopt(item)
                change(&updated)
                document.items[index] = updated.applied(to: item)
                // The next mark of this kind matches, but keeps its own size where sizes differ by
                // kind (a text's type size never becomes an arrow's).
                settings[kind] = updated
            }
            if isInLiveChange {
                // Restyling text while it is typed is part of that edit's one undo step.
                updateLive(document)
            } else {
                commit(document, actionName: actionName)
            }
        }
        saveSettings()
        notify(.settings)
    }

    /// The tool a mark belongs to, whose settings it shares.
    public static func tool(for item: Annotation) -> AnnotationTool {
        switch item.shape {
        case .arrow: .arrow
        case .line: .line
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .pen: .pen
        case .highlighter, .textHighlight: .highlighter
        case .highlightBox: .highlightBox
        case .text: .text
        case .counter: .counter
        case .redaction: .redact
        case .spotlight: .spotlight
        // No tool draws images: they are dropped or pasted in, and selected like anything else.
        case .image: .select
        }
    }

    private static func loadSettings(from defaults: UserDefaults) -> [AnnotationTool: ToolSettings] {
        guard
            let data = defaults.data(forKey: settingsKey),
            let stored = try? JSONDecoder().decode([String: ToolSettings].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in AnnotationTool(rawValue: key).map { ($0, value) } })
    }

    private func saveSettings() {
        let stored = Dictionary(uniqueKeysWithValues: settings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    /// Leaves cropping or the background for the tool in hand before.
    public func leavePictureMode() {
        if tool.isPictureMode { tool = toolBeforeMode }
    }

    // MARK: Background

    /// Sets the background, or takes it away with nil, as one undoable step (or as part of the live
    /// change in progress, such as a slider's drag).
    public func setBackdrop(_ backdrop: Backdrop?, actionName: String) {
        var document = self.document
        document.backdrop = backdrop
        if isInLiveChange {
            // Remembered once the drag ends, not at every step of it.
            updateLive(document)
        } else {
            if let backdrop { rememberBackdrop(backdrop) }
            commit(document, actionName: actionName)
        }
    }

    /// Changes the background, starting from the last one set when there is none.
    public func changeBackdrop(_ actionName: String, _ change: (inout Backdrop) -> Void) {
        var backdrop = document.backdrop ?? lastBackdrop
        change(&backdrop)
        setBackdrop(backdrop, actionName: actionName)
    }

    private func rememberBackdrop(_ backdrop: Backdrop) {
        guard backdrop != lastBackdrop else { return }
        lastBackdrop = backdrop
        if let data = try? JSONEncoder().encode(backdrop) {
            defaults.set(data, forKey: Self.backdropKey)
        }
    }

    /// The capture's edge as the canvas keeps it, read once per canvas.
    public var edges: EdgeAnalysis {
        let canvas = document.canvas.standardized
        let picture = self.picture
        if let edgeCache, edgeCache.canvas == canvas, edgeCache.picture === picture { return edgeCache.edges }
        let edges = EdgeAnalysis.of(picture, canvas: canvas)
        edgeCache = (canvas, picture, edges)
        return edges
    }

    /// Where the background, the capture, and its card go; nil without a background.
    public var backdropLayout: BackdropLayout? {
        document.backdrop == nil ? nil : document.backdropLayout(edges: edges)
    }

    /// The blurred capture a blur background shows, made once per canvas.
    public var blurredCapture: CGImage? {
        let canvas = document.canvas.standardized
        let picture = self.picture
        if let blurCache, blurCache.canvas == canvas, blurCache.picture === picture { return blurCache.image }
        let image = BackdropPainter.blurredCapture(picture, canvas: canvas)
        blurCache = (canvas, picture, image)
        return image
    }

    // MARK: Images

    /// Combines pictures into the capture, each centered on `point` (pixels) and each later one a
    /// little down and to the right, the canvas grown to hold them unless it is locked, as one undoable
    /// step. `size` is in the document's pixels. The new images are selected.
    public func addImages(_ pictures: [(name: String, size: CGSize)], at point: CGPoint) {
        guard !pictures.isEmpty else { return }
        var document = self.document
        var added: [Annotation.ID] = []
        for (index, picture) in pictures.enumerated() {
            let offset = CGFloat(index) * 24 * document.scale
            let rect = CGRect(
                x: point.x - picture.size.width / 2 + offset, y: point.y - picture.size.height / 2 + offset,
                width: picture.size.width, height: picture.size.height
            ).integral
            let item = Annotation(shape: .image(PlacedImage(rect: rect, name: picture.name)), style: Style(color: .black, lineWidth: 0, shadow: false))
            document.items.append(item)
            added.append(item.id)
        }
        if !locksCanvas { document.canvas = Self.canvas(holdingImagesOf: document) }
        let name = pictures.count == 1 ? String(localized: "Add Image", bundle: .module) : String(localized: "Add Images", bundle: .module)
        commit(document, selecting: added, actionName: name)
    }

    /// Grows the canvas to hold every image after one was moved or resized past its edge; part of the
    /// live change in progress, if any. Never shrinks it: a crop does that. A locked canvas stays as it is.
    public func growCanvasToHoldImages() {
        guard !locksCanvas else { return }
        let canvas = Self.canvas(holdingImagesOf: document)
        guard canvas != document.canvas.standardized else { return }
        var document = self.document
        document.canvas = canvas
        if isInLiveChange {
            updateLive(document)
        } else {
            commit(document, actionName: String(localized: "Resize Canvas", bundle: .module))
        }
    }

    private static func canvas(holdingImagesOf document: AnnotationDocument) -> CGRect {
        document.items.reduce(document.canvas.standardized) { canvas, item in
            if case .image(let image) = item.shape { return canvas.union(image.rect.standardized) }
            return canvas
        }.integral
    }

    /// What blurs and pixelations show: the capture with the images combined into it, and where its
    /// corner is in the document; nil while nothing is combined. Made again only when an image changes.
    public var redactionSource: (image: CGImage, origin: CGPoint)? {
        let images = document.items.filter { if case .image = $0.shape { true } else { false } }
        let picture = self.picture
        if let redactionCache, redactionCache.images == images, redactionCache.picture === picture { return redactionCache.source }
        let source = AnnotationRenderer.redactionSource(document, base: picture)
        redactionCache = (images, picture, source)
        return source
    }

    // MARK: Reading

    /// What reading looks at: the capture as blurs see it, combined images included, cut to the canvas and
    /// a margin around it, and where its corner is in the document. Annotating a small area of a large
    /// screen in place reads that area, not the whole display; an editor reads the whole capture unless it
    /// is cropped.
    var readingSource: (image: CGImage, origin: CGPoint) {
        let source = redactionSource ?? (picture, .zero)
        let bounds = CGRect(origin: source.origin, size: CGSize(width: source.image.width, height: source.image.height))
        let canvas = document.canvas.standardized
        // Room for a selection moved or grown a little after reading, and for lines its edge cuts.
        let margin = max(max(canvas.width, canvas.height) * 0.25, 160)
        let region = canvas.insetBy(dx: -margin, dy: -margin).integral.intersection(bounds)
        guard !region.isNull, region != bounds, region.width >= 1, region.height >= 1,
              let part = source.image.cropping(to: region.offsetBy(dx: -source.origin.x, dy: -source.origin.y))
        else { return source }
        return (part, region.origin)
    }

    /// The reading of the capture's text the tools share: the one begun for either of them, while the
    /// combined images are as it saw them and it looks at all the canvas shows; else a new one.
    private func sharedReading() -> (text: CaptureReading, origin: CGPoint)? {
        guard let read = textReader ?? Self.readText else { return nil }
        let images = self.images
        let source = redactionSource ?? (picture, .zero)
        let shown = document.canvas.standardized.intersection(
            CGRect(origin: source.origin, size: CGSize(width: source.image.width, height: source.image.height))
        )
        if let reading, reading.images == images, reading.region.contains(shown) {
            return (reading.text, reading.region.origin)
        }
        let part = readingSource
        let text = read(part.image)
        reading = (text, CGRect(origin: part.origin, size: CGSize(width: part.image.width, height: part.image.height)), images)
        return (text, part.origin)
    }

    // MARK: Redaction suggestions

    /// Reads the capture for redaction suggestions, once per session: the first time the redaction tool is
    /// in hand, so nothing is read for an editor that never covers anything. The reading is the one the
    /// highlighter's lines come from, so what both need is read once.
    public func findRedactionsIfNeeded() {
        guard !hasLookedForRedactions, let reading = sharedReading() else { return }
        hasLookedForRedactions = true
        readingsTransform = document.transform
        redactionsReadOver = images
        isFindingRedactions = true
        couldNotFindRedactions = false
        notify(.suggestions)
        findTask = Task { [weak self] in
            let found = try? await reading.text.redactionSuggestions()
            // A reading dropped midway is no failure.
            guard let self, !Task.isCancelled else { return }
            isFindingRedactions = false
            findTask = nil
            if let found {
                redactionSuggestions = found.map { RedactionSuggestion(rect: $0.rect.offsetBy(dx: reading.origin.x, dy: reading.origin.y), label: $0.label) }
            } else {
                hasLookedForRedactions = false
                redactionsReadOver = nil
                couldNotFindRedactions = true
            }
            notify(.suggestions)
        }
    }

    /// Drops readings still under way, for a canvas that is closing; the next time their tool is in hand
    /// reads again.
    public func cancelReading() {
        if findTask != nil { forgetRedactions() }
        if textLinesTask != nil { forgetTextLines() }
    }

    private func forgetRedactions() {
        findTask?.cancel()
        findTask = nil
        redactionSuggestions = []
        hasLookedForRedactions = false
        isFindingRedactions = false
        couldNotFindRedactions = false
        redactionsReadOver = nil
    }

    private func forgetTextLines() {
        textLinesTask?.cancel()
        textLinesTask = nil
        textLines = []
        hasLookedForTextLines = false
        isFindingTextLines = false
        couldNotFindTextLines = false
        textLinesReadOver = nil
    }

    /// The combined images, which reading sees as part of the capture.
    private var images: [Annotation] {
        document.items.filter { if case .image = $0.shape { true } else { false } }
    }

    /// Forgets what was read of a picture whose combined images have changed since, or that was turned,
    /// flipped, or resized since (readings are in the picture's pixels), and reads it again for the tool in
    /// hand.
    private func forgetReadingsOfChangedImages() {
        let images = self.images
        let turned = document.transform != readingsTransform
        if let reading, reading.images != images || turned { self.reading = nil }
        if let read = redactionsReadOver, read != images || turned {
            forgetRedactions()
            if tool == .redact { findRedactionsIfNeeded() } else { notify(.suggestions) }
        }
        if let read = textLinesReadOver, read != images || turned {
            forgetTextLines()
            if tool == .highlighter { findTextLinesIfNeeded() } else { notify(.textLines) }
        }
    }

    /// The suggestions no redaction covers yet, within what the picture keeps after a crop.
    public var openRedactionSuggestions: [RedactionSuggestion] {
        let covers = document.items.compactMap { item -> CGRect? in
            if case .redaction(let redaction) = item.shape { redaction.rect.standardized } else { nil }
        }
        let kept = document.canvas.standardized
        return redactionSuggestions.filter { suggestion in
            // Only the part a crop keeps needs covering.
            let visible = suggestion.rect.intersection(kept)
            guard !visible.isNull, visible.width > 0, visible.height > 0 else { return false }
            let area = visible.width * visible.height
            return !covers.contains { cover in
                let shared = cover.intersection(visible)
                return !shared.isNull && shared.width * shared.height >= area * 0.9
            }
        }
    }

    /// Where an open suggestion's redaction would go: its covering rectangle, within what a crop keeps.
    public func coveringRect(of suggestion: RedactionSuggestion) -> CGRect {
        suggestion.coveringRect(within: document.canvas)
    }

    /// The open suggestion at `point` (capture pixels), if any.
    public func redactionSuggestion(at point: CGPoint) -> RedactionSuggestion? {
        openRedactionSuggestions.first { coveringRect(of: $0).contains(point) }
    }

    /// Covers the open suggestion at `point` with a redaction in the tool's method, as one undoable step.
    @discardableResult
    public func acceptRedactionSuggestion(at point: CGPoint) -> Bool {
        guard let suggestion = redactionSuggestion(at: point) else { return false }
        return acceptRedactionSuggestion(suggestion)
    }

    /// Covers `suggestion`, if it is still open, as one undoable step.
    @discardableResult
    public func acceptRedactionSuggestion(_ suggestion: RedactionSuggestion) -> Bool {
        guard openRedactionSuggestions.contains(suggestion) else { return false }
        cover([suggestion], actionName: String(localized: "Redact", bundle: .module))
        return true
    }

    /// Covers every open suggestion, as one undoable step.
    public func acceptAllRedactionSuggestions() {
        let open = openRedactionSuggestions
        guard !open.isEmpty else { return }
        cover(open, actionName: String(localized: "Redact All", bundle: .module))
    }

    private func cover(_ suggestions: [RedactionSuggestion], actionName: String) {
        let settings = settings(for: .redact)
        var newDocument = document
        for suggestion in suggestions {
            let rect = coveringRect(of: suggestion)
            if let mark = AnnotationTool.redact.mark(from: rect.origin, to: CGPoint(x: rect.maxX, y: rect.maxY), constrained: false, settings: settings) {
                newDocument.items.append(mark)
            }
        }
        commit(newDocument, selecting: [], actionName: actionName)
    }

    // MARK: Text lines

    /// Reads the capture for its lines of text, once per session: the first time the highlighter is in
    /// hand, so nothing is read for an editor that never highlights. The reading is the one the redaction
    /// suggestions come from, so what both need is read once. A stroke drawn before they come in is drawn
    /// freely.
    public func findTextLinesIfNeeded() {
        guard !hasLookedForTextLines, let reading = sharedReading() else { return }
        hasLookedForTextLines = true
        readingsTransform = document.transform
        textLinesReadOver = images
        isFindingTextLines = true
        couldNotFindTextLines = false
        notify(.textLines)
        textLinesTask = Task { [weak self] in
            let found = try? await reading.text.textLines()
            // A reading dropped midway is no failure.
            guard let self, !Task.isCancelled else { return }
            isFindingTextLines = false
            textLinesTask = nil
            if let found {
                textLines = found.filter { !$0.words.isEmpty }.map { $0.offsetBy(dx: reading.origin.x, dy: reading.origin.y) }
            } else {
                hasLookedForTextLines = false
                textLinesReadOver = nil
                couldNotFindTextLines = true
            }
            notify(.textLines)
        }
    }

    /// Whether the capture is being read for the tool in hand: for the redaction tool's suggestions, or the
    /// lines of text the highlighter snaps to.
    public var isReadingForTool: Bool {
        switch tool {
        case .redact: isFindingRedactions
        case .highlighter: isFindingTextLines
        default: false
        }
    }

    /// Whether the last reading for the tool in hand failed.
    public var readingFailedForTool: Bool {
        switch tool {
        case .redact: couldNotFindRedactions
        case .highlighter: couldNotFindTextLines
        default: false
        }
    }

    /// Reads the capture again for the tool in hand, after a reading that failed.
    public func retryReadingForTool() {
        switch tool {
        case .redact: findRedactionsIfNeeded()
        case .highlighter: findTextLinesIfNeeded()
        default: break
        }
    }

    /// Whether a size means anything for what the controls change: not for highlights snapped to text,
    /// whose height is their text's.
    public var sizeApplies: Bool {
        let selected = selectedItems
        return selected.isEmpty || selected.contains { if case .textHighlight = $0.shape { false } else { true } }
    }

    // MARK: Selection

    public func select(_ ids: [Annotation.ID]) {
        let ids = ids.filter { document.item($0) != nil }
        guard ids != selection else { return }
        selection = ids
        notify(.selection)
    }

    public func selectAll() {
        select(document.items.map(\.id))
    }

    public var selectedItems: [Annotation] {
        selection.compactMap { document.item($0) }
    }

    // MARK: Changes

    /// Replaces the document as one undoable step named `actionName`.
    public func commit(_ newDocument: AnnotationDocument, selecting newSelection: [Annotation.ID]? = nil, actionName: String) {
        guard newDocument != document || (newSelection.map { $0 != selection } ?? false) else { return }
        let old = (document, selection)
        set(newDocument, selection: newSelection ?? selection.filter { newDocument.item($0) != nil })
        registerUndo(restoring: old.0, selection: old.1, actionName: actionName)
    }

    /// Starts a change made over several events, such as a drag: updates until `endLiveChange` become
    /// one undo step.
    public func beginLiveChange() {
        liveChangeStart = (document, selection)
    }

    /// Shows the document mid-change, without an undo step.
    public func updateLive(_ newDocument: AnnotationDocument, selecting newSelection: [Annotation.ID]? = nil) {
        set(newDocument, selection: newSelection ?? selection.filter { newDocument.item($0) != nil })
    }

    /// Ends a live change; nothing is recorded when nothing changed.
    public func endLiveChange(actionName: String) {
        guard let start = liveChangeStart else { return }
        liveChangeStart = nil
        guard start.document != document else { return }
        if let backdrop = document.backdrop, backdrop != start.document.backdrop { rememberBackdrop(backdrop) }
        registerUndo(restoring: start.document, selection: start.selection, actionName: actionName)
    }

    /// Abandons a live change, putting the document back as it was.
    public func cancelLiveChange() {
        guard let start = liveChangeStart else { return }
        liveChangeStart = nil
        set(start.document, selection: start.selection)
    }

    public var isInLiveChange: Bool { liveChangeStart != nil }

    /// Marks the current document as kept: the capture file now shows it.
    public func markKept() {
        hasUnkeptChanges = false
    }

    private func set(_ newDocument: AnnotationDocument, selection newSelection: [Annotation.ID]) {
        let documentChanged = newDocument != document
        let selectionChanged = newSelection != selection
        document = newDocument
        selection = newSelection
        if documentChanged {
            hasUnkeptChanges = true
            notify(.document)
        }
        if selectionChanged { notify(.selection) }
    }

    private func registerUndo(restoring old: AnnotationDocument, selection oldSelection: [Annotation.ID], actionName: String) {
        undoManager.registerUndo(withTarget: self) { session in
            let current = (session.document, session.selection)
            session.set(old, selection: oldSelection)
            session.registerUndo(restoring: current.0, selection: current.1, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        // Told here rather than through the undo manager's group notifications, which close only at
        // the end of an event and are not posted for every change.
        notify(.history)
        forgetReadingsOfChangedImages()
    }

    /// Undoes the last change to the marks.
    public func undo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
        notify(.history)
    }

    public func redo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
        notify(.history)
    }

    // MARK: Editing commands

    public func deleteSelection() {
        guard !selection.isEmpty else { return }
        var document = self.document
        document.items.removeAll { selection.contains($0.id) }
        commit(document, selecting: [], actionName: String(localized: "Delete", bundle: .module))
    }

    /// Copies the selected marks a little down and to the right, and selects the copies.
    public func duplicateSelection() {
        let originals = selectedItems
        guard !originals.isEmpty else { return }
        let offset = 10 * document.scale
        var document = self.document
        var copies: [Annotation.ID] = []
        for original in originals {
            var copy = original.translated(by: CGSize(width: offset, height: offset))
            copy.id = UUID()
            if case .counter(var counter) = copy.shape {
                counter.value = document.nextCounterValue(for: counter.numbering)
                copy.shape = .counter(counter)
            }
            document.items.append(copy)
            copies.append(copy.id)
        }
        commit(document, selecting: copies, actionName: String(localized: "Duplicate", bundle: .module))
    }

    /// Moves the selected marks by `points` of the captured screen.
    public func nudgeSelection(by points: CGSize) {
        guard !selection.isEmpty else { return }
        let delta = CGSize(width: points.width * document.scale, height: points.height * document.scale)
        var document = self.document
        for id in selection {
            guard let index = document.index(of: id) else { continue }
            document.items[index] = document.items[index].translated(by: delta)
        }
        commit(document, actionName: String(localized: "Move", bundle: .module))
    }

    /// Brings the selected marks to the front.
    public func bringSelectionToFront() {
        var document = self.document
        let moving = document.items.filter { selection.contains($0.id) }
        document.items.removeAll { selection.contains($0.id) }
        document.items.append(contentsOf: moving)
        commit(document, actionName: String(localized: "Bring to Front", bundle: .module))
    }

    /// Sends the selected marks to the back.
    public func sendSelectionToBack() {
        var document = self.document
        let moving = document.items.filter { selection.contains($0.id) }
        document.items.removeAll { selection.contains($0.id) }
        document.items.insert(contentsOf: moving, at: 0)
        commit(document, actionName: String(localized: "Send to Back", bundle: .module))
    }

    /// Crops to `rect` (pixels; reaching past the capture adds canvas there).
    public func crop(to rect: CGRect) {
        var document = self.document
        document.canvas = rect.standardized.integral
        commit(document, actionName: String(localized: "Crop", bundle: .module))
    }

    /// Turns, flips, or resizes the whole picture, the marks and the canvas with it, as one undoable step.
    /// A resize asks for the canvas's new size in pixels. A picture that cannot be made, such as one too
    /// large for the memory there is, changes nothing and beeps.
    public func apply(_ operation: PictureOperation) {
        guard let updated = document.applying(operation) else { return }
        // Made before anything is kept, so it is not made twice and a failure leaves the document alone.
        guard let image = updated.picture(from: base) else {
            NSSound.beep()
            return
        }
        keepPicture(image, for: updated.transform)
        commit(updated, actionName: Self.actionName(for: operation))
    }

    private static func actionName(for operation: PictureOperation) -> String {
        switch operation {
        case .rotateRight: String(localized: "Rotate Right", bundle: .module)
        case .rotateLeft: String(localized: "Rotate Left", bundle: .module)
        case .flipHorizontally: String(localized: "Flip Horizontal", bundle: .module)
        case .flipVertically: String(localized: "Flip Vertical", bundle: .module)
        case .resize: String(localized: "Resize Image", bundle: .module)
        }
    }

    /// Chooses the shape the crop frame keeps.
    public func setCropRatio(_ ratio: CropRatio) {
        guard ratio != cropRatio else { return }
        cropRatio = ratio
        notify(.settings)
    }

    /// The finished picture, rendered off the main actor.
    public func render() async -> CGImage? {
        await AnnotationRenderer.render(document, base: base)
    }
}
