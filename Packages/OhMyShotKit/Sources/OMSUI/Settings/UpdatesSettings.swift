import Foundation
import Observation
import OMSCore
import SwiftUI

/// What the app's updater has for Settings › General and the menu bar menu. The app makes one only when its build looks
/// for updates (a release build, which has a feed); without it both leave updates out.
@MainActor
@Observable
public final class UpdateStatus {
    /// The newer version a check of the app's own found, waiting until the person looks at it: the menu names it
    /// rather than a window coming up in front of what they are doing.
    public var waiting: String?
    /// When the updater last looked, whoever asked it to.
    public var lastCheck: Date?
    /// False while the updater is busy and can't be asked again, such as while it fetches the feed by itself.
    public var canCheck = true
    /// Looks now, in the updater's own windows: what it found, or that this is the newest version. Set by the app.
    @ObservationIgnored public var checkNow: () -> Void = {}

    public init() {}
}

/// Settings › General › Updates: whether the app looks by itself, and a check now.
struct UpdatesRow: View {
    @Bindable var settings: SettingsStore
    let updates: UpdateStatus

    /// Its part of its group's help, which General's first row holds.
    static var help: HelpTopic {
        HelpTopic(String(localized: "Check for updates automatically", bundle: .module), Text("About once a day, OhMyShot asks GitHub whether there is a newer version. It asks you before it downloads anything.", bundle: .module))
    }

    var body: some View {
        SettingsRow(String(localized: "Updates", bundle: .module)) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $settings.checksForUpdates) {
                    Text("Check for updates automatically", bundle: .module)
                }
                HStack(spacing: 8) {
                    Button {
                        updates.checkNow()
                    } label: {
                        if updates.waiting == nil {
                            Text("Check Now", bundle: .module)
                        } else {
                            Text("Show Update…", bundle: .module)
                        }
                    }
                    .disabled(!updates.canCheck)
                    if let waiting = updates.waiting {
                        Text("Version \(waiting) is available.", bundle: .module)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if let lastCheck = updates.lastCheck {
                        Text("Last checked \(lastCheck, format: .relative(presentation: .named))", bundle: .module)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
