import Foundation
import Testing
@testable import OMSCore

/// Settings › General › Reset to Default Settings.
@MainActor
struct SettingsResetTests {
    @Test func resetPutsChoicesBackAndKeepsWhatTheAppKeeps() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.playSounds = false
        settings.captureLoupeMagnification = .eight
        settings.colorCopyGesture = .command
        defaults.set(false, forKey: "SUEnableAutomaticChecks")
        defaults.set(true, forKey: "SUAutomaticallyUpdate")
        settings.freezeScreen = false
        settings.screenshotFormat = .jpeg
        settings.fileNamePattern = "{app}"
        settings.exportDirectory = URL(filePath: "/tmp", directoryHint: .isDirectory)
        settings.copyAfterRecording = false
        settings.quickAccessCorner = .bottomRight
        settings.recordingCameraStyle = CameraStyle(shape: .roundedSquare, size: .large, mirrored: false)
        settings.approvedAutomationCallers = ["com.example.app"]
        settings.hidesDesktopIcons = true
        settings.nextFileNumber = 7

        settings.resetToDefaults()

        for store in [settings, SettingsStore(defaults: defaults)] {
            #expect(store.captureLoupeMagnification == .four)
            #expect(store.colorCopyGesture == .option)
            #expect(defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool == false)
            #expect(defaults.object(forKey: "SUAutomaticallyUpdate") as? Bool == true)
            #expect(store.playSounds)
            #expect(store.freezeScreen)
            #expect(store.screenshotFormat == .png)
            #expect(store.fileNameTemplate == .standard)
            #expect(store.exportDirectory == URL.desktopDirectory)
            #expect(store.copyAfterRecording)
            #expect(store.quickAccessCorner == .bottomLeft)
            #expect(store.recordingCameraStyle == CameraStyle(shape: .circle, size: .medium, mirrored: true))
            #expect(store.approvedAutomationCallers == ["com.example.app"])
            #expect(store.hidesDesktopIcons)
            #expect(store.nextFileNumber == 7)
        }
    }

    /// Every setting the store keeps is either reset or deliberately kept, so one added later is not forgotten: the
    /// store's source is read for the settings it has and the ones `resetToDefaults` sets.
    @Test func everySettingIsResetOrKept() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/OMSCore/Settings/SettingsStore.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let stored = Set(source.matches(of: /public (?:internal\(set\) )?var (\w+): [^{\n]+\{\n\s+didSet/).map { String($0.1) })
        #expect(stored.count > 70)
        let reset = Set(source.matches(of: /(\w+) = fresh\.(\w+)/).filter { $0.1 == $0.2 }.map { String($0.1) })
        let kept: Set = ["nextFileNumber", "allInOneArea", "hidesDesktopIcons", "approvedAutomationCallers"]
        for name in stored {
            #expect(reset.contains(name) || kept.contains(name), "\(name) is not reset")
        }
    }
}
