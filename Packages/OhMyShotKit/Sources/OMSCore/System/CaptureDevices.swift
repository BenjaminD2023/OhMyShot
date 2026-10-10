import AVFoundation

/// The microphones the Mac has now. Looked up only when asked, since looking them up starts the system's
/// capture machinery.
public enum Microphones {
    public struct Device: Equatable, Sendable {
        /// The device's unique ID, which ScreenCaptureKit takes for the microphone it records.
        public let id: String
        public let name: String
    }

    /// Every microphone, built in and attached, and which one the system uses by default.
    public static func available() -> (devices: [Device], defaultID: String?) {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        let devices = session.devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
        return (devices, AVCaptureDevice.default(for: .audio)?.uniqueID)
    }
}

/// The cameras the Mac has now, built in, attached, and iPhones nearby (Continuity Camera). Looked up only
/// when asked, as microphones are.
public enum Cameras {
    public struct Device: Equatable, Sendable {
        public let id: String
        public let name: String
    }

    public static func available() -> (devices: [Device], defaultID: String?) {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified
        )
        let devices = session.devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
        return (devices, AVCaptureDevice.default(for: .video)?.uniqueID)
    }
}
