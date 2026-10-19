import Foundation
import Testing
@testable import OMSCore

@MainActor
struct MeasureToleranceSettingTests {
    @Test func snappingStartsEnabledAndAnOffChoiceSurvivesReopening() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        #expect(settings.measureSnapsToContent)
        settings.measureSnapsToContent = false
        #expect(!SettingsStore(defaults: defaults).measureSnapsToContent)
        settings.measureSnapsToContent = true
        #expect(SettingsStore(defaults: defaults).measureSnapsToContent)
    }

    @Test func toleranceSurvivesReopeningAndUnknownValuesUseMedium() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        #expect(settings.measureTolerance == .medium)
        for tolerance in MeasureTolerance.allCases {
            settings.measureTolerance = tolerance
            #expect(SettingsStore(defaults: defaults).measureTolerance == tolerance)
        }

        defaults.set("unknown-preset", forKey: "measureTolerance")
        #expect(SettingsStore(defaults: defaults).measureTolerance == .medium)
    }
}
