import OMSCore
import SwiftUI

/// Settings › Quick Access: where the cards stand, how large they are, and whether they close by themselves.
struct QuickAccessSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsPane {
            SettingsRow(String(localized: "Position", bundle: .module), help: [
                HelpTopic(String(localized: "Show on the display with the pointer", bundle: .module), Text("Cards stand on the display the capture was taken on. With this on they stand on the display where the pointer is when the capture is taken.", bundle: .module)),
            ]) {
                Picker(selection: $settings.quickAccessCorner) {
                    Text("Bottom left", bundle: .module).tag(QuickAccessCorner.bottomLeft)
                    Text("Bottom right", bundle: .module).tag(QuickAccessCorner.bottomRight)
                } label: {
                    Text("Position", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(String(localized: "Size", bundle: .module)) {
                Picker(selection: $settings.quickAccessSize) {
                    Text("Small", bundle: .module).tag(QuickAccessSize.small)
                    Text("Medium", bundle: .module).tag(QuickAccessSize.medium)
                    Text("Large", bundle: .module).tag(QuickAccessSize.large)
                } label: {
                    Text("Size", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(String(localized: "Display", bundle: .module)) {
                Toggle(isOn: $settings.quickAccessOnPointerDisplay) {
                    Text("Show on the display with the pointer", bundle: .module)
                }
            }

            SettingsDivider()

            SettingsRow(String(localized: "Close cards", bundle: .module), help: [
                HelpTopic(String(localized: "Close cards", bundle: .module), Text("A card waits while the pointer is over it, its menu is open, it is being dragged, Quick Look shows it, it has the keyboard, the editor has its capture open, or its upload is going. It then has at least 4 seconds more, or the selected delay if shorter. Close leaves the capture in Capture History, unless History is set to Never in General, when a card that was not saved takes its capture with it; Save and Close also saves a copy to the folder in General, without asking for a name, and keeps the card if that fails.", bundle: .module)),
            ]) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Picker(selection: $settings.quickAccessCloseAfter) {
                            ForEach(SettingsStore.quickAccessCloseDelays, id: \.self) { seconds in
                                if seconds == 0 {
                                    Text("Never", bundle: .module).tag(seconds)
                                } else if seconds == 1 {
                                    Text("After 1 second", bundle: .module).tag(seconds)
                                } else {
                                    Text("After \(seconds) seconds", bundle: .module).tag(seconds)
                                }
                            }
                        } label: {
                            Text("Close cards", bundle: .module)
                        }
                        .labelsHidden()
                        .fixedSize()
                        Picker(selection: $settings.quickAccessCloseAction) {
                            Text("Close", bundle: .module).tag(QuickAccessCloseAction.close)
                            Text("Save and Close", bundle: .module).tag(QuickAccessCloseAction.saveAndClose)
                        } label: {
                            Text("When the time is up", bundle: .module)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(settings.quickAccessCloseAfter == 0)
                    }
                    if settings.quickAccessPreferences.closingDiscardsUnsavedCaptures(history: settings.historyRetention) {
                        Label {
                            Text("History is off: a card that closes unsaved takes its capture with it.", bundle: .module)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
