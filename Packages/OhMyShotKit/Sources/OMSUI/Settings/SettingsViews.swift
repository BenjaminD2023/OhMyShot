import AppKit
import Foundation
import KeyboardShortcuts
import OMSCore
import OMSOCR
import SwiftUI

private let formWidth: CGFloat = 520

struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore
    let openHistory: () -> Void
    let expiredCount: (HistoryRetention) -> Int
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var retentionRequest: RetentionChangeRequest?
    @State private var translationTargets: [Locale.Language] = []

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
                Toggle(isOn: $settings.copyAfterCapture) {
                    Text("Copy to the clipboard", bundle: .module)
                }
                Toggle(isOn: $settings.showQuickAccess) {
                    Text("Show Quick Access", bundle: .module)
                    Text("A card in the corner of the screen to copy, save, or drag the capture into another app.", bundle: .module)
                }
                Toggle(isOn: $settings.saveAfterCapture) {
                    Text("Save automatically", bundle: .module)
                }
                LabeledContent {
                    Button {
                        chooseExportDirectory()
                    } label: {
                        Text("Choose…", bundle: .module)
                    }
                } label: {
                    Text("Save to", bundle: .module)
                    Text(exportPath)
                }
            } header: {
                Text("After capturing", bundle: .module)
            } footer: {
                if !settings.copyAfterCapture, !settings.showQuickAccess, !settings.saveAfterCapture {
                    Label {
                        if settings.historyRetention == .never {
                            Text("With all three off and history set to Never, captures are not kept anywhere.", bundle: .module)
                        } else {
                            Text("With all three off, captures go only to Capture History.", bundle: .module)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker(selection: retentionSelection(settings: settings, expiredCount: expiredCount, request: $retentionRequest)) {
                    ForEach(HistoryRetention.allCases, id: \.self) { retention in
                        Text(retention.title).tag(retention)
                    }
                } label: {
                    Text("Keep captures for", bundle: .module)
                    Text(retentionDescription)
                }
                LabeledContent {
                    Button(action: openHistory) {
                        Text("Open Capture History…", bundle: .module)
                    }
                } label: {
                    EmptyView()
                }
            } header: {
                Text("Capture History", bundle: .module)
            }
            Section {
                Toggle(isOn: $settings.showTextResult) {
                    Text("Show a preview after copying", bundle: .module)
                    Text("A card by the selection with the copied text and a switch for its line breaks.", bundle: .module)
                }
            } header: {
                Text("Capture Text", bundle: .module)
            } footer: {
                Text("Languages follow your preferred languages in System Settings.", bundle: .module)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker(selection: $settings.translationTarget) {
                    Text("Automatic", bundle: .module).tag("")
                    Divider()
                    ForEach(translationOptions, id: \.self) { identifier in
                        Text(verbatim: Translator.name(of: Locale.Language(identifier: identifier))).tag(identifier)
                    }
                } label: {
                    Text("Translate into", bundle: .module)
                    Text("Automatic picks the first of your preferred languages that the text isn’t already in.", bundle: .module)
                }
                .task { translationTargets = await Translator.targets() }
            } header: {
                Text("Translation", bundle: .module)
            } footer: {
                Text("Translation runs on this Mac. A language is downloaded the first time it’s needed.", bundle: .module)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $settings.freezeScreen) {
                    Text("Freeze the screen while selecting", bundle: .module)
                    Text("Keeps hover states and open menus in place until the capture is taken.", bundle: .module)
                }
                Toggle(isOn: $settings.playSounds) {
                    Text("Play sounds", bundle: .module)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: formWidth)
        .fixedSize(horizontal: false, vertical: true)
        .confirmingRetentionChange($retentionRequest) { retention in
            settings.historyRetention = retention
        }
    }
}

extension GeneralSettingsView {
    /// The languages to translate into, by identifier; the chosen one even before the list has loaded.
    fileprivate var translationOptions: [String] {
        var options = translationTargets.map(Translator.identifier(of:))
        let choice = settings.translationTarget
        if !choice.isEmpty, !options.contains(choice) { options.insert(choice, at: 0) }
        return options
    }

    fileprivate var retentionDescription: String {
        settings.historyRetention == .never
            ? String(localized: "Captures are deleted when their Quick Access card closes, unless you saved them.", bundle: .module)
            : String(localized: "Captures stay on this Mac until then, ready to restore to Quick Access. Choosing a shorter time, or Never, deletes older captures right away.", bundle: .module)
    }

    fileprivate var exportPath: String {
        var path = settings.exportDirectory.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    fileprivate func chooseExportDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.exportDirectory
        panel.prompt = String(localized: "Choose", bundle: .module)
        if panel.runModal() == .OK, let url = panel.url {
            settings.exportDirectory = url
        }
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
