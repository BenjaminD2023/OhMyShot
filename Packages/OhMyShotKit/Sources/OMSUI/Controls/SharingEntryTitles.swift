import Foundation
import OMSCore

/// What the sharing entries of a capture's menu and VoiceOver actions are called and draw, for a Quick Access card
/// and History alike: which entries there are is `UploadMenu.entries(state:hasLink:canDelete:)`.
extension SharingEntry {
    /// The entry's name in a menu, where one that asks before it acts ends in an ellipsis. Upload To names the
    /// submenu of destinations.
    var menuTitle: String {
        switch self {
        case .cancelUpload: String(localized: "Cancel Upload", bundle: .module)
        case .retryUpload: String(localized: "Retry Upload", bundle: .module)
        case .copyError: String(localized: "Copy Error", bundle: .module)
        case .upload(nil): String(localized: "Upload", bundle: .module)
        case .upload(let name?): String(localized: "Upload to \(name)", bundle: .module)
        case .uploadTo: String(localized: "Upload To", bundle: .module)
        case .copyLink: String(localized: "Copy Link", bundle: .module)
        case .deleteFromStorage: String(localized: "Delete from Storage…", bundle: .module)
        }
    }

    /// The entry's name as an action VoiceOver reads, which asks nothing more of the reader: no ellipsis. Upload To
    /// is an action for each destination instead (`uploadTitle(to:)`).
    var actionTitle: String {
        switch self {
        case .deleteFromStorage: String(localized: "Delete from Storage", bundle: .module)
        default: menuTitle
        }
    }

    /// The action that uploads to one destination, for VoiceOver, where Upload To has no submenu.
    static func uploadTitle(to target: UploadTarget) -> String {
        String(localized: "Upload to \(target.name)", bundle: .module)
    }

    /// The symbol a card's menu draws beside the entry.
    var symbolName: String {
        switch self {
        case .cancelUpload: "xmark.circle"
        case .retryUpload: "arrow.clockwise"
        case .copyError: "doc.on.clipboard"
        case .upload, .uploadTo: "icloud.and.arrow.up"
        case .copyLink: "link"
        case .deleteFromStorage: "icloud.slash"
        }
    }
}
