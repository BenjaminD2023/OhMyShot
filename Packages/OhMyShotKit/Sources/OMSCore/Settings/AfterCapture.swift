import Foundation

/// What happens to a kept capture beyond Capture History: the four choices Settings has for screenshots and, apart
/// from them, for recordings.
public struct AfterCapture: Equatable, Sendable {
    /// Its picture or file goes on the clipboard.
    public var copies: Bool
    /// It gets a card in the corner of the screen.
    public var showsQuickAccess: Bool
    /// A copy is saved to the export location.
    public var saves: Bool
    /// It is uploaded to the default destination, when there is one.
    public var uploads: Bool

    public init(copies: Bool, showsQuickAccess: Bool, saves: Bool, uploads: Bool) {
        self.copies = copies
        self.showsQuickAccess = showsQuickAccess
        self.saves = saves
        self.uploads = uploads
    }
}

extension SettingsStore {
    /// The choices that apply to a capture of `kind`.
    public func afterCapture(for kind: HistoryItem.Kind) -> AfterCapture {
        switch kind {
        case .screenshot:
            AfterCapture(copies: copyAfterCapture, showsQuickAccess: showQuickAccess, saves: saveAfterCapture, uploads: uploadAfterCapture)
        case .recording:
            AfterCapture(copies: copyAfterRecording, showsQuickAccess: showRecordingQuickAccess, saves: saveAfterRecording, uploads: uploadAfterRecording)
        }
    }
}
