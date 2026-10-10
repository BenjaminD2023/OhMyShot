import CoreGraphics
import OMSCore

/// What a recording takes: part of a display, a window on its own, or a whole display.
public enum RecordingTarget: Equatable, Sendable {
    /// An area of one display, in AppKit's global space.
    case area(CGRect)
    /// One window, wherever it goes, without what covers it.
    case window(WindowTarget)
    /// The whole display the choice was made on.
    case display
}

/// What the recording bar sets before a recording starts; remembered between recordings.
public struct RecordingChoices: Equatable, Sendable {
    /// What the Mac plays.
    public var systemAudio: Bool
    /// The microphone.
    public var microphone: Bool
    /// Clicks drawn as the system draws them.
    public var showsClicks: Bool

    public init(systemAudio: Bool = false, microphone: Bool = false, showsClicks: Bool = false) {
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.showsClicks = showsClicks
    }
}
