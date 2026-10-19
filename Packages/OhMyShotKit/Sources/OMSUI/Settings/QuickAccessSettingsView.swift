import OMSCore
import SwiftUI

/// Settings › Quick Access: where the cards stand, how large they are, and whether they close by themselves.
struct QuickAccessSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsPane {
            SettingsRow(Text("Position", bundle: .module)) {
                Picker(selection: $settings.quickAccessCorner) {
                    Text("Bottom left", bundle: .module).tag(QuickAccessCorner.bottomLeft)
                    Text("Bottom right", bundle: .module).tag(QuickAccessCorner.bottomRight)
                } label: {
                    Text("Position", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(Text("Size", bundle: .module)) {
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
            SettingsRow(Text("Display", bundle: .module)) {
                HStack(spacing: 6) {
                    Toggle(isOn: $settings.quickAccessOnPointerDisplay) {
                        Text("Show on the display with the pointer", bundle: .module)
                    }
                    InfoButton(Text("Cards stand on the display the capture was taken on. With this on they stand on the display where the pointer is when the capture is taken.", bundle: .module))
                }
            }

            SettingsDivider()

            SettingsRow(Text("Close cards", bundle: .module)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Picker(selection: $settings.quickAccessCloseAfter) {
                            ForEach(SettingsStore.quickAccessCloseDelays, id: \.self) { seconds in
                                if seconds == 0 {
                                    Text("Never", bundle: .module).tag(seconds)
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
                        InfoButton(Text("Cards close after 3 seconds by default. A card waits while the pointer is over it, its menu is open, it is being dragged, a preview shows it, it has the keyboard, the editor has its capture open, or its upload is going. When all of these end, it has at least 3 seconds more with the default delay, or 4 seconds with a longer delay. Close leaves the capture in Capture History, unless History is set to Never in General, when a card that was not saved takes its capture with it; Save and Close also saves a copy to the folder in General, without asking for a name, and keeps the card if that fails.", bundle: .module))
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
