import AppKit
import Foundation
import KeyboardShortcuts
import OMSCore
import SwiftUI

struct ShortcutsSettingsView: View {
    let destinations: UploadDestinationStore
    /// Whether the formula pack is installed, read as the pane opens.
    let hasFormulaPack: () -> Bool
    private let resetShortcuts: () -> Void

    @State private var clashesByShortcut: [CaptureShortcut: SystemScreenshotKeys.Clash] = [:]
    @State private var clearedNotice: (shortcut: CaptureShortcut, message: String)?
    @State private var noticeTask: Task<Void, Never>?
    @State private var confirmsReset = false

    #if DEBUG
    private static var defaultProfile: HotkeyCenter.Profile { .development }
    #else
    private static var defaultProfile: HotkeyCenter.Profile { .release }
    #endif

    /// Docs/keyboard.md: the keys of every surface, the capture overlay's by purpose to the editor's and History's.
    static let keyboardReference = URL(string: "https://github.com/MMFoundation/ohmyshot/blob/main/Docs/keyboard.md")!

    init(
        destinations: UploadDestinationStore,
        resetShortcuts: (() -> Void)? = nil,
        hasFormulaPack: @escaping () -> Bool
    ) {
        self.destinations = destinations
        self.resetShortcuts = resetShortcuts ?? { HotkeyCenter(profile: Self.defaultProfile).resetToDefaults() }
        self.hasFormulaPack = hasFormulaPack
    }

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

    /// Formats the inline notice shown when assigning keys clears them from other actions.
    static func clearedNoticeText(for cleared: [KeyboardShortcuts.Name]) -> String? {
        let titles = cleared.compactMap { CaptureShortcut(rawValue: $0.rawValue)?.title }
        guard !titles.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: titles)
        return String(localized: "Cleared shortcut from \(list).", bundle: .module)
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
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                KeyboardShortcuts.Recorder(for: shortcut.name) { keys in
                                    let cleared = HotkeyCenter.clearOtherAssignments(of: keys, keeping: shortcut.name)
                                    showClearedNotice(for: cleared, assignedTo: shortcut)
                                    refreshClashes()
                                }
                                .keyboardShortcutsConflictPolicy(.init(menuItem: .warn))
                                // The label beside it isn't tied to it, so VoiceOver would hear only "Record Shortcut".
                                .accessibilityLabel(Text(shortcut.title))

                                if let clash = clashesByShortcut[shortcut] {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .help(String(localized: "\(clash.keys) is currently assigned to macOS Screenshots in System Settings.", bundle: .module))
                                        .accessibilityLabel(Text("Conflicts with macOS Screenshots (\(clash.keys))", bundle: .module))
                                }
                            }
                            if let notice = clearedNotice, notice.shortcut == shortcut {
                                Text(notice.message)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            SettingsDivider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Keys chosen for one action are taken from any other that had them.", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("macOS keeps ⇧⌘3, ⇧⌘4, and ⇧⌘5 until you turn them off in Keyboard Settings.", bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        } label: {
                            Text("Open Keyboard Settings", bundle: .module)
                        }
                        .buttonStyle(.link)
                        // Every key OhMyShot answers once something of it is open, which this pane's shortcuts open.
                        Link(destination: Self.keyboardReference) {
                            Text("Keyboard Reference", bundle: .module)
                        }
                    }
                    .font(.callout)
                    Spacer()
                    Button {
                        confirmsReset = true
                    } label: {
                        Text("Reset Shortcuts…", bundle: .module)
                    }
                }
                .padding(.top, 2)
            }
            .gridCellUnsizedAxes(.horizontal)
        }
        .onAppear {
            refreshClashes()
        }
        .onDisappear {
            noticeTask?.cancel()
            noticeTask = nil
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                refreshClashes()
            }
        }
        .confirmationDialog(
            Text("Reset all shortcuts to their defaults?", bundle: .module),
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                resetShortcuts()
                noticeTask?.cancel()
                noticeTask = nil
                clearedNotice = nil
                refreshClashes()
            } label: {
                Text("Reset", bundle: .module)
            }
        } message: {
            Text("Custom shortcuts will be cleared and default shortcuts will be restored.", bundle: .module)
        }
    }

    private func refreshClashes() {
        let clashes = SystemScreenshotKeys.clashes(
            hotKeys: SystemScreenshotKeys.readHotKeys(),
            bindings: SystemScreenshotKeys.currentBindings()
        )
        clashesByShortcut = Dictionary(
            clashes.filter(\.takenByMacOS).map { ($0.shortcut, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func showClearedNotice(for cleared: [KeyboardShortcuts.Name], assignedTo shortcut: CaptureShortcut) {
        noticeTask?.cancel()
        noticeTask = nil
        guard let message = Self.clearedNoticeText(for: cleared) else {
            if clearedNotice?.shortcut == shortcut { clearedNotice = nil }
            return
        }
        clearedNotice = (shortcut, message)
        AccessibilityNotification.Announcement(message).post()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if clearedNotice?.shortcut == shortcut {
                clearedNotice = nil
            }
        }
    }
}

extension CaptureShortcut {
    /// Which group of the Shortcuts pane the shortcut is listed in.
    fileprivate var group: Int {
        switch self {
        case .captureArea, .annotateArea, .pinArea, .captureAreaAndCopy, .captureAreaAndSave, .captureAreaAndAnnotate, .captureAreaAndUpload, .captureFullscreen,
             .captureFullscreenAndUpload, .captureWindow, .capturePreviousArea, .allInOne, .selfTimer, .scrollingCapture:
            0
        case .recordScreen, .pauseRecording, .toggleRecordingMicrophone, .saveReplay:
            1
        case .captureText, .captureTextJoined, .captureFormula, .translateArea:
            2
        case .pickColor, .measure, .drawOnScreen, .toggleDesktopIcons, .togglePins:
            3
        case .openHistory, .copyLatestCapture, .annotateLatestCapture, .openFromClipboard, .pinFromClipboard, .recognizeClipboard, .restoreRecentlyClosed, .controlQuickAccess:
            4
        }
    }
}
