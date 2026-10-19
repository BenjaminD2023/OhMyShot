import Foundation
import Testing
@testable import OMSCore

@MainActor
struct CaptureLoupeSizeSettingTests {
    @Test func aNewOrUnknownSizeUsesTheCompactDefault() throws {
        let suite = "CaptureLoupeSizeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SettingsStore(defaults: defaults).captureLoupeSize == .small)
        defaults.set("unknown-size", forKey: "captureLoupeSize")
        #expect(SettingsStore(defaults: defaults).captureLoupeSize == .small)
    }

    @Test func theMagnifiedLensIsTheDefaultAndActualSizeIsKept() throws {
        let suite = "CaptureLoupeSizeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SettingsStore(defaults: defaults).captureLoupeStyle == .magnified)
        defaults.set("unknown-style", forKey: "captureLoupeStyle")
        #expect(SettingsStore(defaults: defaults).captureLoupeStyle == .magnified)
        SettingsStore(defaults: defaults).captureLoupeStyle = .actualSize
        #expect(SettingsStore(defaults: defaults).captureLoupeStyle == .actualSize)
    }

    @Test func theChosenSizeSurvivesReopeningSettings() throws {
        let suite = "CaptureLoupeSizeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        for size in CaptureLoupeSize.allCases {
            settings.captureLoupeSize = size
            #expect(SettingsStore(defaults: defaults).captureLoupeSize == size)
        }
    }
}
