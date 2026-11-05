import Foundation

/// What a capture is to look at: a picture, a movie, or a GIF, the recording that plays by itself and is opened to
/// play rather than to edit. A capture's kind says picture or recording; which recording is its file's extension,
/// the rule the history keeps a GIF by (`HistoryStore.isRecording`), told here once for every view that asks.
public enum CaptureMedia: Sendable, Equatable {
    case screenshot
    case movie
    case gif

    public init(kind: HistoryItem.Kind, fileExtension: String) {
        switch kind {
        case .screenshot: self = .screenshot
        case .recording: self = fileExtension.lowercased() == "gif" ? .gif : .movie
        }
    }

    /// A recording's media, from its file.
    public init(recordingAt url: URL) {
        self.init(kind: .recording, fileExtension: url.pathExtension)
    }
}

extension QuickAccessItem {
    public var media: CaptureMedia { CaptureMedia(kind: kind, fileExtension: fileURL.pathExtension) }
}

extension HistoryItem {
    public var media: CaptureMedia { CaptureMedia(kind: kind, fileExtension: (fileName as NSString).pathExtension) }
}
