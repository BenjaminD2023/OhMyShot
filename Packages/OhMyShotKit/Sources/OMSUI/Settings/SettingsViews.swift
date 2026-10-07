import AppKit
import Foundation
import KeyboardShortcuts
import OMSCore
import SwiftUI

private let formWidth: CGFloat = 520

struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $launchAtLogin) {
                    Text("Launch at login", bundle: .module)
                }
                .onChange(of: launchAtLogin) { _, enabled in
                    guard enabled != LoginItem.isEnabled else { return }
                    do {
                        try LoginItem.setEnabled(enabled)
                        loginItemError = nil
                    } catch {
                        loginItemError = error.localizedDescription
                        launchAtLogin = LoginItem.isEnabled
                    }
                }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Toggle(isOn: $settings.showMenuBarIcon) {
                    Text("Show icon in the menu bar", bundle: .module)
                }
            } footer: {
                Text("With the icon hidden, open OhMyShot again from Finder or Spotlight to come back here.", bundle: .module)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $settings.playSounds) {
                    Text("Play sounds", bundle: .module)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: formWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            Section {
                ForEach(CaptureShortcut.allCases, id: \.self) { shortcut in
                    KeyboardShortcuts.Recorder(shortcut.title, name: shortcut.name)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macOS keeps ⇧⌘3, ⇧⌘4, and ⇧⌘5 for its own screenshots. Turn those off under Keyboard › Keyboard Shortcuts › Screenshots to use them here.", bundle: .module)
                        .foregroundStyle(.secondary)
                    Button {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    } label: {
                        Text("Open Keyboard Settings…", bundle: .module)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: formWidth)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct PermissionsSettingsView: View {
    let permissions: PermissionCenter
    let relaunch: () -> Void

    var body: some View {
        Form {
            Section {
                PermissionRow(permission: .screenRecording, permissions: permissions)
            } header: {
                Text("Required", bundle: .module)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("macOS applies Screen Recording only after OhMyShot restarts. It also asks you to confirm about once a month; that reminder comes from macOS.", bundle: .module)
                        .foregroundStyle(.secondary)
                    Button(action: relaunch) {
                        Text("Relaunch OhMyShot", bundle: .module)
                    }
                    .buttonStyle(.link)
                }
            }
            Section {
                ForEach([Permission.microphone, .camera, .accessibility, .inputMonitoring]) { permission in
                    PermissionRow(permission: permission, permissions: permissions)
                }
            } header: {
                Text("Asked for when a feature first needs it", bundle: .module)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: formWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            permissions.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            permissions.refresh()
        }
    }
}

struct PermissionRow: View {
    let permission: Permission
    let permissions: PermissionCenter

    var body: some View {
        LabeledContent {
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
                    Text("Open System Settings…", bundle: .module)
                }
            }
        } label: {
            Text(permission.title)
            Text(permission.purpose)
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

    var purpose: String {
        switch self {
        case .screenRecording: String(localized: "Take screenshots and record the screen.", bundle: .module)
        case .microphone: String(localized: "Record your voice with screen recordings.", bundle: .module)
        case .camera: String(localized: "Show your camera in screen recordings.", bundle: .module)
        case .accessibility: String(localized: "Scroll for you during scrolling capture, and read text straight from apps.", bundle: .module)
        case .inputMonitoring: String(localized: "Show the keys you press in screen recordings.", bundle: .module)
        }
    }
}

struct AutomationSettingsView: View {
    @Bindable var settings: SettingsStore
    let urlScheme: String

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.automationEnabled) {
                    Text("Allow other apps to control OhMyShot", bundle: .module)
                }
            } footer: {
                Text("Apps and scripts send commands such as \(urlScheme)://capture-area, with the same names and parameters as CleanShot X. Each app needs your approval the first time.", bundle: .module)
                    .foregroundStyle(.secondary)
            }
            Section {
                if settings.approvedAutomationCallers.isEmpty {
                    Text("No apps yet.", bundle: .module)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.approvedAutomationCallers, id: \.self) { identifier in
                        LabeledContent {
                            Button {
                                settings.approvedAutomationCallers.removeAll { $0 == identifier }
                            } label: {
                                Text("Remove", bundle: .module)
                            }
                        } label: {
                            Text(Self.displayName(for: identifier))
                            Text(identifier)
                        }
                    }
                }
            } header: {
                Text("Approved apps", bundle: .module)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: formWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The app's name for a bundle identifier.
    private static func displayName(for identifier: String) -> String {
        if identifier == AutomationCaller.commandLine.identifier {
            return String(localized: "Command-line tools", bundle: .module)
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            return identifier
        }
        return FileManager.default.displayName(atPath: url.path(percentEncoded: false))
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(Self.info("CFBundleDisplayName") ?? "OhMyShot")
                .font(.title2.weight(.semibold))
            Text("Version \(Self.info("CFBundleShortVersionString") ?? "?") (\(Self.info("CFBundleVersion") ?? "?"))", bundle: .module)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Free software under the GNU General Public License v3.", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding(28)
        .frame(width: formWidth)
    }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
