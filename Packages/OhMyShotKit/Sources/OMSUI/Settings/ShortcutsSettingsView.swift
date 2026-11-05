import AppKit
import Foundation
import KeyboardShortcuts
import OMSCore
import SwiftUI

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
                    SettingsRow(shortcut.title) {
                        KeyboardShortcuts.Recorder(for: shortcut.name) { keys in
                            HotkeyCenter.clearOtherAssignments(of: keys, keeping: shortcut.name)
                        }
                        .keyboardShortcutsConflictPolicy(.init(menuItem: .warn))
                        // The label beside it isn't tied to it, so VoiceOver would hear only "Record Shortcut".
                        .accessibilityLabel(Text(shortcut.title))
                    }
                }
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Keys chosen for one action are taken from any other that had them.", bundle: .module)
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
