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
    /// A movie or a GIF.
    public var output: RecordingOutput
    /// What the Mac plays; never in a GIF.
    public var systemAudio: Bool
    /// The microphone; never in a GIF.
    public var microphone: Bool
    /// Which microphone, by its unique ID; empty for the system's default input.
    public var microphoneID: String
    /// Clicks drawn as the system draws them.
    public var showsClicks: Bool
    /// The keys pressed, shown near the bottom of what is recorded; never in a window recording, which
    /// takes the window alone.
    public var showsKeystrokes: Bool
    /// The camera in a bubble over what is recorded; never in a window recording.
    public var camera: Bool
    /// Which camera, by its unique ID; empty for the system's default.
    public var cameraID: String
    public var cameraStyle: CameraStyle

    public init(
        output: RecordingOutput = .video, systemAudio: Bool = false, microphone: Bool = false, microphoneID: String = "",
        showsClicks: Bool = false, showsKeystrokes: Bool = false, camera: Bool = false, cameraID: String = "",
        cameraStyle: CameraStyle = CameraStyle()
    ) {
        self.output = output
        self.systemAudio = systemAudio
        self.microphone = microphone
        self.microphoneID = microphoneID
        self.showsClicks = showsClicks
        self.showsKeystrokes = showsKeystrokes
        self.camera = camera
        self.cameraID = cameraID
        self.cameraStyle = cameraStyle
    }

    /// Whether the recording takes what the Mac plays: chosen, and not a GIF.
    public var recordsSystemAudio: Bool {
        systemAudio && output.hasAudio
    }

    /// Whether the recording takes the microphone: chosen, and not a GIF.
    public var recordsMicrophone: Bool {
        microphone && output.hasAudio
    }
}
