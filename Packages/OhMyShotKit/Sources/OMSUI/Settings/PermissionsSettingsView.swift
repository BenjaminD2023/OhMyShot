import AppKit
import Foundation
import OMSCore
import SwiftUI

struct PermissionsSettingsView: View {
    let permissions: PermissionCenter
    let relaunch: () -> Void

    var body: some View {
        SettingsPane {
            PermissionRow(permission: .screenRecording, permissions: permissions)
            if permissions.status(of: .screenRecording) != .granted {
                SettingsRow {
                    HStack(spacing: 6) {
                        Text("macOS applies it after a relaunch.", bundle: .module)
                            .foregroundStyle(.secondary)
                        Button(action: relaunch) {
                            Text("Relaunch Now", bundle: .module)
                        }
                        .buttonStyle(.link)
                    }
                    .font(.callout)
                }
            }

            SettingsDivider()

            ForEach([Permission.microphone, .camera, .accessibility, .inputMonitoring]) { permission in
                PermissionRow(permission: permission, permissions: permissions)
            }
        }
        .onAppear {
            permissions.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            permissions.refresh()
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let permissions: PermissionCenter

    var body: some View {
        SettingsRow(permission.title, help: [HelpTopic(permission.title, Text(permission.purpose))]) {
            Group {
                switch permissions.status(of: permission) {
                case .granted:
                    Label {
                        Text("Allowed", bundle: .module)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .foregroundStyle(.secondary)
                case .notGranted:
                    Button {
                        Task {
                            await permissions.request(permission)
                            if permissions.status(of: permission) != .granted {
                                permissions.openSystemSettings(for: permission)
                            }
                        }
                    } label: {
                        Text("Allow…", bundle: .module)
                    }
                case .denied:
                    Button {
                        permissions.openSystemSettings(for: permission)
                    } label: {
                        Text("Open System Settings", bundle: .module)
                    }
                }
            }
        }
    }
}

extension Permission {
    var title: String {
        switch self {
        case .screenRecording: String(localized: "Screen Recording", bundle: .module)
        case .microphone: String(localized: "Microphone", bundle: .module)
        case .camera: String(localized: "Camera", bundle: .module)
        case .accessibility: String(localized: "Accessibility", bundle: .module)
        case .inputMonitoring: String(localized: "Input Monitoring", bundle: .module)
        }
    }

    /// Why OhMyShot asks for it, and what is left out without it: the row's help popover.
    var purpose: String {
        switch self {
        case .screenRecording: String(localized: "Needed for everything OhMyShot captures: screenshots, scrolling captures, and screen recordings. macOS applies it after a relaunch.", bundle: .module)
        case .microphone: String(localized: "Records your voice with screen recordings. Without it, recordings keep only the Mac’s sound.", bundle: .module)
        case .camera: String(localized: "Shows your camera in a bubble while you record, and keeps it as a movie of its own for Studio. Without it, recordings have no camera.", bundle: .module)
        case .accessibility: String(localized: "Lets Auto-scroll scroll the page for you during a scrolling capture, and lets Capture Text read the text an app shows instead of recognizing it in the picture. Without it, you scroll yourself and text is recognized from the picture.", bundle: .module)
        case .inputMonitoring: String(localized: "Shows the keys you press in screen recordings with Show Keystrokes, and keeps them so Studio can show them afterwards. Without it, no keys are shown or kept.", bundle: .module)
        }
    }
}
