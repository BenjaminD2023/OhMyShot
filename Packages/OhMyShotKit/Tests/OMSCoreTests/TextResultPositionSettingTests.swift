import Foundation
import Testing
@testable import OMSCore

@MainActor
struct TextResultPositionSettingTests {
    @Test func newAndUnknownPreferencesKeepTheCardByItsSelection() throws {
        let suite = "TextResultPositionTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SettingsStore(defaults: defaults).textResultPosition == .belowSelection)
        defaults.set("future-position", forKey: "textResultPosition")
        #expect(SettingsStore(defaults: defaults).textResultPosition == .belowSelection)
    }

    @Test func eachChoicePersistsWithoutEnablingTheOptionalPopup() throws {
        let suite = "TextResultPositionTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        for position in TextResultPosition.allCases {
            settings.textResultPosition = position
            let reopened = SettingsStore(defaults: defaults)
            #expect(reopened.textResultPosition == position)
            #expect(!reopened.showTextResult)
        }
    }

    @Test func copiedTextPopupDefaultsToOneSecond() throws {
        let suite = "TextResultCloseTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.textResultCloseAfter == 1)
        #expect(!settings.showTextResult)
        #expect(SettingsStore.textResultCloseDelays == [0, 1, 2, 3, 5, 10, 20, 30, 60])
    }

    @Test func everyCloseDelayPersistsIncludingExplicitNever() throws {
        let suite = "TextResultCloseTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.textResultPosition = .bottomLeft
        for seconds in SettingsStore.textResultCloseDelays {
            settings.textResultCloseAfter = seconds
            #expect(defaults.object(forKey: "textResultCloseAfter") as? Int == seconds)
            let reopened = SettingsStore(defaults: defaults)
            #expect(reopened.textResultCloseAfter == seconds)
            #expect(reopened.textResultPosition == .bottomLeft)
            #expect(!reopened.showTextResult)
        }
    }

    @Test func unknownCloseDelaysFallBackToOneSecond() throws {
        let suite = "TextResultCloseTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for invalid in [-1, 4, 7, Int.max] {
            defaults.set(invalid, forKey: "textResultCloseAfter")
            #expect(SettingsStore(defaults: defaults).textResultCloseAfter == 1)
        }
        // None of these values means an intentional integer 0 (Never).
        let invalidTypes: [Any] = ["0", "unexpected", false, 2.5, [1, 2]]
        for invalid in invalidTypes {
            defaults.set(invalid, forKey: "textResultCloseAfter")
            #expect(SettingsStore(defaults: defaults).textResultCloseAfter == 1)
        }
        defaults.set(0, forKey: "textResultCloseAfter")
        #expect(SettingsStore(defaults: defaults).textResultCloseAfter == 0)
    }

    @Test func textPopupAndScreenshotRecordingCardsKeepIndependentDelays() throws {
        let suite = "IndependentPopupCloseTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.quickAccessCloseAfter = 10
        settings.textResultCloseAfter = 1
        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.quickAccessCloseAfter == 10 && reopened.textResultCloseAfter == 1)
        reopened.textResultCloseAfter = 0
        reopened.quickAccessCloseAfter = 5
        let again = SettingsStore(defaults: defaults)
        #expect(again.quickAccessCloseAfter == 5 && again.textResultCloseAfter == 0)
    }
}
