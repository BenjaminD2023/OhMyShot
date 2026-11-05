import AppKit
import Foundation
import OMSCore
import SwiftUI

struct AutomationSettingsView: View {
    @Bindable var settings: SettingsStore
    let urlScheme: String

    var body: some View {
        SettingsPane {
            SettingsRow(String(localized: "URL scheme", bundle: .module), help: [
                HelpTopic(String(localized: "Allow other apps to control OhMyShot", bundle: .module), Text("Apps and scripts send commands such as \(urlScheme)://capture-area, with the same names and parameters as CleanShot X. Each app needs your approval the first time.", bundle: .module)),
            ]) {
                Toggle(isOn: $settings.automationEnabled) {
                    Text("Allow other apps to control OhMyShot", bundle: .module)
                }
            }
            SettingsRow(String(localized: "Approved apps", bundle: .module)) {
                if settings.approvedAutomationCallers.isEmpty {
                    Text("None yet", bundle: .module)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(settings.approvedAutomationCallers, id: \.self) { identifier in
                            HStack(spacing: 8) {
                                Text(Self.displayName(for: identifier))
                                    .help(identifier)
                                Button {
                                    settings.approvedAutomationCallers.removeAll { $0 == identifier }
                                } label: {
                                    Text("Remove", bundle: .module)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
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
