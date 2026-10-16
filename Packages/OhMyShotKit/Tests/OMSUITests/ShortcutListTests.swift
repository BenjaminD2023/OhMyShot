import Foundation
import Testing
@testable import OMSUI

struct ShortcutListTests {
    /// Stands in for the keys chosen in Settings, which are kept in the app's own defaults.
    private static let noKey: (CaptureShortcut) -> Bool = { _ in false }

    private static let newShortcuts: [CaptureShortcut] = [
        .captureAreaAndCopy, .captureAreaAndSave, .captureAreaAndAnnotate, .annotateLatestCapture, .openFromClipboard,
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
            let groups = ShortcutsSettingsView.groups(hasDestination: hasDestination, hasKey: Self.noKey)
            #expect(!groups.contains { $0.isEmpty })
            let listed = groups.flatMap { $0 }
            #expect(Set(listed).count == listed.count)
            let expected = CaptureShortcut.allCases.filter { $0.isAvailable && (hasDestination || !$0.needsUploadDestination) }
            #expect(Set(listed) == Set(expected))
        }
    }

    @Test func theAreaShortcutsAreListedTogetherAndInOrder() throws {
        let capturing = try #require(ShortcutsSettingsView.groups(hasDestination: true, hasKey: Self.noKey).first)
        let order: [CaptureShortcut] = [.captureArea, .annotateArea, .pinArea, .captureAreaAndCopy, .captureAreaAndSave, .captureAreaAndAnnotate, .captureAreaAndUpload]
        #expect(Array(capturing.prefix(order.count)) == order)
    }
}
