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
                .disabled(!settings.showTextResult)
            }

            SettingsDivider()

            SettingsRow(String(localized: "Image line breaks", bundle: .module), help: [
                HelpTopic(String(localized: "Image line breaks", bundle: .module), Text("Keep the detected lines from the image, or join wrapped lines within each paragraph. Sets the default for Capture Text and new Recognized Text windows; the window’s Line Breaks menu changes only that window.", bundle: .module)),
                HelpTopic(String(localized: "Wrap text to window", bundle: .module), Text("Sets the default for new Recognized Text windows. You can change wrapping in each window without changing this setting. Wrapping only changes the display.", bundle: .module)),
                HelpTopic(String(localized: "Recognition languages", bundle: .module), Text("Automatic uses your macOS preferred languages. Choose a language preset or enter comma-separated BCP-47 tags (such as ko-KR, ru-RU, ar-SA, fr-FR) to read scripts Vision does not run by default.", bundle: .module)),
                AppTextSetting.help,
                HelpTopic(String(localized: "Translate into", bundle: .module), Text("Automatic picks the first of your preferred languages that the text isn’t already in. Translation runs on this Mac; a language is downloaded the first time it’s needed.", bundle: .module)),
            ]) {
                Picker(selection: $settings.textRecognitionKeepsLineBreaks) {
                    Text("Keep line breaks", bundle: .module).tag(true)
                    Text("Join lines", bundle: .module).tag(false)
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
            SettingsRow(String(localized: "Recognition languages", bundle: .module)) {
                OCRLanguagesSetting(settings: settings)
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
                ModelPacksRow(
                    center: modelPacks,
                    settings: settings,
                    help: [
                        ModelPacksRow.help(center: modelPacks),
                        ModelPackMirrorRow.help,
                        HelpTopic(String(localized: "Formula format", bundle: .module), Text("How recognized LaTeX formulas are wrapped when copied by Capture Formula or the Recognized Text window.", bundle: .module)),
                    ] + (cloudModels.map(CloudReadingRow.help(store:)) ?? [])
                )
                ModelPackMirrorRow(settings: settings)
                SettingsRow(String(localized: "Formula format", bundle: .module)) {
                    Picker(selection: $settings.formulaDelimiter) {
                        Text("Plain LaTeX", bundle: .module).tag(FormulaDelimiter.raw)
                        Text(verbatim: "$…$").tag(FormulaDelimiter.inlineDollar)
                        Text(verbatim: "$$…$$").tag(FormulaDelimiter.displayDollar)
                        Text(verbatim: #"\(…\)"#).tag(FormulaDelimiter.inlineParen)
                    } label: {
                        Text("Formula format", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
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

/// Settings › Text › Recognition languages: automatic (macOS preferred languages), common script presets, or
/// custom comma-separated BCP-47 language tags.
private struct OCRLanguagesSetting: View {
    @Bindable var settings: SettingsStore
    @State private var customMode = false
    @State private var customText = ""

    enum Preset: String, CaseIterable, Identifiable {
        case automatic
        case english
        case chineseSimplified
        case chineseTraditional
        case japanese
        case korean
        case russian
        case arabic
        case french
        case german
        case spanish
        case portuguese
        case italian
        case thai
        case vietnamese
        case ukrainian
        case custom

        var id: String { rawValue }

        var languages: [String]? {
            switch self {
            case .automatic: []
            case .english: ["en-US"]
            case .chineseSimplified: ["zh-Hans", "en-US"]
            case .chineseTraditional: ["zh-Hant", "en-US"]
            case .japanese: ["ja-JP", "en-US"]
            case .korean: ["ko-KR", "en-US"]
            case .russian: ["ru-RU", "en-US"]
            case .arabic: ["ar-SA", "en-US"]
            case .french: ["fr-FR", "en-US"]
            case .german: ["de-DE", "en-US"]
            case .spanish: ["es-ES", "en-US"]
            case .portuguese: ["pt-BR", "en-US"]
            case .italian: ["it-IT", "en-US"]
            case .thai: ["th-TH", "en-US"]
            case .vietnamese: ["vi-VN", "en-US"]
            case .ukrainian: ["uk-UA", "en-US"]
            case .custom: nil
            }
        }

        var title: String {
            switch self {
            case .automatic: String(localized: "Automatic", bundle: .module)
            case .english: String(localized: "English", bundle: .module)
            case .chineseSimplified: String(localized: "Chinese (Simplified) & English", bundle: .module)
            case .chineseTraditional: String(localized: "Chinese (Traditional) & English", bundle: .module)
            case .japanese: String(localized: "Japanese & English", bundle: .module)
            case .korean: String(localized: "Korean & English", bundle: .module)
            case .russian: String(localized: "Russian & English", bundle: .module)
            case .arabic: String(localized: "Arabic & English", bundle: .module)
            case .french: String(localized: "French & English", bundle: .module)
            case .german: String(localized: "German & English", bundle: .module)
            case .spanish: String(localized: "Spanish & English", bundle: .module)
            case .portuguese: String(localized: "Portuguese & English", bundle: .module)
            case .italian: String(localized: "Italian & English", bundle: .module)
            case .thai: String(localized: "Thai & English", bundle: .module)
            case .vietnamese: String(localized: "Vietnamese & English", bundle: .module)
            case .ukrainian: String(localized: "Ukrainian & English", bundle: .module)
            case .custom: String(localized: "Custom…", bundle: .module)
            }
        }

        static func matching(_ languages: [String]) -> Preset {
            allCases.first { $0.languages == languages } ?? .custom
        }
    }

    private var selectedPreset: Preset {
        if customMode { return .custom }
        return Preset.matching(settings.ocrLanguages)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: Binding(get: { selectedPreset }, set: choose)) {
                Text(verbatim: Preset.automatic.title).tag(Preset.automatic)
                Divider()
                ForEach(Preset.allCases.filter { $0 != .automatic && $0 != .custom }) { preset in
                    Text(verbatim: preset.title).tag(preset)
                }
                Divider()
                Text(verbatim: Preset.custom.title).tag(Preset.custom)
            } label: {
                Text("Recognition languages", bundle: .module)
            }
            .labelsHidden()
            .fixedSize()

            if selectedPreset == .custom {
                TextField(text: $customText, prompt: Text(verbatim: "ko-KR, ru-RU, en-US")) {
                    Text("Custom recognition languages", bundle: .module)
                }
                .labelsHidden()
                .frame(width: 250)
                .onSubmit(commitCustom)
                .onChange(of: customText) { _, _ in commitCustom() }
                Text("Comma-separated BCP-47 language tags, most preferred first.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if Preset.matching(settings.ocrLanguages) == .custom {
                customMode = true
                customText = settings.ocrLanguages.joined(separator: ", ")
            }
        }
    }

    private func choose(_ preset: Preset) {
        if let languages = preset.languages {
            customMode = false
            settings.ocrLanguages = languages
        } else {
            customMode = true
            customText = settings.ocrLanguages.joined(separator: ", ")
        }
    }

    private func commitCustom() {
        let tags = customText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        settings.ocrLanguages = tags
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
                        permissions.hasAsked(.accessibility) ? Text("Open System Settings", bundle: .module) : Text("Allow…", bundle: .module)
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
