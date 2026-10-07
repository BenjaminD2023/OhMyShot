import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Observation
import OSLog

/// The macOS privacy permissions OhMyShot can use. Only Screen Recording is needed to capture;
/// the others are requested the first time a feature needs them, never at launch.
public enum Permission: String, CaseIterable, Sendable, Identifiable {
    case screenRecording
    case microphone
    case camera
    /// Auto-scrolling during scrolling capture, and reading text from native apps.
    case accessibility
    /// Showing keystrokes in recordings.
    case inputMonitoring

    public var id: String { rawValue }

    /// The matching pane of System Settings › Privacy & Security.
    public var settingsURL: URL {
        let anchor = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .camera: "Privacy_Camera"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum PermissionStatus: Sendable, Equatable {
    case granted
    case denied
    /// Not granted yet. Screen Recording, Accessibility, and Input Monitoring cannot tell "never asked"
    /// from "turned off", so they report this until granted.
    case notGranted
}

/// Reads and requests permissions.
///
/// Statuses are read only on request, never all at launch: asking AVFoundation about the microphone
/// or camera initializes the whole capture stack, which loads every camera plug-in on the Mac and
/// costs seconds of CPU and megabytes of memory. Launch reads Screen Recording alone.
@MainActor
@Observable
public final class PermissionCenter {
    public private(set) var statuses: [Permission: PermissionStatus] = [:]

    public init() {}

    /// The last status read for a permission. Call `refresh` first to read it.
    public func status(of permission: Permission) -> PermissionStatus {
        statuses[permission] ?? .notGranted
    }

    /// Re-reads the given statuses, for example when a permissions screen appears or becomes key again.
    public func refresh(_ permissions: [Permission] = Permission.allCases) {
        var changes: [String] = []
        for permission in permissions {
            let status = Self.currentStatus(of: permission)
            if statuses[permission] != status {
                statuses[permission] = status
                changes.append("\(permission.rawValue)=\(String(describing: status))")
            }
        }
        if !changes.isEmpty {
            Log.permissions.notice("Permissions: \(changes.joined(separator: " "), privacy: .public)")
        }
    }

    /// Asks macOS for a permission. Screen Recording, Accessibility, and Input Monitoring prompt only
    /// once; after that the user has to switch them on in System Settings.
    public func request(_ permission: Permission) async {
        switch permission {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
        refresh([permission])
    }

    public func openSystemSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    private static func currentStatus(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        case .microphone:
            status(of: AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera:
            status(of: AVCaptureDevice.authorizationStatus(for: .video))
        case .accessibility:
            AXIsProcessTrusted() ? .granted : .notGranted
        case .inputMonitoring:
            CGPreflightListenEventAccess() ? .granted : .notGranted
        }
    }

    private static func status(of authorization: AVAuthorizationStatus) -> PermissionStatus {
        switch authorization {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notGranted
        @unknown default: .notGranted
        }
    }
}
