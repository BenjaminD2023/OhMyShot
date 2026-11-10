import Foundation
import OMSCore
import OSLog
import SwiftUI

/// Settings › General: the app itself, and how long captures are kept.
struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore
    let openHistory: () -> Void
    var showOnboarding: () -> Void = {}
    let expiredCount: (HistoryRetention) -> Int
    /// The updater's state, in builds that look for updates.
    let updates: UpdateStatus?
    @State private var launchAtLogin = false
    @State private var loadedLaunchAtLogin = false
    @State private var loginItemError: String?
    @State private var retentionRequest: RetentionChangeRequest?
    @State private var language = AppLanguage.chosen ?? ""
    @State private var confirmsReset = false

    var body: some View {
        SettingsPane {
            SettingsRow(String(localized: "Language", bundle: .module), help: help) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(selection: $language) {
                        Text("System default", bundle: .module).tag("")
                        Divider()
                        ForEach(AppLanguage.available, id: \.self) { code in
                            Text(verbatim: AppLanguage.displayName(code)).tag(code)
                        }
                    } label: {
                        Text("Language", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: language) { _, code in
                        AppLanguage.chosen = code.isEmpty ? nil : code
                    }
                    if (language.isEmpty ? nil : language) != AppLanguage.atLaunch {
                        HStack(spacing: 8) {
                            Text("The new language shows after OhMyShot relaunches.", bundle: .module)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button {
                                Relauncher.relaunch()
                            } label: {
                                Text("Relaunch Now", bundle: .module)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            SettingsRow(String(localized: "Startup", bundle: .module)) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $launchAtLogin) {
                        Text("Launch at login", bundle: .module)
                    }
                    .task {
                        guard !loadedLaunchAtLogin else { return }
                        loadedLaunchAtLogin = true
                        launchAtLogin = LoginItem.isEnabled
                    }
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard loadedLaunchAtLogin, enabled != LoginItem.isEnabled else { return }
                        do {
                            try LoginItem.setEnabled(enabled)
                            loginItemError = nil
                        } catch {
                            Log.app.error("Launch at login couldn’t be turned \(enabled ? "on" : "off", privacy: .public): \(error.localizedDescription, privacy: .public)")
                            loginItemError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                    if let loginItemError {
                        // What went wrong in the app's words, the system's own reason on the pointer, and where to do it.
                        SettingsWarning(Text("Couldn’t change Launch at login. You can turn OhMyShot on or off in System Settings.", bundle: .module))
                            .help(loginItemError)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            LoginItem.openSettings()
                        } label: {
                            Text("Open System Settings", bundle: .module)
                        }
                    }
                }
            }
            if let updates {
                UpdatesRow(settings: settings, updates: updates)
            }
            SettingsRow(String(localized: "Menu bar", bundle: .module)) {
                Toggle(isOn: $settings.showMenuBarIcon) {
                    Text("Show icon", bundle: .module)
                }
            }
            SettingsRow(String(localized: "Sound", bundle: .module)) {
                Toggle(isOn: $settings.playSounds) {
                    Text("Play sounds", bundle: .module)
                }
            }

            SettingsDivider()

            SettingsRow(String(localized: "Keep captures", bundle: .module)) {
                HStack(spacing: 8) {
                    Picker(selection: retentionSelection(settings: settings, expiredCount: expiredCount, request: $retentionRequest)) {
                        ForEach(HistoryRetention.allCases, id: \.self) { retention in
                            Text(retention.title).tag(retention)
                        }
                    } label: {
                        Text("Keep captures", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button(action: openHistory) {
                        Text("Open Capture History", bundle: .module)
                    }
                }
            }

            SettingsDivider()

            SettingsRow(String(localized: "Reset", bundle: .module)) {
                Button {
                    confirmsReset = true
                } label: {
                    Text("Reset to Default Settings…", bundle: .module)
                }
            }
            SettingsRow(String(localized: "Getting Started", bundle: .module)) {
                Button(action: showOnboarding) {
                    Text("Show the Getting Started Guide…", bundle: .module)
                }
            }
        }
        .confirmingRetentionChange($retentionRequest) { retention in
            settings.historyRetention = retention
        }
        .confirmationDialog(
            Text("Reset all settings to their defaults?", bundle: .module),
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                settings.resetToDefaults()
            } label: {
                Text("Reset", bundle: .module)
            }
        } message: {
            Text("Every choice in Settings goes back to how it was when OhMyShot was installed. Your shortcuts, upload destinations, cloud reading, language, approved apps, and capture history stay as they are.", bundle: .module)
        }
    }

    /// What the first group explains.
    private var help: [HelpTopic] {
        var topics = [HelpTopic(String(localized: "Language", bundle: .module), Text("OhMyShot can show itself in a language other than the system’s. Missing your language? Translations are welcome on GitHub.", bundle: .module))]
        if updates != nil { topics.append(UpdatesRow.help) }
        topics.append(HelpTopic(String(localized: "Show icon", bundle: .module), Text("With the icon hidden, open OhMyShot again from Finder or Spotlight to come back here.", bundle: .module)))
        return topics
    }
}
