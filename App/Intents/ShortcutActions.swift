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
    /// The captures shortcuts hold until they have read their files.
    private let holds: ShortcutCaptureHolds
    /// Shows how to turn Screen Recording on.
    private let showOnboarding: () -> Void
    /// Counts a feature in usage data by its usage-data name, for the actions that run no URL API command, which
    /// counts itself, and for a command stopped here before it runs.
    private let used: (String) -> Void
    /// Runs a URL API command, which needs no caller's approval here: the user made the shortcut. `kept` is told the
    /// capture's record as soon as a capture command's capture is kept, before anything can let it go; `done` once it is
    /// kept, or nil when none is.
    private let run: (AutomationCommand, _ kept: ((HistoryItem) -> Void)?, _ done: ((HistoryItem?) -> Void)?) -> Void
    /// Opens a picture in the editor under a name, added to the history first.
    private let openInEditor: (ImageLoader.Loaded, String) async -> Void

    init(
        permissions: PermissionCenter, uploads: UploadCoordinator, captures: CaptureCoordinator, textCapture: TextCaptureCoordinator,
        files: ScreenshotFiles, packs: TextReaderPacks, pins: PinController, displays: DisplayTopology, holds: ShortcutCaptureHolds,
        showOnboarding: @escaping () -> Void, used: @escaping (String) -> Void,
        run: @escaping (AutomationCommand, ((HistoryItem) -> Void)?, ((HistoryItem?) -> Void)?) -> Void,
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
        self.holds = holds
        self.showOnboarding = showOnboarding
        self.used = used
        self.run = run
        self.openInEditor = openInEditor
    }

    /// A shortcut that reads the screen runs only with Screen Recording on; without it, onboarding shows how to turn it on,
    /// and the URL API command it would have run, which counts itself when it runs, is counted here.
    private func requireScreenRecording(for command: AutomationCommand? = nil) throws(ShortcutFailure) {
        guard permissions.status(of: .screenRecording) == .granted else {
            if let command { used(command.usageName) }
            showOnboarding()
            throw .needsScreenRecording
        }
    }

    /// A shortcut's capture: one of the URL API's capture commands, run as its keyboard shortcut runs it with the command's
    /// action after it. Its picture in the format Settings choose, or nil when it was cancelled or failed. The capture is
    /// held from the moment it is kept until its picture is read, as with Keep Captures at Never and no card nothing else
    /// holds it, and let go then, however reading it went.
    func capture(_ command: AutomationCommand) async throws -> (data: Data, name: String, type: UTType)? {
        try requireScreenRecording(for: command)
        if command.captureAction == .upload, !uploads.canUpload {
            used(command.usageName)
            throw ShortcutFailure.noUploadDestination
        }
        // A pinned capture is left as Capture Area and Pin leaves it, for the pin's Save and drag.
        return try await holds.holding(lettingGo: command.captureAction != .pin) { hold -> (data: Data, name: String, type: UTType)? in
            guard let entry = await kept(command, holding: hold) else { return nil }
            return try await files.shortcutFile(for: entry)
        }
    }

    /// Runs a capture command, calling `hold` with its capture's ID as soon as it is kept; the capture's record once it is
    /// kept, or nil when it was cancelled or failed.
    private func kept(_ command: AutomationCommand, holding hold: @escaping (UUID) -> Void) async -> HistoryItem? {
        await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            run(command, { hold($0.id) }) { answer.give($0) }
        }
    }

    /// A shortcut's Capture Text: the text copied, or nil when none was.
    func captureText(keepsLineBreaks: Bool) async throws(ShortcutFailure) -> String? {
        used(keepsLineBreaks ? "captureText" : "captureTextJoined")
        try requireScreenRecording()
        captures.cancelSelfTimer()
        return await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            textCapture.captureText(joinLines: !keepsLineBreaks, allowsCloud: false) { answer.give($0) }
        }
    }

    /// The text in a picture a shortcut hands over, read as Capture Text reads it; nothing is copied or shown.
    func text(inImage data: Data, keepsLineBreaks: Bool) async throws -> String? {
        used(keepsLineBreaks ? "captureText" : "captureTextJoined")
        // A picture, without decoding it here.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw ShortcutFailure.unreadableImage
        }
        // Without the text reader in the app, read it here from memory, as nothing then needs it in a file; decoded off
        // the main thread, as a large photo takes a while.
        guard packs.helper != nil else {
            guard let loaded = await TextCaptureCoordinator.load(.data(data), fallbackScale: 1) else { throw ShortcutFailure.unreadableImage }
            return await textCapture.text(in: loaded.image, joinLines: !keepsLineBreaks)
        }
        let file = FileManager.default.temporaryDirectory.appending(path: "OhMyShot Shortcut \(UUID().uuidString)")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await textCapture.text(ofPictureAt: file, joinLines: !keepsLineBreaks)
    }

    /// A shortcut's Capture Formula: the LaTeX copied, or nil when no formula was.
    func captureFormula() async throws(ShortcutFailure) -> String? {
        used("captureFormula")
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
        used("captureFormula")
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
        used("pinImage")
        let scale = displays.layout.displayUnderPointer?.pixelsPerPoint ?? 2
        guard let loaded = ImageLoader.load(data: data, fallbackScale: scale) else { throw .unreadableImage }
        pins.pin(loaded.image, scale: loaded.scale, origin: .clipboard)
    }

    /// Opens a picture a shortcut hands over in the editor, added to the history first.
    func annotate(_ data: Data, name: String) async throws(ShortcutFailure) {
        used("openAnnotate")
        guard let loaded = ImageLoader.load(data: data) else { throw .unreadableImage }
        await openInEditor(loaded, name)
    }

    /// Runs a URL API command for a shortcut.
    func perform(_ command: AutomationCommand) throws(ShortcutFailure) {
        if command.readsScreen { try requireScreenRecording(for: command) }
        run(command, nil, nil)
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
