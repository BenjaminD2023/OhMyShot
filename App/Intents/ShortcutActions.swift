import AppKit
import Foundation
import ImageIO
import OMSCore
import OMSUI
import OSLog
import UniformTypeIdentifiers

/// What the Shortcuts actions run, as the menu, the keyboard shortcuts, and the URL API run it. What a shortcut's user
/// can act on (a permission, a destination, a pack to download, a picture that isn't one) is thrown as a
/// `ShortcutFailure`, which Shortcuts shows as it says; anything else is thrown as it came.
final class ShortcutActions {
    private let permissions: PermissionCenter
    private let uploads: UploadCoordinator
    private let captures: CaptureCoordinator
    private let textCapture: TextCaptureCoordinator
    private let files: ScreenshotFiles
    private let packs: TextReaderPacks
    private let pins: PinController
    private let displays: DisplayTopology
    /// Shows how to turn Screen Recording on.
    private let showOnboarding: () -> Void
    /// Runs a URL API command, which needs no caller's approval here: the user made the shortcut. `done` is told the
    /// capture's record once a capture command's capture is kept, or nil when none is.
    private let run: (AutomationCommand, ((HistoryItem?) -> Void)?) -> Void
    /// Opens a picture in the editor under a name, added to the history first.
    private let openInEditor: (ImageLoader.Loaded, String) async -> Void

    init(
        permissions: PermissionCenter, uploads: UploadCoordinator, captures: CaptureCoordinator, textCapture: TextCaptureCoordinator,
        files: ScreenshotFiles, packs: TextReaderPacks, pins: PinController, displays: DisplayTopology,
        showOnboarding: @escaping () -> Void, run: @escaping (AutomationCommand, ((HistoryItem?) -> Void)?) -> Void,
        openInEditor: @escaping (ImageLoader.Loaded, String) async -> Void
    ) {
        self.permissions = permissions
        self.uploads = uploads
        self.captures = captures
        self.textCapture = textCapture
        self.files = files
        self.packs = packs
        self.pins = pins
        self.displays = displays
        self.showOnboarding = showOnboarding
        self.run = run
        self.openInEditor = openInEditor
    }

    /// A shortcut that reads the screen runs only with Screen Recording on; without it, onboarding shows how to turn it on.
    private func requireScreenRecording() throws(ShortcutFailure) {
        guard permissions.status(of: .screenRecording) == .granted else {
            showOnboarding()
            throw .needsScreenRecording
        }
    }

    /// A shortcut's capture: one of the URL API's capture commands, run as its keyboard shortcut runs it with the command's
    /// action after it. The capture's record once it is kept, or nil when it was cancelled or failed.
    func capture(_ command: AutomationCommand) async throws(ShortcutFailure) -> HistoryItem? {
        try requireScreenRecording()
        if command.captureAction == .upload, !uploads.canUpload { throw .noUploadDestination }
        return await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            run(command) { answer.give($0) }
        }
    }

    /// A kept capture's picture, to hand to a shortcut: in the format Settings choose.
    func file(for entry: HistoryItem) async throws -> (data: Data, name: String, type: UTType) {
        try await files.shortcutFile(for: entry)
    }

    /// A shortcut's Capture Text: the text copied, or nil when none was.
    func captureText(keepsLineBreaks: Bool) async throws(ShortcutFailure) -> String? {
        try requireScreenRecording()
        captures.cancelSelfTimer()
        return await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            textCapture.captureText(joinLines: !keepsLineBreaks, allowsCloud: false) { answer.give($0) }
        }
    }

    /// The text in a picture a shortcut hands over, read as Capture Text reads it; nothing is copied or shown.
    func text(inImage data: Data, keepsLineBreaks: Bool) async throws -> String? {
        // A picture, without decoding it here.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw ShortcutFailure.unreadableImage
        }
        // Read in the text reader, so the app is no larger after it (Docs/perf.md, M5 — power gate).
        guard let helper = packs.helper else {
            guard let loaded = ImageLoader.load(data: data, fallbackScale: 1) else { throw ShortcutFailure.unreadableImage }
            return await textCapture.text(in: loaded.image, joinLines: !keepsLineBreaks)
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "OhMyShot Shortcut \(UUID().uuidString)")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let text = try await TextReaderTool.text(
                ofPictureAt: file, joinsWrappedLines: !keepsLineBreaks, formulas: packs.formula, vlm: packs.vlm, seconds: TextCaptureCoordinator.panelTableWait,
                helper: helper
            )
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        } catch let failure as TextReaderTool.Failure {
            // As Capture Text's own reading did: no text, rather than an error.
            Log.capture.error("Recognizing a shortcut's picture failed: \(String(describing: failure), privacy: .public)")
            return nil
        }
    }

    /// A shortcut's Capture Formula: the LaTeX copied, or nil when no formula was.
    func captureFormula() async throws(ShortcutFailure) -> String? {
        try requireScreenRecording()
        guard packs.formula != nil else { throw .needsFormulaPack }
        captures.cancelSelfTimer()
        return await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            textCapture.captureFormula { answer.give($0) }
        }
    }

    /// The LaTeX of the formula in a picture a shortcut hands over, read as Capture Formula reads it; nothing is
    /// copied or shown. Nil when the pack read no whole formula.
    func formula(inImage data: Data) async throws -> String? {
        guard let helper = packs.helper, let pack = packs.formula else { throw ShortcutFailure.needsFormulaPack }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw ShortcutFailure.unreadableImage
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "OhMyShot Shortcut \(UUID().uuidString)")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let formula = try await TextReaderTool.formula(ofPictureAt: file, pack: pack, helper: helper)
            Log.capture.notice("A shortcut's formula reading ended with \(formula.ended.rawValue, privacy: .public), \(formula.latex.count, privacy: .public) characters")
            return formula.isFormula ? formula.latex : nil
        } catch let failure as TextReaderTool.Failure {
            Log.capture.error("Reading a shortcut's formula failed: \(String(describing: failure), privacy: .public)")
            return nil
        }
    }

    /// Pins a picture a shortcut hands over.
    func pin(_ data: Data) throws(ShortcutFailure) {
        let scale = displays.layout.displayUnderPointer?.pixelsPerPoint ?? 2
        guard let loaded = ImageLoader.load(data: data, fallbackScale: scale) else { throw .unreadableImage }
        pins.pin(loaded.image, scale: loaded.scale, origin: .clipboard)
    }

    /// Opens a picture a shortcut hands over in the editor, added to the history first.
    func annotate(_ data: Data, name: String) async throws(ShortcutFailure) {
        guard let loaded = ImageLoader.load(data: data) else { throw .unreadableImage }
        await openInEditor(loaded, name)
    }

    /// Runs a URL API command for a shortcut.
    func perform(_ command: AutomationCommand) throws(ShortcutFailure) {
        if command.readsScreen { try requireScreenRecording() }
        run(command, nil)
    }

    /// Hands a continuation its value once, however many times a follow-up says it is done.
    private final class Answer<Value: Sendable> {
        private var continuation: CheckedContinuation<Value, Never>?

        init(_ continuation: CheckedContinuation<Value, Never>) {
            self.continuation = continuation
        }

        func give(_ value: Value) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}

private extension AutomationCommand {
    /// What a capture command does with the capture once it is kept, beside what Settings say; nil for any other command.
    var captureAction: CaptureAction? {
        switch self {
        case .captureArea(_, let action), .capturePreviousArea(let action), .captureFullscreen(let action), .captureWindow(let action),
             .selfTimer(let action):
            action
        default:
            nil
        }
    }
}
