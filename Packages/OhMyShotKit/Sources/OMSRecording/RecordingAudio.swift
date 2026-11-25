import Foundation
import OMSCore
import OSLog

extension RecordingAudio.Microphone {
    /// Resolves `id` (its unique ID; empty for the system's default) to an attached microphone, reporting
    /// `fellBack == true` when a specifically chosen microphone was disconnected and fell back to the default.
    public static func resolve(_ id: String) -> (microphone: Self, fellBack: Bool) {
        guard !id.isEmpty else { return (.systemDefault, false) }
        guard Microphones.available().devices.contains(where: { $0.id == id }) else {
            Log.recording.notice("The chosen microphone is not attached; recording the default one")
            return (.systemDefault, true)
        }
        return (.device(id), false)
    }

    /// The microphone to record for the one Settings name (its unique ID; empty for the system's default): that one
    /// while it is attached, else the system's default. The attached ones are looked up only for a microphone named, as
    /// looking them up starts the system's capture machinery.
    public static func chosen(_ id: String) -> Self {
        resolve(id).microphone
    }
}
