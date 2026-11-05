import Foundation
import OMSCore
import OSLog

extension RecordingAudio.Microphone {
    /// The microphone to record for the one Settings name (its unique ID; empty for the system's default): that one
    /// while it is attached, else the system's default. The attached ones are looked up only for a microphone named, as
    /// looking them up starts the system's capture machinery.
    public static func chosen(_ id: String) -> Self {
        guard !id.isEmpty else { return .systemDefault }
        guard Microphones.available().devices.contains(where: { $0.id == id }) else {
            Log.recording.notice("The chosen microphone is not attached; recording the default one")
            return .systemDefault
        }
        return .device(id)
    }
}
