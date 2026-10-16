import Foundation

/// How loud the sound of a kept recording is against the recording's own: from silence (0) to full (1).
public enum RecordingVolume {
    /// From here up the sound counts as full and is left as it was. The recording window's slider moves in
    /// whole percents, so its last step is full; the window and the export both decide what is an edit by this.
    public static let full = 0.995

    public static func isFull(_ volume: Double) -> Bool {
        volume >= full
    }
}
