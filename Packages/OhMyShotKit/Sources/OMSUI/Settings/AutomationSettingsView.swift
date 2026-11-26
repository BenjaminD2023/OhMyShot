import AppKit
import Foundation
import Observation
import OMSCore
import SwiftUI

/// Session-scoped list of callers refused during this run, shared between `AutomationController` and Settings so
/// users can unblock or approve a refused app without relaunching OhMyShot.
@MainActor
@Observable
public final class AutomationDeniedStore {
    public static let shared = AutomationDeniedStore()
    public private(set) var callers: [String] = []
    @ObservationIgnored public var onRemove: ((String) -> Void)?
    @ObservationIgnored public var onClear: (() -> Void)?

    public init() {}

    public func recordDenied(_ identifier: String) {
        guard !callers.contains(identifier) else { return }
        callers.append(identifier)
    }

    public func remove(_ identifier: String) {
        callers.removeAll { $0 == identifier }
        onRemove?(identifier)
    }

    public func clear() {
        callers.removeAll()
        onClear?()
    }
}

struct AutomationSettingsView: View {
    @Bindable var settings: SettingsStore
    let urlScheme: String
    var deniedStore: AutomationDeniedStore = .shared

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
            SettingsRow(String(localized: "Blocked apps", bundle: .module)) {
                if deniedStore.callers.isEmpty {
                    Text("None", bundle: .module)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(deniedStore.callers, id: \.self) { identifier in
                            HStack(spacing: 8) {
                                Text(Self.displayName(for: identifier))
                                    .help(identifier)
                                Button {
                                    deniedStore.remove(identifier)
                                    if !settings.approvedAutomationCallers.contains(identifier) {
                                        settings.approvedAutomationCallers.append(identifier)
                                    }
                                } label: {
                                    Text("Allow", bundle: .module)
                                }
                                .controlSize(.small)
                                Button {
                                    deniedStore.remove(identifier)
                                } label: {
                                    Text("Clear", bundle: .module)
                                }
                                .controlSize(.small)
                            }
                        }
                        if deniedStore.callers.count > 1 {
                            Button {
                                deniedStore.clear()
                            } label: {
                                Text("Clear All", bundle: .module)
                            }
                            .controlSize(.small)
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
