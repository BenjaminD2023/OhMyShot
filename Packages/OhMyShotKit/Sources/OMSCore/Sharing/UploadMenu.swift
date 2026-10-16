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
}

public extension UploadDestinationStore {
    /// The destinations as menus list them, in the order the user arranged them.
    var targets: [UploadTarget] {
        destinations.map { UploadTarget(id: $0.id, name: $0.name, isDefault: $0.id == defaultDestinationID) }
    }

    var menu: UploadMenu { UploadMenu(targets: targets) }
}
