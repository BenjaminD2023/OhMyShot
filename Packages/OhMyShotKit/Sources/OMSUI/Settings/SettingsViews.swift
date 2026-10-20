import AppKit
import Foundation
import KeyboardShortcuts
import OMSCore
import OMSOCR
import SwiftUI

/// The narrowest a settings pane gets, in points: room for its rows in English. A translation whose rows run longer
/// gives a wider one in its catalog, so nothing in a pane is cut off.
let paneWidth = CGFloat(Double(String(
    localized: "SETTINGS_PANE_WIDTH",
    defaultValue: "520",
    bundle: .module,
    comment: "The narrowest a Settings pane gets, in points. Not words: raise the number if your language's rows are cut off."
)) ?? 520)

/// A settings pane in the classic two-column layout: short labels right-aligned in the first column,
/// controls in the second, and groups split by dividers. Explanations wait behind a help button rather
/// than sitting under every row. The pane fills the window beside the sidebar, its rows at the top, and
/// scrolls when they are taller than the window.
struct SettingsPane<Rows: View>: View {
    /// How a row's label lines up with its controls: on the first line of text by default, or centered
    /// for controls without text, such as shortcut recorders.
    var alignment: Alignment = .leadingFirstTextBaseline
    var spacing: CGFloat = 12
    @ViewBuilder var rows: Rows

    var body: some View {
        ScrollView {
            Grid(alignment: alignment, horizontalSpacing: 10, verticalSpacing: spacing) {
                rows
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(minWidth: paneWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A row of a settings pane: its label right-aligned in the first column, its controls in the second.
struct SettingsRow<Content: View>: View {
    let label: Text?
    /// A fixed width for the label column, so the fields of one form line up whatever its rows say.
    var labelWidth: CGFloat?
    @ViewBuilder var content: Content

    init(_ label: Text? = nil, labelWidth: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.content = content()
    }

    var body: some View {
        GridRow {
            Group {
                if let labelWidth {
                    (label ?? Text(verbatim: "")).frame(width: labelWidth, alignment: .trailing)
                } else {
                    label ?? Text(verbatim: "")
                }
            }
            .gridColumnAlignment(.trailing)
            content
        }
    }
}

/// The line between groups of rows.
struct SettingsDivider: View {
    var body: some View {
        Divider()
            .gridCellUnsizedAxes(.horizontal)
            .padding(.vertical, 4)
    }
}

/// The round help button beside a control, with a short explanation in a popover.
struct InfoButton: View {
    let text: Text
    @State private var isShown = false

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        HelpLink { isShown.toggle() }
            .popover(isPresented: $isShown, arrowEdge: .bottom) {
                text
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260, alignment: .leading)
                    .padding(14)
            }
            .accessibilityHint(text)
    }
}

/// Settings › General: the app itself, and how long captures are kept.
struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore
    let openHistory: () -> Void
    let expiredCount: (HistoryRetention) -> Int
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    @State private var retentionRequest: RetentionChangeRequest?
    @State private var language = AppLanguage.chosen ?? ""

    var body: some View {
        SettingsPane {
            SettingsRow(Text("Language", bundle: .module)) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Picker(selection: $language) {
                            Text("System Default", bundle: .module).tag("")
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
                        InfoButton(Text("OhMyShot can show itself in a language other than the system’s. Missing your language? Translations are welcome on GitHub.", bundle: .module))
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
            SettingsRow(Text("Startup", bundle: .module)) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $launchAtLogin) {
                        Text("Launch at login", bundle: .module)
                    }
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard enabled != LoginItem.isEnabled else { return }
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
            SettingsRow(Text("Menu bar", bundle: .module)) {
                HStack(spacing: 6) {
                    Toggle(isOn: $settings.showMenuBarIcon) {
                        Text("Show icon", bundle: .module)
                    }
                    InfoButton(Text("With the icon hidden, open OhMyShot again from Finder or Spotlight to come back here.", bundle: .module))
                }
            }
            SettingsRow(Text("Sound", bundle: .module)) {
                Toggle(isOn: $settings.playSounds) {
                    Text("Play sounds", bundle: .module)
                }
            }

            SettingsDivider()

            SettingsRow(Text("Keep captures", bundle: .module)) {
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
        }
        .confirmingRetentionChange($retentionRequest) { retention in
            settings.historyRetention = retention
        }
    }
}

/// Settings › Capture: choosing what to capture, and how a window is taken.
struct CaptureSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsPane {
            SettingsRow(Text("Selecting", bundle: .module)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Toggle(isOn: $settings.freezeScreen) {
                            Text("Freeze the screen", bundle: .module)
                        }
                        InfoButton(Text("Hover states and open menus stay in place until the capture is taken.", bundle: .module))
                    }
                    HStack(spacing: 6) {
                        Toggle(isOn: $settings.screenshotShowsCursor) {
                            Text("Show the pointer in screenshots", bundle: .module)
                        }
                        InfoButton(Text("The pointer is in the picture where it was when you took it. With the screen frozen, that is where it was when you pressed the shortcut; All-In-One leaves it out then.", bundle: .module))
                    }
                    HStack(spacing: 6) {
                        Text("Shift keeps", bundle: .module)
                        Picker(selection: $settings.areaShape) {
                            Text("A square", bundle: .module).tag("")
                            ForEach(AspectRatio.presets.dropFirst(), id: \.label) { ratio in
                                Text(ratio.label).tag(ratio.label)
                            }
                        } label: {
                            Text("Shift keeps", bundle: .module)
                        }
                        .labelsHidden()
                        .fixedSize()
                        InfoButton(Text("Hold Shift while you drag out an area to keep its shape. Press Tab while choosing an area to type its width and height in pixels; a shape you choose there is the one Shift keeps from then on.", bundle: .module))
                    }
                    HStack(spacing: 6) {
                        Toggle(isOn: $settings.snapSelectionToText) {
                            Text("Snap the selection to text", bundle: .module)
                        }
                        InfoButton(Text("On a frozen screen, the edges of a selection snap to paragraphs, lists, code, and tables near them, with a little room around. Hold Command while dragging to place the edges freely.", bundle: .module))
                    }
                    HStack(spacing: 6) {
                        Toggle(isOn: $settings.allInOneRemembersArea) {
                            Text("All-In-One remembers the last area", bundle: .module)
                        }
                        InfoButton(Text("All-In-One opens with the area it last took, framed to adjust or take again.", bundle: .module))
                    }
                }
            }
            SettingsRow(Text("Color picker size", bundle: .module)) {
                HStack(spacing: 6) {
                    Picker(selection: $settings.captureLoupeSize) {
                        ForEach(CaptureLoupeSize.allCases, id: \.self) { size in
                            Text(verbatim: size.title).tag(size)
                        }
                    } label: {
                        Text("Color picker size", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            SettingsRow(Text("Color picker magnification", bundle: .module)) {
                HStack(spacing: 6) {
                    Picker(selection: $settings.captureLoupeMagnification) {
                        ForEach(CaptureLoupeMagnification.allCases, id: \.self) { magnification in
                            Text(verbatim: magnification.title).tag(magnification)
                        }
                    } label: {
                        Text("Color picker magnification", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                    InfoButton(Text("Controls how much each screen pixel is enlarged in the centered screenshot picker. The size stays the same when you change magnification. Applies to the next screenshot or Annotate Area capture; Pick Color is unchanged.", bundle: .module))
                }
            }
            SettingsRow(Text("Copy color shortcut", bundle: .module)) {
                HStack(spacing: 6) {
                    Picker(selection: $settings.colorCopyGesture) {
                        ForEach(ColorCopyGesture.allCases, id: \.self) { gesture in
                            if gesture == .disabled {
                                Text("Off", bundle: .module).tag(gesture)
                            } else {
                                Text("\(gesture.modifierSymbols) + Left Click", bundle: .module).tag(gesture)
                            }
                        }
                    } label: {
                        Text("Copy color shortcut", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                    InfoButton(Text("Before starting an area selection, or while using Pick Color, this left-click shortcut copies the pointed color without closing the overlay. Other clicks keep their usual behavior.", bundle: .module))
                }
            }
            SettingsRow(Text("Self-Timer", bundle: .module)) {
                Picker(selection: $settings.selfTimerDelay) {
                    ForEach(SettingsStore.selfTimerDelays, id: \.self) { seconds in
                        Text("\(seconds) seconds", bundle: .module).tag(seconds)
                    }
                } label: {
                    Text("Self-Timer", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }

            SettingsDivider()

            SettingsRow(Text("Windows", bundle: .module)) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $settings.windowShadow) {
                        Text("Capture the shadow", bundle: .module)
                    }
                    HStack(spacing: 6) {
                        Picker(selection: $settings.windowBackground) {
                            Text("Same background as screenshots", bundle: .module).tag(WindowBackground.asScreenshots)
                            Text("No background", bundle: .module).tag(WindowBackground.transparent)
                            Text("Desktop wallpaper", bundle: .module).tag(WindowBackground.desktopWallpaper)
                        } label: {
                            Text("Window background", bundle: .module)
                        }
                        .labelsHidden()
                        .fixedSize()
                        InfoButton(Text("Desktop wallpaper puts a window on the desktop picture around it, as the screen shows it. Hold Shift as you click a window to take it the other way: with no background, or on the desktop wallpaper.", bundle: .module))
                    }
                }
            }
        }
    }
}

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
            SettingsRow(Text("After screenshot", bundle: .module)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        HStack(spacing: 14) {
                            Toggle(isOn: $settings.copyAfterCapture) {
                                Text("Copy", bundle: .module)
                            }
                            Toggle(isOn: $settings.showQuickAccess) {
                                Text("Quick Access", bundle: .module)
                            }
                            Toggle(isOn: $settings.saveAfterCapture) {
                                Text("Save", bundle: .module)
                            }
                            // Uploading is offered only to a person who has somewhere to upload to.
                            if hasDestination {
                                Toggle(isOn: $settings.uploadAfterCapture) {
                                    Text("Upload", bundle: .module)
                                }
                            }
                        }
                        InfoButton(hasDestination
                            ? Text("Copy puts the capture on the clipboard. Quick Access shows it as a card in the corner of the screen, to copy, save, or drag into another app. Save puts it in the folder below. Upload sends it to your default destination.", bundle: .module)
                            : Text("Copy puts the capture on the clipboard. Quick Access shows it as a card in the corner of the screen, to copy, save, or drag into another app. Save puts it in the folder below.", bundle: .module))
                    }
                    if !settings.copyAfterCapture, !settings.showQuickAccess, !settings.saveAfterCapture, !(hasDestination && settings.uploadAfterCapture) {
                        Label {
                            if settings.historyRetention == .never {
                                Text("Captures won’t be kept anywhere.", bundle: .module)
                            } else {
                                Text("Captures go only to History.", bundle: .module)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            SettingsRow(Text("Save to", bundle: .module)) {
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
            SettingsRow(Text("Background", bundle: .module)) {
                HStack(spacing: 6) {
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
                    InfoButton(Text("Puts each new screenshot on a background. Save one as a preset with the editor’s Background tool.", bundle: .module))
                }
            }

            SettingsDivider()

            SettingsRow(Text("Format", bundle: .module)) {
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
                    Slider(value: $settings.screenshotQuality, in: ScreenshotOutput.qualities, step: 0.05) {
                        Text("Quality", bundle: .module)
                    }
                    .frame(width: 110)
                    .disabled(settings.screenshotFormat == .png)
                    // The slider spans 50 to 100 percent, so it would read as 0 to 100 of that.
                    .accessibilityValue(Text(settings.screenshotQuality, format: .percent.precision(.fractionLength(0))))
                    Text(settings.screenshotQuality, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                        .accessibilityHidden(true)
                    InfoButton(Text("Screenshots you save, drag out, upload, or hand to a shortcut are written in this format; the slider sets how much JPEG and HEIC give up for size. History keeps every capture as a PNG, so editing and reading text are never affected. JPEG has no transparency, so a window’s clear corners turn white. With Freeze the screen and Convert to sRGB off, a HEIC saved as the screenshot is taken also keeps the brightness of an HDR display.", bundle: .module))
                }
            }
            SettingsRow(Text("Pictures", bundle: .module)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Toggle(isOn: $settings.savesRetinaAtOneX) {
                            Text("Save Retina screenshots at 1×", bundle: .module)
                        }
                        InfoButton(Text("A screenshot taken at 2× is scaled down to its size in points where it leaves the app. The clipboard’s picture follows too.", bundle: .module))
                    }
                    HStack(spacing: 6) {
                        Toggle(isOn: $settings.convertsToSRGB) {
                            Text("Convert to sRGB", bundle: .module)
                        }
                        InfoButton(Text("A wide-gamut display captures in Display P3. Converting makes colors look the same in apps that ignore color profiles.", bundle: .module))
                    }
                    HStack(spacing: 6) {
                        Toggle(isOn: $settings.addsBorder) {
                            Text("Add a 1 px border", bundle: .module)
                        }
                        InfoButton(Text("Draws a faint dark line around the picture’s edge, so a light screenshot shows on a white page. A picture with clear corners or a shadow, like a window’s, gets none.", bundle: .module))
                    }
                }
            }
            SettingsRow(Text("File name", bundle: .module)) {
                FileNameSettings(settings: settings)
            }
            SettingsRow(Text("Clipboard", bundle: .module)) {
                HStack(spacing: 6) {
                    Picker(selection: $settings.clipboardFormat) {
                        Text("Picture only", bundle: .module).tag(ClipboardFormat.pictureOnly)
                        Text("File and picture", bundle: .module).tag(ClipboardFormat.fileAndPicture)
                    } label: {
                        Text("Clipboard", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                    InfoButton(Text("File and picture also puts the file on the clipboard, in the format above, so Finder, Mail, and chat apps paste the file while image editors paste the picture. Some apps paste the file where you wanted the picture.", bundle: .module))
                }
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

struct RecordingSettingsView: View {
    @Bindable var settings: SettingsStore
    let destinations: UploadDestinationStore
    private var hasDestination: Bool { !destinations.destinations.isEmpty }

    var body: some View {
        SettingsPane {
            SettingsRow(Text("Countdown", bundle: .module)) {
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
            SettingsRow(Text("While recording", bundle: .module)) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Toggle(isOn: $settings.recordingShowsControls) {
                            Text("Show controls", bundle: .module)
                        }
                        InfoButton(Text("A small bar by the recording with the time, Pause, Restart, Delete, and Stop. It stays out of the recording. The menu bar shows the time too; click it to stop.", bundle: .module))
                    }
                    Toggle(isOn: $settings.recordingShowsCursor) {
                        Text("Show the pointer", bundle: .module)
                    }
                }
            }
            SettingsRow(Text("Recorded area", bundle: .module)) {
                HStack(spacing: 6) {
                    Picker(selection: $settings.recordingHighlight) {
                        Text("Outline", bundle: .module).tag(RecordingHighlight.outline)
                        Text("Dim the rest of the screen", bundle: .module).tag(RecordingHighlight.dim)
                        Text("Red frame", bundle: .module).tag(RecordingHighlight.redFrame)
                    } label: {
                        Text("Recorded area", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                    InfoButton(Text("How an area you record shows on screen, from the countdown to the end: a white outline, the rest of the display dimmed, or a red frame just outside it. None of it is in the recording. A window or a whole display is not marked.", bundle: .module))
                }
            }
            SettingsRow(Text("Audio", bundle: .module)) {
                Text("Chosen on the bar before you record.", bundle: .module)
                    .foregroundStyle(.secondary)
                    .help(Text("Video or GIF, computer audio, the microphone, clicks, and keystrokes are chosen on the bar under what you are about to record.", bundle: .module))
            }
            SettingsRow(Text("Clicks", bundle: .module)) {
                HStack(spacing: 6) {
                    Picker(selection: $settings.recordingClickStyle) {
                        Text("As the system shows them", bundle: .module).tag(ClickStyle.system)
                        Text("Accent rings", bundle: .module).tag(ClickStyle.ring)
                    } label: {
                        Text("Clicks", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                    InfoButton(Text("With Show Clicks on the recording bar, each click shows in the recording: as the system's dark circles, or as a ring in your accent color that widens and fades. A window recorded on its own always gets the system's circles.", bundle: .module))
                }
            }
            SettingsRow(Text("Keystrokes", bundle: .module)) {
                HStack(spacing: 6) {
                    Picker(selection: $settings.recordingKeystrokeMode) {
                        Text("All keys", bundle: .module).tag(KeystrokeMode.all)
                        Text("Shortcuts only", bundle: .module).tag(KeystrokeMode.shortcuts)
                    } label: {
                        Text("Keystrokes", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                    InfoButton(Text("With Show Keystrokes on the recording bar, the keys you press appear near the bottom of the recording. Shortcuts are keys held with Command, Control, or Option, and the function keys. Keys typed into password fields never appear. A window recorded on its own shows none. Needs Input Monitoring.", bundle: .module))
                }
            }
            SettingsRow(Text("Studio", bundle: .module)) {
                HStack(spacing: 6) {
                    Toggle(isOn: $settings.recordingKeepsKeysForStudio) {
                        Text("Keep the keys pressed", bundle: .module)
                    }
                    InfoButton(Text("A Studio recording writes down the keys you press, even with Show Keystrokes off, so Studio can show them afterwards. Which keys is the Keystrokes choice above: under All keys, what you type is kept as typed, in the recording’s project on this Mac; under Shortcuts only, typing is never written down. Keys typed into password fields are never kept. A window recorded on its own keeps none unless Show Keystrokes is on. Needs Input Monitoring.", bundle: .module))
                }
            }

            SettingsDivider()

            SettingsRow(Text("Frame rate", bundle: .module)) {
                Picker(selection: $settings.recordingFrameRate) {
                    ForEach(SettingsStore.recordingFrameRates, id: \.self) { rate in
                        Text("\(rate) frames per second", bundle: .module).tag(rate)
                    }
                } label: {
                    Text("Frame rate", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
                .help(Text("Low Power Mode records at 30.", bundle: .module))
            }
            SettingsRow(Text("Video format", bundle: .module)) {
                HStack(spacing: 6) {
                    Picker(selection: $settings.recordingPrefersHEVC) {
                        Text("H.264 when it fits", bundle: .module).tag(false)
                        Text("HEVC", bundle: .module).tag(true)
                    } label: {
                        Text("Video format", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                    InfoButton(Text("Recordings are MP4 files at the screen’s own resolution. H.264 plays everywhere; recordings wider or taller than 4096 pixels use HEVC, which H.264 can’t encode in hardware. HEVC makes smaller files, but some players, browsers, and upload forms can’t play it.", bundle: .module))
                }
            }
            SettingsRow(Text("GIF", bundle: .module)) {
                HStack(spacing: 6) {
                    Picker(selection: $settings.recordingGIFFrameRate) {
                        ForEach(SettingsStore.recordingGIFFrameRates, id: \.self) { rate in
                            Text("\(rate) frames per second", bundle: .module).tag(rate)
                        }
                    } label: {
                        Text("GIF frame rate", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                    InfoButton(Text("Choose GIF on the recording bar to keep a recording as an animated GIF, which shows wherever pictures do. GIFs have no sound and are made as large as things were on screen, at most 1920 pixels on their longer side. More frames move more smoothly and make larger files.", bundle: .module))
                }
            }

            SettingsDivider()

            SettingsRow(Text("After recording", bundle: .module)) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        HStack(spacing: 14) {
                            Toggle(isOn: $settings.copyAfterRecording) {
                                Text("Copy", bundle: .module)
                            }
                            Toggle(isOn: $settings.showRecordingQuickAccess) {
                                Text("Quick Access", bundle: .module)
                            }
                            Toggle(isOn: $settings.saveAfterRecording) {
                                Text("Save", bundle: .module)
                            }
                            // Uploading is offered only to a person who has somewhere to upload to.
                            if hasDestination {
                                Toggle(isOn: $settings.uploadAfterRecording) {
                                    Text("Upload", bundle: .module)
                                }
                            }
                        }
                        InfoButton(hasDestination
                            ? Text("Copy puts the recording on the clipboard. Quick Access shows it as a card in the corner of the screen, to copy, save, or drag into another app. Save puts it in the folder chosen in Screenshots. Upload sends it to your default destination.", bundle: .module)
                            : Text("Copy puts the recording on the clipboard. Quick Access shows it as a card in the corner of the screen, to copy, save, or drag into another app. Save puts it in the folder chosen in Screenshots.", bundle: .module))
                    }
                    if !settings.copyAfterRecording, !settings.showRecordingQuickAccess, !settings.saveAfterRecording, !(hasDestination && settings.uploadAfterRecording) {
                        Label {
                            if settings.historyRetention == .never {
                                Text("Recordings won’t be kept anywhere.", bundle: .module)
                            } else {
                                Text("Recordings go only to History.", bundle: .module)
                            }
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

struct ToolsSettingsView: View {
    @Bindable var settings: SettingsStore
    var modelPacks: ModelPackCenter?
    @State private var translationTargets: [Locale.Language] = []

    var body: some View {
        SettingsPane {
            SettingsRow(Text("Capture Text", bundle: .module)) {
                Toggle(isOn: $settings.showTextResult) {
                    Text("Show the copied text", bundle: .module)
                }
                .help(Text("A card with the copied text and a switch for its line breaks. Choose when it closes below; hovering keeps it open.", bundle: .module))
            }
            SettingsRow(Text("Text popup position", bundle: .module)) {
                Picker(selection: $settings.textResultPosition) {
                    Text("Below selection", bundle: .module).tag(TextResultPosition.belowSelection)
                    Text("Bottom left", bundle: .module).tag(TextResultPosition.bottomLeft)
                } label: {
                    Text("Text popup position", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
                .help(Text("Shows the result on the display where the text or formula was selected.", bundle: .module))
            }
            SettingsRow(Text("Close text popup", bundle: .module)) {
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
                    Text("Close text popup", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
                .help(Text("The popup stays open while hovered. When the pointer leaves, the selected duration starts again. Never keeps it open until you close it.", bundle: .module))
            }
            SettingsRow(Text("Image line breaks", bundle: .module)) {
                Picker(selection: $settings.textRecognitionKeepsLineBreaks) {
                    Text("Keep Line Breaks", bundle: .module).tag(true)
                    Text("Join Lines", bundle: .module).tag(false)
                } label: {
                    Text("Image line breaks", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
                .help(Text("Keep the detected lines from the image, or join wrapped lines within each paragraph. Sets the default for Capture Text and new Recognized Text windows; the window’s Line Breaks menu changes only that window.", bundle: .module))
            }
            SettingsRow(Text("Recognized Text", bundle: .module)) {
                Toggle(isOn: $settings.textRecognitionWrapsText) {
                    Text("Wrap text to window", bundle: .module)
                }
                .help(Text("Sets the default for new Recognized Text windows. You can change wrapping in each window without changing this setting. Wrapping only changes the display.", bundle: .module))
            }
            SettingsRow(Text("Translate into", bundle: .module)) {
                HStack(spacing: 6) {
                    Picker(selection: $settings.translationTarget) {
                        Text("Automatic", bundle: .module).tag("")
                        Divider()
                        ForEach(translationOptions, id: \.self) { identifier in
                            Text(verbatim: Translator.name(of: Locale.Language(identifier: identifier))).tag(identifier)
                        }
                    } label: {
                        Text("Translate into", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .task { translationTargets = await Translator.targets() }
                    InfoButton(Text("Automatic picks the first of your preferred languages that the text isn’t already in. Translation runs on this Mac; a language is downloaded the first time it’s needed.", bundle: .module))
                }
            }
            if let modelPacks, !modelPacks.isEmpty {
                ModelPacksRow(center: modelPacks)
            }

            SettingsDivider()

            SettingsRow(Text("Copy colors as", bundle: .module)) {
                Picker(selection: $settings.colorFormat) {
                    ForEach(ColorFormat.allCases, id: \.self) { format in
                        Text(verbatim: format.title).tag(format)
                    }
                } label: {
                    Text("Copy colors as", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
                .help(Text("For Pick Color, and C while capturing or measuring.", bundle: .module))
            }
            SettingsRow(Text("Measure in", bundle: .module)) {
                Picker(selection: $settings.measureUnit) {
                    Text("Points", bundle: .module).tag(MeasureUnit.points)
                    Text("Pixels", bundle: .module).tag(MeasureUnit.pixels)
                } label: {
                    Text("Measure in", bundle: .module)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                .fixedSize()
                .help(Text("Tab switches between them while measuring.", bundle: .module))
            }
            SettingsRow(Text("Measurement snapping", bundle: .module)) {
                Toggle(isOn: $settings.measureSnapsToContent) {
                    Text("Snap selections to content", bundle: .module)
                }
                .help(Text("Fits a measurement box to the content inside it when you release the pointer. Turn off to keep the box as drawn, or hold Command while releasing to skip snapping once.", bundle: .module))
            }
            SettingsRow(Text("Edge tolerance", bundle: .module)) {
                HStack(spacing: 6) {
                    Picker(selection: $settings.measureTolerance) {
                        ForEach(MeasureTolerance.allCases, id: \.self) { tolerance in
                            Text(verbatim: tolerance.title).tag(tolerance)
                        }
                    } label: {
                        Text("Edge tolerance", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                    InfoButton(Text("Lower tolerance finds finer boundaries. Higher tolerance ignores small color changes. This affects ruler lines and selection snapping. While measuring, T cycles the presets and +/− adjusts them; the choice is remembered here.", bundle: .module))
                }
            }

            SettingsDivider()

            SettingsRow(Text("Pins", bundle: .module)) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Corners", bundle: .module)
                            .fixedSize()
                        // Rounded here rather than with `step:`, which hangs a row of tick marks under the
                        // slider and lifts it off the label's line.
                        Slider(
                            value: Binding(get: { settings.pinCornerRadius }, set: { settings.pinCornerRadius = $0.rounded() }),
                            in: SettingsStore.pinCornerRadii
                        ) {
                            Text("Corners", bundle: .module)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Text("\(Int(settings.pinCornerRadius)) pt", bundle: .module)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                    }
                    HStack(spacing: 14) {
                        Toggle(isOn: $settings.pinShadow) {
                            Text("Shadow", bundle: .module)
                        }
                        Toggle(isOn: $settings.pinBorder) {
                            Text("Border", bundle: .module)
                        }
                        .help(Text("A hairline, so a white picture still reads against a white window.", bundle: .module))
                    }
                    Toggle(isOn: $settings.pinsAppearInCaptures) {
                        Text("Show in screenshots", bundle: .module)
                    }
                }
            }
        }
    }

    /// The languages to translate into, by identifier; the chosen one even before the list has loaded.
    private var translationOptions: [String] {
        var options = translationTargets.map(Translator.identifier(of:))
        let choice = settings.translationTarget
        if !choice.isEmpty, !options.contains(choice) { options.insert(choice, at: 0) }
        return options
    }
}

struct ShortcutsSettingsView: View {
    let destinations: UploadDestinationStore
    /// Whether the formula pack is installed, read as the pane opens.
    let hasFormulaPack: () -> Bool

    /// The shortcuts in the order of `CaptureShortcut`, split into the pane's groups. Those that upload are left
    /// out until a destination is set up, as every upload entry is left out of the capture interface, and Capture
    /// Formula until the formula pack is installed, unless a key was chosen for one: it stays listed to be changed or
    /// cleared.
    static func groups(hasDestination: Bool, hasFormulaPack: Bool = false, hasKey: (CaptureShortcut) -> Bool) -> [[CaptureShortcut]] {
        let listed = CaptureShortcut.allCases.filter { shortcut in
            shortcut.isAvailable && (hasDestination || !shortcut.needsUploadDestination || hasKey(shortcut))
                && (hasFormulaPack || !shortcut.needsFormulaPack || hasKey(shortcut))
        }
        return Dictionary(grouping: listed, by: \.group)
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    var body: some View {
        let groups = Self.groups(hasDestination: !destinations.destinations.isEmpty, hasFormulaPack: hasFormulaPack()) { KeyboardShortcuts.getShortcut(for: $0.name) != nil }
        SettingsPane(alignment: .leading, spacing: 8) {
            ForEach(groups.indices, id: \.self) { index in
                if index > 0 {
                    SettingsDivider()
                }
                ForEach(groups[index], id: \.self) { shortcut in
                    SettingsRow(Text(shortcut.title)) {
                        KeyboardShortcuts.Recorder(for: shortcut.name) { keys in
                            HotkeyCenter.clearOtherAssignments(of: keys, keeping: shortcut.name)
                        }
                        .keyboardShortcutsConflictPolicy(.init(menuItem: .warn))
                    }
                }
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose Use Anyway to override an app menu shortcut. Assigning the same shortcut to another action removes its previous assignment.", bundle: .module)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("macOS keeps ⇧⌘3, ⇧⌘4, and ⇧⌘5 until you turn them off in Keyboard Settings.", bundle: .module)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                } label: {
                    Text("Open Keyboard Settings", bundle: .module)
                }
                .buttonStyle(.link)
            }
            .font(.callout)
            .gridCellUnsizedAxes(.horizontal)
        }
    }
}

extension CaptureShortcut {
    /// Which group of the Shortcuts pane the shortcut is listed in.
    fileprivate var group: Int {
        switch self {
        case .captureArea, .annotateArea, .pinArea, .captureAreaAndCopy, .captureAreaAndSave, .captureAreaAndAnnotate, .captureAreaAndUpload, .captureFullscreen,
             .captureFullscreenAndUpload, .captureWindow, .capturePreviousArea, .allInOne, .selfTimer, .scrollingCapture, .recordScreen, .saveReplay: 0
        case .captureText, .captureTextJoined, .captureFormula, .translateArea: 1
        case .pickColor, .measure: 2
        case .openHistory, .copyLatestCapture, .annotateLatestCapture, .openFromClipboard, .controlQuickAccess: 3
        }
    }
}

struct PermissionsSettingsView: View {
    let permissions: PermissionCenter
    let relaunch: () -> Void

    var body: some View {
        SettingsPane {
            PermissionRow(permission: .screenRecording, permissions: permissions)
            if permissions.status(of: .screenRecording) != .granted {
                SettingsRow {
                    HStack(spacing: 6) {
                        Text("macOS applies it after a relaunch.", bundle: .module)
                            .foregroundStyle(.secondary)
                        Button(action: relaunch) {
                            Text("Relaunch Now", bundle: .module)
                        }
                        .buttonStyle(.link)
                    }
                    .font(.callout)
                }
            }

            SettingsDivider()

            ForEach([Permission.microphone, .camera, .accessibility, .inputMonitoring]) { permission in
                PermissionRow(permission: permission, permissions: permissions)
            }
        }
        .onAppear {
            permissions.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            permissions.refresh()
        }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let permissions: PermissionCenter

    var body: some View {
        SettingsRow(Text(permission.title)) {
            Group {
                switch permissions.status(of: permission) {
                case .granted:
                    Label {
                        Text("Allowed", bundle: .module)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .foregroundStyle(.secondary)
                case .notGranted:
                    Button {
                        Task {
                            await permissions.request(permission)
                            if permissions.status(of: permission) != .granted {
                                permissions.openSystemSettings(for: permission)
                            }
                        }
                    } label: {
                        Text("Allow…", bundle: .module)
                    }
                case .denied:
                    Button {
                        permissions.openSystemSettings(for: permission)
                    } label: {
                        Text("Open System Settings…", bundle: .module)
                    }
                }
            }
            .help(permission.purpose)
        }
    }
}

extension Permission {
    var title: String {
        switch self {
        case .screenRecording: String(localized: "Screen Recording", bundle: .module)
        case .microphone: String(localized: "Microphone", bundle: .module)
        case .camera: String(localized: "Camera", bundle: .module)
        case .accessibility: String(localized: "Accessibility", bundle: .module)
        case .inputMonitoring: String(localized: "Input Monitoring", bundle: .module)
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording: String(localized: "Take screenshots and record the screen.", bundle: .module)
        case .microphone: String(localized: "Record your voice with screen recordings.", bundle: .module)
        case .camera: String(localized: "Show your camera in screen recordings.", bundle: .module)
        case .accessibility: String(localized: "Scroll for you during scrolling capture, and read text straight from apps.", bundle: .module)
        case .inputMonitoring: String(localized: "Show the keys you press in screen recordings.", bundle: .module)
        }
    }
}

struct AutomationSettingsView: View {
    @Bindable var settings: SettingsStore
    let urlScheme: String

    var body: some View {
        SettingsPane {
            SettingsRow(Text("URL scheme", bundle: .module)) {
                HStack(spacing: 6) {
                    Toggle(isOn: $settings.automationEnabled) {
                        Text("Allow other apps to control OhMyShot", bundle: .module)
                    }
                    InfoButton(Text("Apps and scripts send commands such as \(urlScheme)://capture-area, with the same names and parameters as CleanShot X. Each app needs your approval the first time.", bundle: .module))
                }
            }
            SettingsRow(Text("Approved apps", bundle: .module)) {
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

struct AboutSettingsView: View {
    var body: some View {
        // In a scroll view like the other panes, so the toolbar above stays clear rather than drawing its own
        // grey background over a pane with nothing to scroll.
        ScrollView {
            about
                .containerRelativeFrame([.horizontal, .vertical])
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(minWidth: paneWidth, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var about: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(Self.info("CFBundleDisplayName") ?? "OhMyShot")
                .font(.title2.weight(.semibold))
            Text("Version \(Self.info("CFBundleShortVersionString") ?? "?") (\(Self.info("CFBundleVersion") ?? "?"))", bundle: .module)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Free software under the GNU General Public License v3.", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding(28)
    }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
