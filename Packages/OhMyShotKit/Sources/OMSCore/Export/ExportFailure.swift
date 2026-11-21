import Darwin
import Foundation

/// A copy of a capture that could not be written where it was going, saved or converted to be handed over, told as a
/// person reads it: a short sentence for a card's notice badge or the reading by the pointer, and the system's own
/// account of what went wrong, for a tooltip and VoiceOver.
public struct ExportFailure: Error, Equatable, Sendable {
    /// What was being made.
    public enum Step: Equatable, Sendable {
        /// A copy saved where the person asked.
        case saving
        /// The copy Settings ask for (a watermark, another format, 1×, sRGB, a border), to drag out, share, upload, or
        /// copy as a file.
        case converting
    }

    /// What went wrong, as far as a person can do something about it.
    public enum Cause: Equatable, Sendable {
        /// The folder is not there: its disk unplugged, its network share gone, or the folder removed.
        case folderUnavailable
        case diskFull
        case readOnly
        /// The folder may not be written to: its permissions, or the privacy protection macOS gives it.
        case noAccess
        /// The capture's own file is gone, so there is nothing to copy.
        case sourceMissing
        case other
    }

    public let step: Step
    public let cause: Cause
    /// The sentence a notice badge or the reading by the pointer shows, such as "Couldn’t save: the disk is full" or
    /// "Couldn’t prepare the picture".
    public let summary: String
    /// The system's description of the error, for a tooltip and VoiceOver.
    public let detail: String

    public init(step: Step = .saving, cause: Cause, summary: String, detail: String) {
        self.step = step
        self.cause = cause
        self.summary = summary
        self.detail = detail
    }

    /// Why saving a copy into `folder` failed with `error`.
    public static func saving(_ error: any Error, into folder: URL?) -> ExportFailure {
        let cause = cause(of: error, folder: folder)
        let summary = switch cause {
        case .folderUnavailable: String(localized: "Couldn’t save: the folder isn’t available", bundle: .module)
        case .diskFull: String(localized: "Couldn’t save: the disk is full", bundle: .module)
        case .readOnly: String(localized: "Couldn’t save: the disk is read-only", bundle: .module)
        case .noAccess: String(localized: "Couldn’t save: no access to the folder", bundle: .module)
        case .sourceMissing: String(localized: "Couldn’t save: the capture’s file is missing", bundle: .module)
        case .other: String(localized: "Couldn’t save", bundle: .module)
        }
        return ExportFailure(step: .saving, cause: cause, summary: summary, detail: error.localizedDescription)
    }

    /// Why the copy Settings ask for could not be made with `error`: nothing is handed over in its place.
    public static func converting(_ error: any Error) -> ExportFailure {
        let cause = cause(of: error, folder: nil)
        let summary = switch cause {
        case .diskFull: String(localized: "Couldn’t prepare the picture: the disk is full", bundle: .module)
        case .sourceMissing: String(localized: "Couldn’t prepare the picture: the capture’s file is missing", bundle: .module)
        default: String(localized: "Couldn’t prepare the picture", bundle: .module)
        }
        return ExportFailure(step: .converting, cause: cause, summary: summary, detail: error.localizedDescription)
    }

    /// What went wrong writing into `folder`: told first by a folder whose disk is gone, which the system reports as
    /// a folder it may not create, then by Foundation's code, then by the system call's.
    static func cause(of error: any Error, folder: URL?) -> Cause {
        if let folder, isOnMissingVolume(folder) { return .folderUnavailable }
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            switch CocoaError.Code(rawValue: error.code) {
            case .fileWriteOutOfSpace: return .diskFull
            case .fileWriteVolumeReadOnly: return .readOnly
            case .fileWriteNoPermission, .fileReadNoPermission: return .noAccess
            case .fileReadNoSuchFile: return .sourceMissing
            case .fileNoSuchFile: return .folderUnavailable
            default: break
            }
        }
        switch posixCode(of: error) {
        case ENOSPC, EDQUOT: return .diskFull
        case EROFS: return .readOnly
        case EACCES, EPERM: return .noAccess
        case ENOENT, ENOTDIR, ENXIO, ENODEV: return .folderUnavailable
        default: return .other
        }
    }

    /// Whether `folder` is on a disk that is not mounted now: under /Volumes, on a volume that is not there.
    static func isOnMissingVolume(_ folder: URL) -> Bool {
        let components = folder.standardizedFileURL.pathComponents
        guard components.count > 2, components[1] == "Volumes" else { return false }
        return !FileManager.default.fileExists(atPath: "/Volumes/\(components[2])")
    }

    /// The system call's error under Foundation's, however deep it is.
    private static func posixCode(of error: NSError) -> Int32? {
        var current: NSError? = error
        while let error = current {
            if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }
}
