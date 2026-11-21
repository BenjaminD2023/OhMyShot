import Foundation

/// How saving a copy of a capture ended: written, called off by the person (the name alert or the Save panel cancelled),
/// or failed, with why.
public enum SaveOutcome: Equatable, Sendable {
    case saved(URL)
    case cancelled
    case failed(ExportFailure)

    /// Where the copy went; nil when none was saved.
    public var url: URL? {
        if case .saved(let url) = self { url } else { nil }
    }

    /// Why the copy was not saved, when it failed.
    public var failure: ExportFailure? {
        if case .failed(let failure) = self { failure } else { nil }
    }

    /// Runs `save`, which returns where the copy went, and says how it ended: an error is a failure to write into
    /// `folder`, told by what went wrong; a cancelled task, or a person cancelling, is no failure.
    public static func saving(into folder: URL?, _ save: () async throws -> URL) async -> SaveOutcome {
        do {
            return .saved(try await save())
        } catch is CancellationError {
            return .cancelled
        } catch let error as CocoaError where error.code == .userCancelled {
            return .cancelled
        } catch {
            return .failed(.saving(error, into: folder))
        }
    }
}
