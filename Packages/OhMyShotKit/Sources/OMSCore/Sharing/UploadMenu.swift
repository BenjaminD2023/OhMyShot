import Foundation

/// A destination as a menu lists it.
public struct UploadTarget: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    /// The one a plain Upload goes to.
    public let isDefault: Bool

    public init(id: UUID, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

/// What a capture's menu offers for uploading, decided from the destinations alone.
///
/// With no destination set up nothing is offered anywhere in the capture interface: uploads are visible in
/// Settings only. The menus and the accessibility actions of cards and History all ask this one rule.
public enum UploadMenu: Equatable, Sendable {
    /// No destination: no Upload entry of any kind.
    case hidden
    /// One destination: an Upload that goes to it.
    case upload
    /// Several: Upload, to the default, and Upload To with every destination listed.
    case uploadWithChoice([UploadTarget])

    public init(targets: [UploadTarget]) {
        switch targets.count {
        case 0: self = .hidden
        case 1: self = .upload
        default: self = .uploadWithChoice(targets)
        }
    }

    public var isHidden: Bool { self == .hidden }

    /// Where a plain Upload goes with several destinations: the default, else the first. Nil with one, which a plain
    /// Upload goes to without naming it, or none.
    public var defaultTarget: UploadTarget? {
        guard case .uploadWithChoice(let targets) = self else { return nil }
        return targets.first(where: \.isDefault) ?? targets.first
    }

    /// The sharing entries of a capture's menu, and of its actions for VoiceOver, in the order they show: what a
    /// Quick Access card and History offer is this one list, which each draws in its own way.
    /// - Parameters:
    ///   - state: where the capture's upload stands.
    ///   - hasLink: whether an upload left a link to copy.
    ///   - canDelete: whether the upload can be removed from its storage.
    public func entries(state: UploadState, hasLink: Bool, canDelete: Bool) -> [SharingEntry] {
        var entries: [SharingEntry] = []
        switch state {
        case .uploading:
            entries.append(.cancelUpload)
        case .failed:
            // Retrying is uploading again: not offered once the last destination has been removed.
            if !isHidden { entries.append(.retryUpload) }
            entries.append(.copyError)
        case .idle:
            switch self {
            case .hidden:
                break
            case .upload:
                entries.append(.upload(named: nil))
            case .uploadWithChoice(let targets):
                // With several destinations the plain Upload says which one it goes to.
                entries.append(.upload(named: defaultTarget?.name))
                entries.append(.uploadTo(targets))
            }
        }
        if hasLink { entries.append(.copyLink) }
        if canDelete { entries.append(.deleteFromStorage) }
        return entries
    }
}

/// Where a capture's upload stands, as far as its sharing entries care.
public enum UploadState: Equatable, Sendable {
    /// None going: none began, or the last one finished.
    case idle
    case uploading
    /// The last one failed and its card waits on Retry. (History shows no failure: it is the card's.)
    case failed
}

/// One sharing entry of a capture's menu or VoiceOver actions. What it is called and the symbol it draws are the
/// interface's, which has the words in its languages; which entries there are, and in what order, is
/// `UploadMenu.entries(state:hasLink:canDelete:)`.
public enum SharingEntry: Equatable, Sendable {
    case cancelUpload
    case retryUpload
    /// Puts the failure's sentence on the clipboard.
    case copyError
    /// To the default destination: `named` it with several, so the entry says which one it goes to.
    case upload(named: String?)
    /// Every destination, to choose one: a submenu in a menu, an action each for VoiceOver.
    case uploadTo([UploadTarget])
    case copyLink
    /// Asks, then removes the upload from its storage.
    case deleteFromStorage
}

public extension UploadDestinationStore {
    /// The destinations as menus list them, in the order the user arranged them.
    var targets: [UploadTarget] {
        destinations.map { UploadTarget(id: $0.id, name: $0.name, isDefault: $0.id == defaultDestinationID) }
    }

    var menu: UploadMenu { UploadMenu(targets: targets) }
}
