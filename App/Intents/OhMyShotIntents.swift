import AppIntents
import Foundation
import OMSCore
import UniformTypeIdentifiers

// The app's actions in Shortcuts and Spotlight. They run what the menu, the keyboard shortcuts, and the URL API run,
// and need no caller's approval: the user made the shortcut. A capture hands its picture on to the next action, and
// Capture Text its text, which the URL API cannot.

/// Hands the actions the composition root, once the app has started: a shortcut can launch the app, and its action
/// then waits for the start, which can itself wait for a quitting copy of the app.
enum ShortcutsBridge {
    private static var root: CompositionRoot?
    private static var waiting: [CheckedContinuation<CompositionRoot, Never>] = []

    static func started(_ root: CompositionRoot) {
        self.root = root
        for continuation in waiting { continuation.resume(returning: root) }
        waiting = []
    }

    static func current() async -> CompositionRoot {
        if let root { return root }
        return await withCheckedContinuation { waiting.append($0) }
    }
}

// MARK: - Choices

/// What happens to a capture after it is taken, beside what Settings says: the URL API's `action`.
nonisolated enum AfterCaptureOption: String, AppEnum {
    case copy
    case save
    case annotate
    case upload
    case pin

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "After Capture"
    static let caseDisplayRepresentations: [AfterCaptureOption: DisplayRepresentation] = [
        .copy: DisplayRepresentation(title: "Copy", image: .init(systemName: "doc.on.doc")),
        .save: DisplayRepresentation(title: "Save", image: .init(systemName: "square.and.arrow.down")),
        .annotate: DisplayRepresentation(title: "Annotate", image: .init(systemName: "pencil.tip.crop.circle")),
        .upload: DisplayRepresentation(title: "Upload", image: .init(systemName: "icloud.and.arrow.up")),
        .pin: DisplayRepresentation(title: "Pin", image: .init(systemName: "pin")),
    ]

    var action: CaptureAction {
        switch self {
        case .copy: .copy
        case .save: .save
        case .annotate: .annotate
        case .upload: .upload
        case .pin: .pin
        }
    }
}

nonisolated enum DesktopIconsOption: String, AppEnum {
    case hide
    case show
    case toggle

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Desktop Icons"
    static let caseDisplayRepresentations: [DesktopIconsOption: DisplayRepresentation] = [
        .hide: "Hide",
        .show: "Show",
        .toggle: "Toggle",
    ]
}

/// What an action tells Shortcuts when it cannot run.
nonisolated enum ShortcutFailure: Error, CustomLocalizedStringResourceConvertible {
    case needsScreenRecording
    case noUploadDestination
    case unreadableImage

    init(_ error: any Error) {
        switch error as? CompositionRoot.ShortcutError {
        case .needsScreenRecording: self = .needsScreenRecording
        case .noUploadDestination: self = .noUploadDestination
        case .unreadableImage, nil: self = .unreadableImage
        }
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .needsScreenRecording: "OhMyShot needs Screen Recording permission. Turn it on in System Settings › Privacy & Security, then try again."
        case .noUploadDestination: "No upload destination is set up. Add one in OhMyShot’s Settings › Sharing."
        case .unreadableImage: "The image couldn’t be read."
        }
    }
}

// MARK: - Capturing

/// Runs a capture action and hands its picture on; nothing when it was cancelled.
@MainActor
private func capture(_ kind: CompositionRoot.ShortcutCapture, then after: AfterCaptureOption?) async throws -> some IntentResult & ReturnsValue<IntentFile?> {
    let root = await ShortcutsBridge.current()
    let entry: HistoryItem?
    do {
        entry = try await root.captureForShortcut(kind, action: after?.action)
    } catch {
        throw ShortcutFailure(error)
    }
    guard let entry else { return .result(value: nil) }
    // Read now: with Keep Captures at Never, the file goes once its card does.
    let file = try await root.fileForShortcut(entry)
    return .result(value: IntentFile(data: file.data, filename: file.name, type: file.type))
}

struct CaptureAreaIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Area"
    static let description = IntentDescription("Choose an area of the screen and capture it. The screenshot is passed to the next action.")

    @Parameter(title: "After Capture", description: "Done to the screenshot besides what Settings says.")
    var after: AfterCaptureOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Capture an area, then \(\.$after)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile?> {
        try await capture(.area, then: after)
    }
}

struct CaptureWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Window"
    static let description = IntentDescription("Click a window to capture it with its shadow. The screenshot is passed to the next action.")

    @Parameter(title: "After Capture", description: "Done to the screenshot besides what Settings says.")
    var after: AfterCaptureOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Capture a window, then \(\.$after)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile?> {
        try await capture(.window, then: after)
    }
}

struct CaptureFullscreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Fullscreen"
    static let description = IntentDescription("Capture the whole display under the pointer. The screenshot is passed to the next action.")

    @Parameter(title: "After Capture", description: "Done to the screenshot besides what Settings says.")
    var after: AfterCaptureOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Capture the screen, then \(\.$after)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile?> {
        try await capture(.fullscreen, then: after)
    }
}

struct CapturePreviousAreaIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Previous Area"
    static let description = IntentDescription("Capture the area chosen last again, as it is on screen now. The screenshot is passed to the next action.")

    @Parameter(title: "After Capture", description: "Done to the screenshot besides what Settings says.")
    var after: AfterCaptureOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Capture the previous area, then \(\.$after)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile?> {
        try await capture(.previousArea, then: after)
    }
}

struct SelfTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Self-Timer"
    static let description = IntentDescription("Choose an area or a window; it is captured once the Self-Timer delay is over. The screenshot is passed to the next action.")

    @Parameter(title: "After Capture", description: "Done to the screenshot besides what Settings says.")
    var after: AfterCaptureOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Capture with the Self-Timer, then \(\.$after)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile?> {
        try await capture(.selfTimer, then: after)
    }
}

// MARK: - Text

struct CaptureTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Capture Text"
    static let description = IntentDescription("Drag over text on screen to copy it. The text is passed to the next action.")

    @Parameter(title: "Keep Line Breaks", default: true)
    var keepsLineBreaks: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Capture text on screen") {
            \.$keepsLineBreaks
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String?> {
        let root = await ShortcutsBridge.current()
        do {
            return .result(value: try await root.captureTextForShortcut(keepsLineBreaks: keepsLineBreaks))
        } catch {
            throw ShortcutFailure(error)
        }
    }
}

struct RecognizeTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Recognize Text in Image"
    static let description = IntentDescription("Read the text in an image on this Mac, as Capture Text reads the screen. Nothing is copied.")

    @Parameter(title: "Image", supportedContentTypes: [.image])
    var image: IntentFile

    @Parameter(title: "Keep Line Breaks", default: true)
    var keepsLineBreaks: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Recognize text in \(\.$image)") {
            \.$keepsLineBreaks
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String?> {
        let root = await ShortcutsBridge.current()
        do {
            return .result(value: try await root.textForShortcut(inImage: image.data, keepsLineBreaks: keepsLineBreaks))
        } catch {
            throw ShortcutFailure(error)
        }
    }
}

// MARK: - Pictures

struct PinImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Pin Image"
    static let description = IntentDescription("Keep an image on screen above every window.")

    @Parameter(title: "Image", supportedContentTypes: [.image])
    var image: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Pin \(\.$image)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let root = await ShortcutsBridge.current()
        do {
            try root.pinForShortcut(image.data)
        } catch {
            throw ShortcutFailure(error)
        }
        return .result()
    }
}

struct AnnotateImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Annotate Image"
    static let description = IntentDescription("Open an image in the annotation editor. It is added to Capture History.")

    @Parameter(title: "Image", supportedContentTypes: [.image])
    var image: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Annotate \(\.$image)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let root = await ShortcutsBridge.current()
        let name = image.filename.isEmpty ? "Shortcut" : (image.filename as NSString).deletingPathExtension
        do {
            try await root.annotateForShortcut(image.data, name: name)
        } catch {
            throw ShortcutFailure(error)
        }
        return .result()
    }
}

// MARK: - Modes

struct RecordScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Screen"
    static let description = IntentDescription("Choose an area, a window, or the whole screen to record. While recording, stops it.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await run(.recordScreen(AutomationRegion()))
        return .result()
    }
}

struct ScrollingCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Scrolling Capture"
    static let description = IntentDescription("Choose the part of the screen that scrolls and capture all of it. While capturing, finishes it.")

    @Parameter(title: "Auto-scroll", default: false)
    var autoScrolls: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Start a scrolling capture") {
            \.$autoScrolls
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await run(.scrollingCapture(AutomationRegion(), start: false, autoscroll: autoScrolls))
        return .result()
    }
}

struct OpenHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Capture History"
    static let description = IntentDescription("Open the window with every capture kept.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await run(.openHistory)
        return .result()
    }
}

struct DesktopIconsIntent: AppIntent {
    static let title: LocalizedStringResource = "Hide or Show Desktop Icons"
    static let description = IntentDescription("Cover the desktop icons with the wallpaper, or show them again. Windows stay above.")

    @Parameter(title: "Desktop Icons", default: .toggle)
    var operation: DesktopIconsOption

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$operation) desktop icons")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        switch operation {
        case .hide: try await run(.hideDesktopIcons)
        case .show: try await run(.showDesktopIcons)
        case .toggle: try await run(.toggleDesktopIcons)
        }
        return .result()
    }
}

@MainActor
private func run(_ command: AutomationCommand) async throws {
    let root = await ShortcutsBridge.current()
    do {
        try root.performForShortcut(command)
    } catch {
        throw ShortcutFailure(error)
    }
}

// MARK: - Spotlight and Siri

nonisolated struct OhMyShotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureAreaIntent(),
            phrases: ["Capture an area with \(.applicationName)", "Take a screenshot with \(.applicationName)"],
            shortTitle: "Capture Area",
            systemImageName: "rectangle.dashed"
        )
        AppShortcut(
            intent: CaptureWindowIntent(),
            phrases: ["Capture a window with \(.applicationName)"],
            shortTitle: "Capture Window",
            systemImageName: "macwindow"
        )
        AppShortcut(
            intent: CaptureFullscreenIntent(),
            phrases: ["Capture the screen with \(.applicationName)"],
            shortTitle: "Capture Fullscreen",
            systemImageName: "display"
        )
        AppShortcut(
            intent: CaptureTextIntent(),
            phrases: ["Capture text with \(.applicationName)", "Copy text on screen with \(.applicationName)"],
            shortTitle: "Capture Text",
            systemImageName: "text.viewfinder"
        )
        AppShortcut(
            intent: RecordScreenIntent(),
            phrases: ["Record the screen with \(.applicationName)"],
            shortTitle: "Record Screen",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: ScrollingCaptureIntent(),
            phrases: ["Start a scrolling capture with \(.applicationName)"],
            shortTitle: "Scrolling Capture",
            systemImageName: "arrow.up.and.down.text.horizontal"
        )
        AppShortcut(
            intent: OpenHistoryIntent(),
            phrases: ["Open \(.applicationName) capture history"],
            shortTitle: "Capture History",
            systemImageName: "clock.arrow.circlepath"
        )
        AppShortcut(
            intent: DesktopIconsIntent(),
            phrases: ["Hide desktop icons with \(.applicationName)", "Toggle desktop icons with \(.applicationName)"],
            shortTitle: "Desktop Icons",
            systemImageName: "eye.slash"
        )
    }
}
