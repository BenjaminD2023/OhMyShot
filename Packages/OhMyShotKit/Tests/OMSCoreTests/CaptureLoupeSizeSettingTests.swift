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
    @Test func aNewOrUnknownMagnificationKeepsTheFourTimesDefault() throws {
        let suite = "CaptureLoupeSizeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SettingsStore(defaults: defaults).captureLoupeMagnification == .four)
        defaults.set("unknown-magnification", forKey: "captureLoupeMagnification")
        #expect(SettingsStore(defaults: defaults).captureLoupeMagnification == .four)
    }

    @Test func magnificationSurvivesReopeningWithoutChangingThePickerSize() throws {
        let suite = "CaptureLoupeSizeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.captureLoupeSize = .large
        for magnification in CaptureLoupeMagnification.allCases {
            settings.captureLoupeMagnification = magnification
            let restored = SettingsStore(defaults: defaults)
            #expect(restored.captureLoupeMagnification == magnification)
            #expect(restored.captureLoupeSize == .large)
        }
    }

    @Test func everyMagnificationAndSizeKeepsAnOddCenterAtOneAndTwoTimesBackingScale() {
        let cases: [(scale: CGFloat, counts: [[Int]])] = [
            (1, [[75, 91, 121], [37, 45, 61], [19, 23, 31], [9, 11, 15]]),
            (2, [[151, 181, 241], [75, 91, 121], [37, 45, 61], [19, 23, 31]]),
        ]
        for (scale, counts) in cases {
            for (magnification, expected) in zip(CaptureLoupeMagnification.allCases, counts) {
                for (size, count) in zip(CaptureLoupeSize.allCases, expected) {
                    #expect(size.pixelsAcross(backingScale: scale, magnification: magnification) == count)
                    #expect(count % 2 == 1)
                    // Omitting the new argument preserves all existing 4× callers.
                    #expect(size.pixelsAcross(backingScale: scale) == size.pixelsAcross(backingScale: scale, magnification: .four))
                }
            }
        }
    }
}
