import Foundation
import OMSCore
import SwiftUI

struct RecordingSettingsView: View {
    @Bindable var settings: SettingsStore
    let destinations: UploadDestinationStore
    private var hasDestination: Bool { !destinations.destinations.isEmpty }

    var body: some View {
        SettingsPane {
            SettingsRow(String(localized: "Countdown", bundle: .module), help: [
                HelpTopic(String(localized: "Show controls", bundle: .module), Text("A small bar by the recording with the time, Pause, Restart, Delete, and Stop. It stays out of the recording. The menu bar shows the time too; click it to stop.", bundle: .module)),
                HelpTopic(String(localized: "Recorded area", bundle: .module), Text("How an area you record shows on screen, from the countdown to the end: a white outline, the rest of the display dimmed, or a red frame just outside it. None of it is in the recording. A window or a whole display is not marked.", bundle: .module)),
                HelpTopic(String(localized: "Audio", bundle: .module), Text("Video or GIF, computer audio, the microphone, clicks, and keystrokes are chosen on the bar under what you are about to record.", bundle: .module)),
            ]) {
                Picker(selection: $settings.recordingCountdown) {
                    ForEach(SettingsStore.recordingCountdowns, id: \.self) { seconds in
                        if seconds == 0 {
                            Text("None", bundle: .module).tag(seconds)
                        } else {
                            Text("\(seconds) seconds", bundle: .module).tag(seconds)
                        }
                    }
                } label: {
                    Text("Countdown", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(String(localized: "While recording", bundle: .module)) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $settings.recordingShowsControls) {
                        Text("Show controls", bundle: .module)
                    }
                    Toggle(isOn: $settings.recordingShowsCursor) {
                        Text("Show the pointer", bundle: .module)
                    }
                }
            }
            SettingsRow(String(localized: "Recorded area", bundle: .module)) {
                Picker(selection: $settings.recordingHighlight) {
                    Text("Outline", bundle: .module).tag(RecordingHighlight.outline)
                    Text("Dim the rest of the screen", bundle: .module).tag(RecordingHighlight.dim)
                    Text("Red frame", bundle: .module).tag(RecordingHighlight.redFrame)
                } label: {
                    Text("Recorded area", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(String(localized: "Audio", bundle: .module)) {
                Text("Chosen on the bar before you record.", bundle: .module)
                    .foregroundStyle(.secondary)
            }

            SettingsDivider()

            SettingsRow(String(localized: "Clicks", bundle: .module), help: [
                HelpTopic(String(localized: "Clicks", bundle: .module), Text("With Show Clicks on the recording bar, each click shows in the recording: as the system’s dark circles, or as a ring in your accent color that widens and fades. A window recorded on its own always gets the system’s circles.", bundle: .module)),
                HelpTopic(String(localized: "Keystrokes", bundle: .module), Text("With Show Keystrokes on the recording bar, the keys you press appear near the bottom of the recording. Shortcuts are keys held with Command, Control, or Option, and the function keys. Keys typed into password fields never appear. A window recorded on its own shows none. Needs Input Monitoring.", bundle: .module)),
                HelpTopic(String(localized: "Keep the keys pressed", bundle: .module), Text("A Studio recording writes down the keys you press, even with Show Keystrokes off, so Studio can show them afterwards. Which keys is the Keystrokes choice above: under All keys, what you type is kept as typed, in the recording’s project on this Mac; under Shortcuts only, typing is never written down. Keys typed into password fields are never kept. A window recorded on its own keeps none unless Show Keystrokes is on. Needs Input Monitoring.", bundle: .module)),
            ]) {
                Picker(selection: $settings.recordingClickStyle) {
                    Text("As the system shows them", bundle: .module).tag(ClickStyle.system)
                    Text("Accent rings", bundle: .module).tag(ClickStyle.ring)
                } label: {
                    Text("Clicks", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(String(localized: "Keystrokes", bundle: .module)) {
                Picker(selection: $settings.recordingKeystrokeMode) {
                    Text("All keys", bundle: .module).tag(KeystrokeMode.all)
                    Text("Shortcuts only", bundle: .module).tag(KeystrokeMode.shortcuts)
                } label: {
                    Text("Keystrokes", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(String(localized: "Studio", bundle: .module)) {
                Toggle(isOn: $settings.recordingKeepsKeysForStudio) {
                    Text("Keep the keys pressed", bundle: .module)
                }
            }

            SettingsDivider()

            SettingsRow(String(localized: "Frame rate", bundle: .module), help: [
                HelpTopic(String(localized: "Frame rate", bundle: .module), Text("Low Power Mode records at 30.", bundle: .module)),
                HelpTopic(String(localized: "Video format", bundle: .module), Text("Recordings are MP4 files at the screen’s own resolution. H.264 plays everywhere; recordings wider or taller than 4096 pixels use HEVC, which H.264 can’t encode in hardware. HEVC makes smaller files, but some players, browsers, and upload forms can’t play it.", bundle: .module)),
                HelpTopic(String(localized: "GIF", bundle: .module), Text("Choose GIF on the recording bar to keep a recording as an animated GIF, which shows wherever pictures do. GIFs have no sound and are made as large as things were on screen, at most 1920 pixels on their longer side. More frames move more smoothly and make larger files.", bundle: .module)),
            ]) {
                Picker(selection: $settings.recordingFrameRate) {
                    ForEach(SettingsStore.recordingFrameRates, id: \.self) { rate in
                        Text("\(rate) frames per second", bundle: .module).tag(rate)
                    }
                } label: {
                    Text("Frame rate", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(String(localized: "Video format", bundle: .module)) {
                Picker(selection: $settings.recordingPrefersHEVC) {
                    Text("H.264 when it fits", bundle: .module).tag(false)
                    Text("HEVC", bundle: .module).tag(true)
                } label: {
                    Text("Video format", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(String(localized: "GIF", bundle: .module)) {
                Picker(selection: $settings.recordingGIFFrameRate) {
                    ForEach(SettingsStore.recordingGIFFrameRates, id: \.self) { rate in
                        Text("\(rate) frames per second", bundle: .module).tag(rate)
                    }
                } label: {
                    Text("GIF frame rate", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }

            SettingsDivider()

            SettingsRow(String(localized: "After recording", bundle: .module), help: [
                HelpTopic(String(localized: "After recording", bundle: .module), hasDestination
                    ? Text("Copy puts the recording on the clipboard. Quick Access shows it as a card in the corner of the screen, to copy, save, or drag into another app. Save puts it in the folder chosen in Screenshots. Upload sends it to your default destination.", bundle: .module)
                    : Text("Copy puts the recording on the clipboard. Quick Access shows it as a card in the corner of the screen, to copy, save, or drag into another app. Save puts it in the folder chosen in Screenshots.", bundle: .module)),
            ]) {
                AfterCaptureChoices(
                    settings: settings, kind: .recording, hasDestination: hasDestination,
                    keptNowhere: Text("Recordings won’t be kept anywhere.", bundle: .module),
                    keptInHistoryOnly: Text("Recordings go only to History.", bundle: .module)
                )
            }
        }
    }
}
