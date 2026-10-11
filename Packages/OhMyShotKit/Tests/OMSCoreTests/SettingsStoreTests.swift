import Foundation
import Testing
@testable import OMSCore

@MainActor
struct SettingsStoreTests {
    @Test func theReplaysSoundIsKeptAndStartsWithBoth() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.replaySound == .all)
        settings.replaySound = .microphone
        #expect(SettingsStore(defaults: defaults).replaySound == .microphone)
        #expect(ReplaySound.system.keepsSystem && !ReplaySound.system.keepsMicrophone)
        #expect(!ReplaySound.none.keepsSystem && !ReplaySound.none.keepsMicrophone)
    }
}
