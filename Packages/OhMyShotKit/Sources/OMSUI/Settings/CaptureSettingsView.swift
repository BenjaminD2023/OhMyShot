import Foundation
import OMSCore
import SwiftUI

/// Settings › Capture: choosing what to capture, and how a window is taken.
struct CaptureSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsPane {
            SettingsRow(String(localized: "Selecting", bundle: .module), help: [
                HelpTopic(String(localized: "Freeze the screen", bundle: .module), Text("Hover states and open menus stay in place until the capture is taken.", bundle: .module)),
                HelpTopic(String(localized: "Show the pointer in screenshots", bundle: .module), Text("The pointer is in the picture where it was when you took it. With the screen frozen, that is where it was when you pressed the shortcut; All-In-One leaves it out then.", bundle: .module)),
                HelpTopic(String(localized: "Shift keeps", bundle: .module), Text("Hold Shift while you drag out an area to keep its shape. Press Tab while choosing an area to type its width and height in pixels; a shape you choose there is the one Shift keeps from then on.", bundle: .module)),
                HelpTopic(String(localized: "Snap the selection to text", bundle: .module), Text("On a frozen screen, the edges of a selection snap to paragraphs, lists, code, and tables near them, with a little room around. Hold Command while dragging to place the edges freely.", bundle: .module)),
                HelpTopic(String(localized: "All-In-One remembers the last area", bundle: .module), Text("All-In-One opens with the area it last took, framed to adjust or take again.", bundle: .module)),
                HelpTopic(String(localized: "Color picker magnification", bundle: .module), Text("Controls how much each screen pixel is enlarged in the centered screenshot picker. The size stays the same when you change magnification. Applies to the next screenshot or Annotate Area capture; Pick Color is unchanged.", bundle: .module)),
                HelpTopic(String(localized: "Copy color shortcut", bundle: .module), Text("Before starting an area selection, or while using Pick Color, this left-click shortcut copies the pointed color without closing the overlay. Other clicks keep their usual behavior.", bundle: .module)),
            ]) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $settings.freezeScreen) {
                        Text("Freeze the screen", bundle: .module)
                    }
                    Toggle(isOn: $settings.screenshotShowsCursor) {
                        Text("Show the pointer in screenshots", bundle: .module)
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
                    }
                    Toggle(isOn: $settings.snapSelectionToText) {
                        Text("Snap the selection to text", bundle: .module)
                    }
                    Toggle(isOn: $settings.allInOneRemembersArea) {
                        Text("All-In-One remembers the last area", bundle: .module)
                    }
                }
            }
            SettingsRow(String(localized: "Color picker size", bundle: .module)) {
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
            SettingsRow(String(localized: "Color picker magnification", bundle: .module)) {
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
                }
            }
            SettingsRow(String(localized: "Copy color shortcut", bundle: .module)) {
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
                }
            }
            SettingsRow(String(localized: "Self-Timer", bundle: .module)) {
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

            SettingsRow(String(localized: "Windows", bundle: .module), help: [
                HelpTopic(String(localized: "Windows", bundle: .module), Text("Desktop wallpaper puts a window on the desktop picture around it, as the screen shows it. Hold Shift as you click a window to take it the other way: with no background, or on the desktop wallpaper.", bundle: .module)),
            ]) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: $settings.windowShadow) {
                        Text("Capture the shadow", bundle: .module)
                    }
                    Picker(selection: $settings.windowBackground) {
                        Text("Same background as screenshots", bundle: .module).tag(WindowBackground.asScreenshots)
                        Text("No background", bundle: .module).tag(WindowBackground.transparent)
                        Text("Desktop wallpaper", bundle: .module).tag(WindowBackground.desktopWallpaper)
                    } label: {
                        Text("Window background", bundle: .module)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }
}
