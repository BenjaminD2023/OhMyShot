import Foundation

/// What a window screenshot is put on.
public enum WindowBackground: String, CaseIterable, Codable, Sendable {
    /// The background every new screenshot gets (Settings › Screenshots › Background), or none.
    case asScreenshots
    /// None: the window alone, its corners clear, with its shadow when that is captured.
    case transparent
    /// The desktop picture around the window, as it is on screen.
    case desktopWallpaper

    /// What one window screenshot gets: this choice, or with Shift held as the window was clicked the other way
    /// round: no background where there would be one, the desktop picture where there would be none.
    public func resolved(automaticPreset: Bool, shiftHeld: Bool) -> Resolved {
        let chosen: Resolved = switch self {
        case .asScreenshots: automaticPreset ? .preset : .none
        case .transparent: .none
        case .desktopWallpaper: .wallpaper
        }
        guard shiftHeld else { return chosen }
        return chosen == .none ? .wallpaper : .none
    }

    public enum Resolved: Equatable, Sendable {
        case none
        /// The automatic background preset.
        case preset
        case wallpaper
    }
}
