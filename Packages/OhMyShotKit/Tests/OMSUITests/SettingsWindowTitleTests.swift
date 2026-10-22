import AppKit
import Foundation
import OMSCore
import Testing
@testable import OMSUI

/// The Settings window's title is the name of the pane it shows. The window is made, never shown.
@MainActor
struct SettingsWindowTitleTests {
    /// SwiftUI hands the window the pane's name only when it changes, so the pane the window opens on, General,
    /// once left it "Untitled".
    @Test func theWindowOpensTitledAfterItsFirstPane() async throws {
        let suite = "OMSUITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SettingsWindowController(dependencies: SettingsDependencies(
            settings: SettingsStore(defaults: defaults),
            permissions: PermissionCenter(defaults: defaults),
            urlScheme: "ohmyshot-tests",
            relaunch: {},
            openHistory: {},
            expiredCount: { _ in 0 },
            destinations: UploadDestinationStore(defaults: defaults, secrets: InMemorySecretStore()),
            uploadRecords: UploadRecordStore(fileURL: nil)
        ))
        let window = try #require(controller.window)
        #expect(window.title == SettingsTab.general.title)
        // SwiftUI's first pass over the window leaves it so.
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        #expect(window.title == SettingsTab.general.title)
        window.close()
    }
}
