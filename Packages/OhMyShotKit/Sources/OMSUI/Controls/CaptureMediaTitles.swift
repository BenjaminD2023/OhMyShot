import Foundation
import OMSCore

/// What opening a capture in its window is called and draws, on a Quick Access card and in History alike: a
/// picture is marked up in the editor, a movie trimmed and made smaller in the recording window, and a GIF, which
/// that window only plays, is played.
extension CaptureMedia {
    /// As a button names it.
    var openTitle: String {
        switch self {
        case .screenshot: String(localized: "Annotate", bundle: .module)
        case .movie: String(localized: "Edit", bundle: .module)
        case .gif: String(localized: "Play", bundle: .module)
        }
    }

    /// As a menu names it, where one that opens a window to go on in ends in an ellipsis: playing a GIF asks nothing more.
    var openMenuTitle: String {
        switch self {
        case .screenshot: String(localized: "Annotate…", bundle: .module)
        case .movie: String(localized: "Edit…", bundle: .module)
        case .gif: String(localized: "Play", bundle: .module)
        }
    }

    var openSymbolName: String {
        switch self {
        case .screenshot: "pencil.and.scribble"
        case .movie: "timeline.selection"
        case .gif: "play"
        }
    }
}
