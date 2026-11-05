import AppKit
import Foundation
import OMSCore
import SwiftUI

/// Settings › Screenshots: where a screenshot goes, and the file and picture it is kept as.
struct ScreenshotsSettingsView: View {
    @Bindable var settings: SettingsStore
    let destinations: UploadDestinationStore
    let backgrounds: SettingsDependencies.Backgrounds
    private var hasDestination: Bool { !destinations.destinations.isEmpty }
    @State private var backgroundPresets: [SettingsDependencies.Backgrounds.Choice] = []
    @State private var automaticBackground: UUID?

    var body: some View {
        SettingsPane {
            SettingsRow(String(localized: "After screenshot", bundle: .module), help: [
                HelpTopic(String(localized: "After screenshot", bundle: .module), hasDestination
                    ? Text("Copy puts the capture on the clipboard. Quick Access shows it as a card in the corner of the screen, to copy, save, or drag into another app. Save puts it in the folder below. Upload sends it to your default destination.", bundle: .module)
                    : Text("Copy puts the capture on the clipboard. Quick Access shows it as a card in the corner of the screen, to copy, save, or drag into another app. Save puts it in the folder below.", bundle: .module)),
                HelpTopic(String(localized: "Background", bundle: .module), Text("Puts each new screenshot on a background. Save one as a preset with the editor’s Background tool.", bundle: .module)),
            ]) {
                AfterCaptureChoices(
                    settings: settings, kind: .screenshot, hasDestination: hasDestination,
                    keptNowhere: Text("Captures won’t be kept anywhere.", bundle: .module),
                    keptInHistoryOnly: Text("Captures go only to History.", bundle: .module)
                )
            }
            SettingsRow(String(localized: "Save to", bundle: .module)) {
                HStack(spacing: 8) {
                    Text(exportPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .leading)
                        .fixedSize()
                        .help(exportPath)
                    Button {
                        chooseExportDirectory()
                    } label: {
                        Text("Choose…", bundle: .module)
                    }
                }
            }
            SettingsRow(String(localized: "Background", bundle: .module)) {
                Picker(selection: Binding(
                        get: { automaticBackground },
                    set: { choice in
                        automaticBackground = choice
                        backgrounds.setAutomatic(choice)
                    }
                )) {
                    Text("None", bundle: .module).tag(UUID?.none)
                    if !backgroundPresets.isEmpty { Divider() }
                    ForEach(backgroundPresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                } label: {
                    Text("Background", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(backgroundPresets.isEmpty)
                .onAppear {
                    backgroundPresets = backgrounds.presets()
                    automaticBackground = backgrounds.automatic()
                }
            }

            SettingsDivider()

            SettingsRow(String(localized: "Format", bundle: .module), help: [
                HelpTopic(String(localized: "Format", bundle: .module), Text("Screenshots you save, drag out, upload, or hand to a shortcut are written in this format; the slider sets how much JPEG and HEIC give up for size. History keeps every capture as a PNG, so editing and reading text are never affected. JPEG has no transparency, so a window’s clear corners turn white. With Freeze the screen and Convert to sRGB off, a HEIC saved as the screenshot is taken also keeps the brightness of an HDR display.", bundle: .module)),
                HelpTopic(String(localized: "Save Retina screenshots at 1×", bundle: .module), Text("A screenshot taken at 2× is scaled down to its size in points where it leaves the app. The clipboard’s picture follows too.", bundle: .module)),
                HelpTopic(String(localized: "Convert to sRGB", bundle: .module), Text("A wide-gamut display captures in Display P3. Converting makes colors look the same in apps that ignore color profiles.", bundle: .module)),
                HelpTopic(String(localized: "Add a 1 px border", bundle: .module), Text("Draws a faint dark line around the picture’s edge, so a light screenshot shows on a white page. A picture with clear corners or a shadow, like a window’s, gets none.", bundle: .module)),
            ]) {
                HStack(spacing: 8) {
                    Picker(selection: $settings.screenshotFormat) {
                        ForEach(ImageExporter.Format.allCases, id: \.self) { format in
                            Text(verbatim: format.title).tag(format)
                        }
                    } label: {
                        Text("Format", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                    // Only JPEG and HEIC give up anything for size; a PNG is lossless, and a slider shown dimmed for
                    // it looked stuck, so it says so in the slider's place. The label sits beside the slider rather
                    // than in it: a slider's own label shares the slider's width, and the track ran over it.
                    if settings.screenshotFormat == .png {
                        Text("Lossless", bundle: .module)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            Text("Quality", bundle: .module)
                                .accessibilityHidden(true)
                            // Steps of 5 percent, rounded here rather than given as the slider's step: a stepped
                            // slider draws a dot for each stop under its track, eleven crowded under a short track,
                            // inset from its ends and covered by the knob.
                            Slider(value: Binding {
                                settings.screenshotQuality
                            } set: {
                                settings.screenshotQuality = ($0 * 20).rounded() / 20
                            }, in: ScreenshotOutput.qualities) {
                                Text("Quality", bundle: .module)
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            // The slider spans 50 to 100 percent, so it would read as 0 to 100 of that.
                            .accessibilityValue(Text(settings.screenshotQuality, format: .percent.precision(.fractionLength(0))))
                            Text(settings.screenshotQuality, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            SettingsRow(String(localized: "Pictures", bundle: .module)) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $settings.savesRetinaAtOneX) {
                        Text("Save Retina screenshots at 1×", bundle: .module)
                    }
                    Toggle(isOn: $settings.convertsToSRGB) {
                        Text("Convert to sRGB", bundle: .module)
                    }
                    Toggle(isOn: $settings.addsBorder) {
                        Text("Add a 1 px border", bundle: .module)
                    }
                }
            }

            SettingsDivider()

            SettingsRow(String(localized: "File name", bundle: .module), help: FileNameSettings.help + [
                HelpTopic(String(localized: "Clipboard", bundle: .module), Text("File and picture also puts the file on the clipboard, in the format above, so Finder, Mail, and chat apps paste the file while image editors paste the picture. Some apps paste the file where you wanted the picture.", bundle: .module)),
            ]) {
                FileNameSettings(settings: settings)
            }
            SettingsRow(String(localized: "Clipboard", bundle: .module)) {
                Picker(selection: $settings.clipboardFormat) {
                    Text("Picture only", bundle: .module).tag(ClipboardFormat.pictureOnly)
                    Text("File and picture", bundle: .module).tag(ClipboardFormat.fileAndPicture)
                } label: {
                    Text("Clipboard", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

extension ScreenshotsSettingsView {
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
