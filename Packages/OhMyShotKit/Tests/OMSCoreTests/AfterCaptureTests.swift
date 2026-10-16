import Foundation
import Testing
@testable import OMSCore

@MainActor
struct AfterCaptureTests {
    private func suite() throws -> (defaults: UserDefaults, name: String) {
        let name = "OMSCoreTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func recordingsAreKeptAsCapturesAreByDefault() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let expected = AfterCapture(copies: true, showsQuickAccess: true, saves: false, uploads: false)
        #expect(settings.afterCapture(for: .screenshot) == expected)
        #expect(settings.afterCapture(for: .recording) == expected)
    }

    /// Whoever turned Save on for captures had recordings saved too, so recordings start saved.
    @Test func recordingsStartAsTheChoicesForCapturesWere() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "copyAfterCapture")
        defaults.set(false, forKey: "showQuickAccess")
        defaults.set(true, forKey: "saveAfterCapture")
        defaults.set(true, forKey: "uploadAfterCapture")
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.afterCapture(for: .recording) == AfterCapture(copies: false, showsQuickAccess: false, saves: true, uploads: true))
    }

    @Test func recordingsAndScreenshotsGoOnApartOnceTheyHaveTheirOwn() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.copyAfterRecording = false
        settings.showRecordingQuickAccess = false
        settings.saveAfterRecording = true
        settings.uploadAfterRecording = true
        #expect(settings.afterCapture(for: .screenshot) == AfterCapture(copies: true, showsQuickAccess: true, saves: false, uploads: false))
        #expect(settings.afterCapture(for: .recording) == AfterCapture(copies: false, showsQuickAccess: false, saves: true, uploads: true))

        // What is chosen for screenshots afterwards leaves the recordings alone, and the other way round.
        settings.saveAfterCapture = true
        settings.copyAfterCapture = false
        #expect(settings.afterCapture(for: .recording) == AfterCapture(copies: false, showsQuickAccess: false, saves: true, uploads: true))
        settings.copyAfterRecording = true
        #expect(settings.afterCapture(for: .screenshot) == AfterCapture(copies: false, showsQuickAccess: true, saves: true, uploads: false))

        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.afterCapture(for: .recording) == AfterCapture(copies: true, showsQuickAccess: false, saves: true, uploads: true))
        #expect(reopened.afterCapture(for: .screenshot) == AfterCapture(copies: false, showsQuickAccess: true, saves: true, uploads: false))
    }

    /// The recordings' own choices begin at the first launch that knows them and stay: a choice for screenshots
    /// changed later does not move them, even before they were ever touched.
    @Test func theStartIsKeptFromTheFirstLaunch() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        _ = SettingsStore(defaults: defaults)
        defaults.set(true, forKey: "saveAfterCapture")
        #expect(!SettingsStore(defaults: defaults).saveAfterRecording)
    }
}
