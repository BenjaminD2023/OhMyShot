import AppKit
import Foundation
import KeyboardShortcuts
import Testing
@testable import OMSUI

@Suite(.serialized)
struct ShortcutListTests {
    @Test func aNewAssignmentTakesTheKeysFromAllPreviousActions() {
        let names = (0..<4).map { KeyboardShortcuts.Name("OMSUITests-\(UUID().uuidString)-\($0)") }
        defer { names.forEach { KeyboardShortcuts.setShortcut(nil, for: $0) } }
        let keys = KeyboardShortcuts.Shortcut(.s, modifiers: [.command, .shift])
        let unrelatedKeys = KeyboardShortcuts.Shortcut(.t, modifiers: [.command, .shift])
        for name in names.prefix(3) { KeyboardShortcuts.setShortcut(keys, for: name) }
        KeyboardShortcuts.setShortcut(unrelatedKeys, for: names[3])

        let cleared = HotkeyCenter.clearOtherAssignments(of: keys, keeping: names[2], among: names)

        #expect(cleared == [names[0], names[1]])
        #expect(KeyboardShortcuts.getShortcut(for: names[0]) == nil)
        #expect(KeyboardShortcuts.getShortcut(for: names[1]) == nil)
        #expect(KeyboardShortcuts.getShortcut(for: names[2]) == keys)
        #expect(KeyboardShortcuts.getShortcut(for: names[3]) == unrelatedKeys)
    }

    @Test func clearingARecorderDoesNotChangeOtherAssignments() {
        let other = KeyboardShortcuts.Name("OMSUITests-\(UUID().uuidString)")
        let cleared = KeyboardShortcuts.Name("OMSUITests-\(UUID().uuidString)")
        defer { KeyboardShortcuts.setShortcut(nil, for: other) }
        let keys = KeyboardShortcuts.Shortcut(.s, modifiers: [.command, .shift])
        KeyboardShortcuts.setShortcut(keys, for: other)

        let removed = HotkeyCenter.clearOtherAssignments(of: nil, keeping: cleared, among: [other, cleared])

        #expect(removed.isEmpty)
        #expect(KeyboardShortcuts.getShortcut(for: other) == keys)
        #expect(KeyboardShortcuts.getShortcut(for: cleared) == nil)
    }

    /// Stands in for the keys chosen in Settings, which are kept in the app's own defaults.
    private static let noKey: (CaptureShortcut) -> Bool = { _ in false }

    private static let newShortcuts: [CaptureShortcut] = [
        .captureAreaAndCopy, .captureAreaAndSave, .captureAreaAndAnnotate, .annotateLatestCapture, .openFromClipboard, .captureFormula,
        .pinFromClipboard, .recognizeClipboard, .togglePins, .restoreRecentlyClosed, .toggleDesktopIcons,
        .pauseRecording, .toggleRecordingMicrophone,
    ]

    @Test func theNewShortcutsHaveNoKeysUntilChosen() throws {
        let suite = "OMSUITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for profile in [HotkeyCenter.Profile.development, .release] {
            let center = HotkeyCenter(profile: profile, defaults: defaults)
            for shortcut in Self.newShortcuts {
                #expect(center.defaultShortcut(for: shortcut) == nil, "\(shortcut.rawValue) has a default key")
            }
        }
    }

    @Test func everyShortcutHasItsOwnTitleAndName() {
        let titles = CaptureShortcut.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        let names = CaptureShortcut.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
    }

    @Test func theUploadShortcutsAreListedOnlyOnceADestinationExists() {
        let uploading = CaptureShortcut.allCases.filter(\.needsUploadDestination)
        #expect(Set(uploading) == [.captureAreaAndUpload, .captureFullscreenAndUpload])

        let without = Set(ShortcutsSettingsView.groups(hasDestination: false, hasKey: Self.noKey).flatMap { $0 })
        let with = Set(ShortcutsSettingsView.groups(hasDestination: true, hasKey: Self.noKey).flatMap { $0 })
        #expect(without.isDisjoint(with: uploading))
        #expect(with.isSuperset(of: uploading))
        // Nothing else goes missing.
        #expect(with.subtracting(without) == Set(uploading))
    }

    @Test func anUploadShortcutWithAKeyStaysListedWithoutADestination() {
        let listed = Set(ShortcutsSettingsView.groups(hasDestination: false) { $0 == .captureAreaAndUpload }.flatMap { $0 })
        #expect(listed.contains(.captureAreaAndUpload))
        #expect(!listed.contains(.captureFullscreenAndUpload))
        // A key on a shortcut that does not upload changes nothing.
        let others = Set(ShortcutsSettingsView.groups(hasDestination: false) { $0 == .captureArea }.flatMap { $0 })
        #expect(others == Set(ShortcutsSettingsView.groups(hasDestination: false, hasKey: Self.noKey).flatMap { $0 }))
    }

    @Test func everyAvailableShortcutIsListedOnceAndNoGroupIsEmpty() {
        for hasDestination in [false, true] {
            for hasFormulaPack in [false, true] {
                let groups = ShortcutsSettingsView.groups(hasDestination: hasDestination, hasFormulaPack: hasFormulaPack, hasKey: Self.noKey)
                #expect(!groups.contains { $0.isEmpty })
                let listed = groups.flatMap { $0 }
                #expect(Set(listed).count == listed.count)
                let expected = CaptureShortcut.allCases.filter {
                    $0.isAvailable && (hasDestination || !$0.needsUploadDestination) && (hasFormulaPack || !$0.needsFormulaPack)
                }
                #expect(Set(listed) == Set(expected))
            }
        }
    }

    @Test func captureFormulaIsListedOnlyOnceThePackIsInstalled() {
        #expect(CaptureShortcut.allCases.filter(\.needsFormulaPack) == [.captureFormula])
        let without = Set(ShortcutsSettingsView.groups(hasDestination: true, hasFormulaPack: false, hasKey: Self.noKey).flatMap { $0 })
        let with = Set(ShortcutsSettingsView.groups(hasDestination: true, hasFormulaPack: true, hasKey: Self.noKey).flatMap { $0 })
        #expect(with.subtracting(without) == [.captureFormula])
        // A key chosen while the pack was installed keeps it listed after the pack is removed.
        let kept = Set(ShortcutsSettingsView.groups(hasDestination: true, hasFormulaPack: false) { $0 == .captureFormula }.flatMap { $0 })
        #expect(kept.contains(.captureFormula))
        // Beside Capture Text, in the text group.
        let textGroup = ShortcutsSettingsView.groups(hasDestination: true, hasFormulaPack: true, hasKey: Self.noKey).first { $0.contains(.captureText) }
        #expect(textGroup == [.captureText, .captureTextJoined, .captureFormula, .translateArea])
    }

    @Test func thePinShortcutsSitWithTheToolsAndRestoreWithTheHistory() throws {
        let groups = ShortcutsSettingsView.groups(hasDestination: true, hasKey: Self.noKey)
        let tools = try #require(groups.first { $0.contains(.pickColor) })
        #expect(tools.contains(.togglePins))
        #expect(tools.contains(.toggleDesktopIcons))
        let history = try #require(groups.first { $0.contains(.openHistory) })
        #expect(history.contains(.restoreRecentlyClosed))
    }

    @Test func theAreaShortcutsAreListedTogetherAndInOrder() throws {
        let capturing = try #require(ShortcutsSettingsView.groups(hasDestination: true, hasKey: Self.noKey).first)
        let order: [CaptureShortcut] = [.captureArea, .annotateArea, .pinArea, .captureAreaAndCopy, .captureAreaAndSave, .captureAreaAndAnnotate, .captureAreaAndUpload]
        #expect(Array(capturing.prefix(order.count)) == order)
    }

    @Test func recordingGroupHoldsPauseAndMicrophoneToggle() throws {
        let recordingGroup = try #require(
            ShortcutsSettingsView.groups(hasDestination: true, hasFormulaPack: true, hasKey: Self.noKey).first { $0.contains(.recordScreen) }
        )
        #expect(recordingGroup.contains(.pauseRecording))
        #expect(recordingGroup.contains(.toggleRecordingMicrophone))
    }

    @Test func clearedNoticeMentionsClearedShortcutTitles() throws {
        #expect(ShortcutsSettingsView.clearedNoticeText(for: []) == nil)
        let notice = try #require(ShortcutsSettingsView.clearedNoticeText(for: [CaptureShortcut.captureArea.name]))
        #expect(notice.contains(CaptureShortcut.captureArea.title))
    }

    @Test func resetToDefaultsRestoresDefaultsAndClearsCustomAssignments() throws {
        let suite = "OMSUITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let snapshot = CaptureShortcut.allCases.map { ($0.name, KeyboardShortcuts.getShortcut(for: $0.name)) }
        defer {
            for (name, keys) in snapshot { KeyboardShortcuts.setShortcut(keys, for: name) }
            defaults.removePersistentDomain(forName: suite)
        }
        let center = HotkeyCenter(profile: .development, defaults: defaults)
        KeyboardShortcuts.setShortcut(nil, for: CaptureShortcut.captureArea.name)
        KeyboardShortcuts.setShortcut(.init(.k, modifiers: [.command, .shift]), for: CaptureShortcut.pinFromClipboard.name)

        center.resetToDefaults()

        #expect(KeyboardShortcuts.getShortcut(for: CaptureShortcut.captureArea.name) == center.defaultShortcut(for: .captureArea))
        #expect(KeyboardShortcuts.getShortcut(for: CaptureShortcut.pinFromClipboard.name) == nil)
    }
}
