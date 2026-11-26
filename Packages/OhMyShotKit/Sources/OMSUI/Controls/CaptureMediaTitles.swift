import Foundation
import OMSCore

/// What opening a capture in its window is called and draws, on a Quick Access card and in History alike: a
/// picture is marked up in the editor, a movie trimmed and made smaller in the recording window (or filmed again
/// in Studio when it has a Studio project), and a GIF, which that window only plays, is played.
extension CaptureMedia {
    /// As a button names it.
    var openTitle: String {
        openTitle(isStudio: false)
    }

    /// As a button names it, distinguishing Studio recordings from plain movies.
    func openTitle(isStudio: Bool) -> String {
        switch self {
        case .screenshot: String(localized: "Annotate", bundle: .module)
        case .movie: isStudio ? String(localized: "Edit in Studio", bundle: .module) : String(localized: "Edit", bundle: .module)
        case .gif: String(localized: "Play", bundle: .module)
        }
    }

    /// As a menu names it, where one that opens a window to go on in ends in an ellipsis: playing a GIF asks nothing more.
    var openMenuTitle: String {
        openMenuTitle(isStudio: false)
    }

    /// As a menu names it, distinguishing Studio recordings from plain movies.
    func openMenuTitle(isStudio: Bool) -> String {
        switch self {
        case .screenshot: String(localized: "Annotate…", bundle: .module)
        case .movie: isStudio ? String(localized: "Edit in Studio…", bundle: .module) : String(localized: "Edit…", bundle: .module)
        case .gif: String(localized: "Play", bundle: .module)
        }
    }

    var openSymbolName: String {
        openSymbolName(isStudio: false)
    }

    /// The symbol for opening the capture, distinguishing Studio recordings from plain movies.
    func openSymbolName(isStudio: Bool) -> String {
        switch self {
        case .screenshot: "pencil.and.scribble"
        case .movie: isStudio ? "wand.and.sparkles" : "timeline.selection"
        case .gif: "play"
        }
    }

    /// Short badge title shown on Studio recordings so they stand apart from plain movies.
    static var studioBadgeTitle: String {
        String(localized: "Studio", bundle: .module)
    }
}

extension QuickAccessItem {
    /// Whether this recording has a Studio project bundle beside its history file.
    var hasStudioProject: Bool {
        kind == .recording && HistoryStore.hasStudioProject(forFileAt: fileURL)
    }

    var openTitle: String { media.openTitle(isStudio: hasStudioProject) }
    var openMenuTitle: String { media.openMenuTitle(isStudio: hasStudioProject) }
    var openSymbolName: String { media.openSymbolName(isStudio: hasStudioProject) }
}
