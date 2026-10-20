import Foundation
import Testing
@testable import OMSCore

@MainActor
struct ColorCopyGestureSettingTests {
    private func makeSettings() throws -> (SettingsStore, UserDefaults, () -> Void) {
        let suite = "ColorCopyGestureSettingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (SettingsStore(defaults: defaults), defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func theGestureStartsWithOptionClick() throws {
        let (settings, _, cleanUp) = try makeSettings()
        defer { cleanUp() }
        #expect(settings.colorCopyGesture == .option)
    }

    @Test(arguments: ColorCopyGesture.allCases)
    func everyGestureIncludingDisabledIsRemembered(_ gesture: ColorCopyGesture) throws {
        let (settings, defaults, cleanUp) = try makeSettings()
        defer { cleanUp() }
        settings.colorCopyGesture = gesture
        settings.colorFormat = .rgb
        let restored = SettingsStore(defaults: defaults)
        #expect(restored.colorCopyGesture == gesture)
        #expect(restored.colorFormat == .rgb)
        #expect(restored.captureLoupeSize == .small && restored.captureLoupeMagnification == .four)
    }

    @Test func unknownPreferencesFallBackToOptionClick() throws {
        let (_, defaults, cleanUp) = try makeSettings()
        defer { cleanUp() }
        for value: Any in ["unknown", "", 17, true, ["option"]] {
            defaults.set(value, forKey: "colorCopyGesture")
            #expect(SettingsStore(defaults: defaults).colorCopyGesture == .option)
        }
    }
}
