import CoreGraphics
import Foundation

/// What to do with a capture, named as in CleanShot X's URL API.
public enum CaptureAction: String, Sendable, CaseIterable {
    case copy
    case save
    case annotate
    case upload
    case pin
}

/// A region on one display, as the URL API describes it.
public struct AutomationRegion: Equatable, Sendable {
    /// Points in the display's local space with a bottom-left origin. `nil` asks the user to select.
    public var rect: CGRect?
    /// 1 is the primary display. `nil` means the display under the pointer.
    public var display: Int?

    public init(rect: CGRect? = nil, display: Int? = nil) {
        self.rect = rect
        self.display = display
    }
}

/// Every command of CleanShot X's URL API, with the same names and parameters, so scripts and
/// launchers switch over by changing only the scheme; plus OhMyShot's own commands.
public enum AutomationCommand: Equatable, Sendable {
    case allInOne(AutomationRegion)
    case captureArea(AutomationRegion, action: CaptureAction?)
    case capturePreviousArea(action: CaptureAction?)
    case captureFullscreen(action: CaptureAction?)
    case captureWindow(action: CaptureAction?)
    case selfTimer(action: CaptureAction?)
    case scrollingCapture(AutomationRegion, start: Bool, autoscroll: Bool)
    case pin(file: URL?)
    case recordScreen(AutomationRegion)
    case captureText(file: URL?, region: AutomationRegion, lineBreaks: Bool?)
    /// OhMyShot's own, with no CleanShot twin: needs the formula pack.
    case captureFormula(file: URL?, region: AutomationRegion)
    case annotateArea(AutomationRegion)
    case translateArea(AutomationRegion)
    case pickColor
    case measure
    case drawOnScreen
    case saveReplay
    case openAnnotate(file: URL?)
    case openFromClipboard
    /// OhMyShot's own: pins what the clipboard holds, as the menu's Pin from Clipboard does.
    case pinFromClipboard
    /// OhMyShot's own: hides every pin, or shows them again where they were.
    case togglePins
    case toggleDesktopIcons
    case hideDesktopIcons
    case showDesktopIcons
    case addQuickAccessOverlay(file: URL)
    case openHistory
    case restoreRecentlyClosed
    case openSettings(tab: SettingsTab)

    /// Whether the command captures the screen, which needs Screen Recording.
    public var readsScreen: Bool {
        switch self {
        case .allInOne, .captureArea, .capturePreviousArea, .captureFullscreen, .captureWindow, .selfTimer,
             .scrollingCapture, .recordScreen, .annotateArea, .translateArea, .pickColor, .measure, .saveReplay:
            true
        case .captureText(let file, _, _), .captureFormula(let file, _):
            file == nil
        case .pin, .drawOnScreen, .openAnnotate, .openFromClipboard, .pinFromClipboard, .togglePins, .toggleDesktopIcons,
             .hideDesktopIcons, .showDesktopIcons, .addQuickAccessOverlay, .openHistory, .restoreRecentlyClosed, .openSettings:
            false
        }
    }

    /// Files the command would read.
    public var fileURLs: [URL] {
        switch self {
        case .pin(let file), .openAnnotate(let file), .captureText(let file, _, _), .captureFormula(let file, _):
            file.map { [$0] } ?? []
        case .addQuickAccessOverlay(let file):
            [file]
        default:
            []
        }
    }
}
