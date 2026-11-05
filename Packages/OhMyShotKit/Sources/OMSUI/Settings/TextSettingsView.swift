import AppKit
import Foundation
import OMSCore
import OMSOCR
import SwiftUI

/// Settings › Text: reading text out of pictures, from Capture Text's card to the model packs and cloud reading.
struct TextSettingsView: View {
    @Bindable var settings: SettingsStore
    var permissions: PermissionCenter?
    var modelPacks: ModelPackCenter?
    var cloudModels: CloudModelStore?
    @State private var translationTargets: [Locale.Language] = []

    var body: some View {
        SettingsPane {
            SettingsRow(String(localized: "Capture Text", bundle: .module), help: [
                HelpTopic(String(localized: "Show the copied text", bundle: .module), Text("A card with the copied text and a switch for its line breaks. Choose when it closes below; hovering keeps it open.", bundle: .module)),
                HelpTopic(String(localized: "Text card position", bundle: .module), Text("Shows the result on the display where the text or formula was selected.", bundle: .module)),
                HelpTopic(String(localized: "Close text card", bundle: .module), Text("How long the copied-text card stays. It stays open while the pointer is over it and closes the chosen time after the pointer leaves; Never keeps it until you close it. A card that says nothing was found, or that the text was not copied, always stays at least as long as it used to.", bundle: .module)),
            ]) {
                Toggle(isOn: $settings.showTextResult) {
                    Text("Show the copied text", bundle: .module)
                }
            }
            SettingsRow(String(localized: "Text card position", bundle: .module)) {
                Picker(selection: $settings.textResultPosition) {
                    Text("Below selection", bundle: .module).tag(TextResultPosition.belowSelection)
                    Text("Bottom left", bundle: .module).tag(TextResultPosition.bottomLeft)
                } label: {
                    Text("Text card position", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(String(localized: "Close text card", bundle: .module)) {
                Picker(selection: $settings.textResultCloseAfter) {
                    ForEach(SettingsStore.textResultCloseDelays, id: \.self) { seconds in
                        if seconds == 0 {
                            Text("Never", bundle: .module).tag(seconds)
                        } else if seconds == 1 {
                            Text("After 1 second", bundle: .module).tag(seconds)
                        } else {
                            Text("After \(seconds) seconds", bundle: .module).tag(seconds)
                        }
                    }
                } label: {
                    Text("Close text card", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }

            SettingsDivider()

            SettingsRow(String(localized: "Image line breaks", bundle: .module), help: [
                HelpTopic(String(localized: "Image line breaks", bundle: .module), Text("Keep the detected lines from the image, or join wrapped lines within each paragraph. Sets the default for Capture Text and new Recognized Text windows; the window’s Line Breaks menu changes only that window.", bundle: .module)),
                HelpTopic(String(localized: "Wrap text to window", bundle: .module), Text("Sets the default for new Recognized Text windows. You can change wrapping in each window without changing this setting. Wrapping only changes the display.", bundle: .module)),
                AppTextSetting.help,
                HelpTopic(String(localized: "Translate into", bundle: .module), Text("Automatic picks the first of your preferred languages that the text isn’t already in. Translation runs on this Mac; a language is downloaded the first time it’s needed.", bundle: .module)),
            ]) {
                Picker(selection: $settings.textRecognitionKeepsLineBreaks) {
                    Text("Keep Line Breaks", bundle: .module).tag(true)
                    Text("Join Lines", bundle: .module).tag(false)
                } label: {
                    Text("Image line breaks", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(String(localized: "Recognized Text", bundle: .module)) {
                Toggle(isOn: $settings.textRecognitionWrapsText) {
                    Text("Wrap text to window", bundle: .module)
                }
            }
            SettingsRow(String(localized: "Text from apps", bundle: .module)) {
                AppTextSetting(settings: settings, permissions: permissions)
            }
            SettingsRow(String(localized: "Translate into", bundle: .module)) {
                TranslationTargetPicker(selection: $settings.translationTarget, targets: translationTargets) {
                    Text("Automatic", bundle: .module)
                } label: {
                    Text("Translate into", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
                .task { translationTargets = await Translator.targets() }
            }
            // The last group is headed by whichever of its rows the build shows first.
            if let modelPacks, !modelPacks.isEmpty {
                SettingsDivider()
                ModelPacksRow(center: modelPacks, help: [ModelPacksRow.help(center: modelPacks)] + (cloudModels.map(CloudReadingRow.help(store:)) ?? []))
                if let cloudModels {
                    CloudReadingRow(store: cloudModels)
                }
            } else if let cloudModels {
                SettingsDivider()
                CloudReadingRow(store: cloudModels, help: CloudReadingRow.help(store: cloudModels))
            }
        }
    }
}

/// Settings › Text › Text from apps: Capture Text and the Recognized Text window take the characters the app under the
/// selection shows (L0, Docs/ocr.md › Text from apps). Turning it on asks for Accessibility; while OhMyShot doesn't
/// have it, a line under the switch says so, with the way to it.
private struct AppTextSetting: View {
    @Bindable var settings: SettingsStore
    let permissions: PermissionCenter?

    /// Its part of its group's help, which the Image line breaks row holds.
    static var help: HelpTopic {
        HelpTopic(String(localized: "Use the app’s own characters", bundle: .module), Text("Capture Text and the Recognized Text window ask the app under the selection for the text it shows, through Accessibility, and use its own characters for the lines that read the same, so code, names, and numbers come out as the app has them. Apps that don’t share their text, such as Chrome and most apps built with Electron, are read from the picture alone. Nothing leaves this Mac.", bundle: .module))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { settings.readsAppText }, set: { on in
                settings.readsAppText = on
                if on { allow() }
            })) {
                Text("Use the app’s own characters", bundle: .module)
            }
            if settings.readsAppText, let permissions, permissions.status(of: .accessibility) != .granted {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SettingsWarning(Text("Needs Accessibility to ask apps for their text.", bundle: .module))
                    Button(action: allow) {
                        permissions.hasAsked(.accessibility) ? Text("Open System Settings…", bundle: .module) : Text("Allow…", bundle: .module)
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear { permissions?.refresh([.accessibility]) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions?.refresh([.accessibility])
        }
    }

    /// macOS asks once; after that, System Settings.
    private func allow() {
        guard let permissions else { return }
        permissions.refresh([.accessibility])
        guard permissions.status(of: .accessibility) != .granted else { return }
        if permissions.hasAsked(.accessibility) {
            permissions.openSystemSettings(for: .accessibility)
        } else {
            Task { await permissions.request(.accessibility) }
        }
    }
}
