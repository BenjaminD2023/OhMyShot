import Foundation
import OMSCore
import SwiftUI

/// Settings › General: the app itself, and how long captures are kept.
struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore
    let openHistory: () -> Void
    var showOnboarding: () -> Void = {}
    let expiredCount: (HistoryRetention) -> Int
    var updates: SettingsDependencies.Updates? = nil
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
                            loginItemError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                    if let loginItemError {
                        Text(loginItemError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
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

            if let updates {
                let checks = updates.automaticallyChecks()
                let downloads = updates.automaticallyDownloads()
                SettingsRow(String(localized: "Updates", bundle: .module)) {
                    VStack(alignment: .leading, spacing: 6) {
                        UpdateCheckStatus(updates: updates.status)
                        Button(action: updates.check) {
                            Text("Check for Updates…", bundle: .module)
                        }
                        .disabled(!updates.canCheck())
                        Toggle(isOn: Binding(get: { checks }, set: { updates.setAutomaticallyChecks($0) })) {
                            Text("Automatically check for updates", bundle: .module)
                        }
                        Toggle(isOn: Binding(get: { downloads }, set: { updates.setAutomaticallyDownloads($0) })) {
                            Text("Automatically download and install updates", bundle: .module)
                        }
                        .disabled(!checks)
                    }
                }
            }

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
                        Text("Open History", bundle: .module)
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
        if updates != nil { topics.append(UpdateCheckStatus.help) }
        topics.append(HelpTopic(String(localized: "Show icon", bundle: .module), Text("With the icon hidden, open OhMyShot again from Finder or Spotlight to come back here.", bundle: .module)))
        return topics
    }
}
