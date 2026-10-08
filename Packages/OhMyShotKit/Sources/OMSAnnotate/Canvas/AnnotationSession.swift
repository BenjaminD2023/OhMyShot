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
    }

    /// The capture, as it was taken.
    public let base: CGImage
    public private(set) var document: AnnotationDocument
    public var tool: AnnotationTool {
        didSet {
            guard tool != oldValue else { return }
            // Cropping is a passing mode; the next capture opens with a drawing tool.
            if tool != .crop { UserDefaults.standard.set(tool.rawValue, forKey: Self.toolKey) }
            notify(.tool)
        }
    }
    /// The selected marks, in the order they were selected.
    public private(set) var selection: [Annotation.ID] = []
    /// Whether the document changed since it was last kept.
    public private(set) var hasUnkeptChanges = false

    @ObservationIgnored public let undoManager = UndoManager()
    @ObservationIgnored private var settings: [AnnotationTool: ToolSettings]
    @ObservationIgnored private var listeners: [(Event) -> Void] = []
    @ObservationIgnored private var liveChangeStart: (document: AnnotationDocument, selection: [Annotation.ID])?

    private static let toolKey = "annotation.tool"
    private static let settingsKey = "annotation.toolSettings"

    /// - Parameters:
    ///   - image: the capture.
    ///   - scale: pixels per point of the screen it came from.
    ///   - document: marks made earlier, when a capture is opened again.
    public init(image: CGImage, scale: CGFloat, document: AnnotationDocument? = nil) {
        base = image
        let size = CGSize(width: image.width, height: image.height)
        if let document, document.pixelSize == size {
            self.document = document
        } else {
            self.document = AnnotationDocument(pixelSize: size, scale: scale)
        }
        let stored = UserDefaults.standard.string(forKey: Self.toolKey).flatMap(AnnotationTool.init(rawValue:))
        tool = stored == nil || stored == .crop ? .arrow : stored!
        settings = Self.loadSettings()
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
        case .highlighter: .highlighter
        case .text: .text
        case .counter: .counter
        case .redaction: .redact
        case .spotlight: .spotlight
        }
    }

    private static func loadSettings() -> [AnnotationTool: ToolSettings] {
        guard
            let data = UserDefaults.standard.data(forKey: settingsKey),
            let stored = try? JSONDecoder().decode([String: ToolSettings].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in AnnotationTool(rawValue: key).map { ($0, value) } })
    }

    private func saveSettings() {
        let stored = Dictionary(uniqueKeysWithValues: settings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
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

    /// The finished picture, rendered off the main actor.
    public func render() async -> CGImage? {
        await AnnotationRenderer.render(document, base: base)
    }
}
