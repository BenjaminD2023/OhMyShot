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

@MainActor
struct FileSettingsTests {
    private func makeSettings() throws -> (SettingsStore, UserDefaults, () -> Void) {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (SettingsStore(defaults: defaults), defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func screenshotsAreSavedAsTheyAreTakenUnlessAskedOtherwise() throws {
        let (settings, _, cleanUp) = try makeSettings()
        defer { cleanUp() }
        #expect(settings.screenshotOutput == .standard)
        #expect(settings.screenshotOutput.isUnchanged)
        #expect(settings.screenshotFormat == .png && settings.screenshotQuality == 0.9)
        #expect(!settings.savesRetinaAtOneX && !settings.convertsToSRGB && !settings.addsBorder)
        #expect(settings.fileNameTemplate == .standard)
        #expect(!settings.asksForFileName)
        #expect(settings.clipboardFormat == .pictureOnly)
        #expect(settings.nextFileNumber == 1)
    }

    @Test func theFileSettingsAreKept() throws {
        let (settings, defaults, cleanUp) = try makeSettings()
        defer { cleanUp() }
        settings.screenshotFormat = .heic
        settings.screenshotQuality = 0.7
        settings.savesRetinaAtOneX = true
        settings.convertsToSRGB = true
        settings.addsBorder = true
        settings.fileNamePattern = "{app} {counter}"
        settings.asksForFileName = true
        settings.clipboardFormat = .fileAndPicture
        let again = SettingsStore(defaults: defaults)
        #expect(again.screenshotOutput == ScreenshotOutput(format: .heic, quality: 0.7, retinaAtOneX: true, convertsToSRGB: true, addsBorder: true))
        #expect(again.fileNamePattern == "{app} {counter}")
        #expect(again.asksForFileName)
        #expect(again.clipboardFormat == .fileAndPicture)
    }

    @Test func aQualityOutOfRangeIsBroughtBackIn() throws {
        let (_, defaults, cleanUp) = try makeSettings()
        defer { cleanUp() }
        defaults.set(5.0, forKey: "screenshotQuality")
        #expect(SettingsStore(defaults: defaults).screenshotQuality == 1)
        defaults.set(0.0, forKey: "screenshotQuality")
        #expect(SettingsStore(defaults: defaults).screenshotQuality == 0.5)
    }

    @Test func theCounterCountsFilesSavedUnderTheNameItOffered() throws {
        let (settings, defaults, cleanUp) = try makeSettings()
        defer { cleanUp() }
        settings.fileNamePattern = "Shot {counter}"
        let date = Date(timeIntervalSince1970: 1_791_419_110)
        #expect(settings.nextFileName(date: date, appName: nil, windowTitle: nil) == "Shot 1")
        // Asking for the name takes no number.
        #expect(settings.nextFileName(date: date, appName: nil, windowTitle: nil) == "Shot 1")
        settings.didSaveFile(named: "Shot 1", offered: "Shot 1")
        #expect(settings.nextFileName(date: date, appName: nil, windowTitle: nil) == "Shot 2")
        // A name the person typed is no file of the pattern's.
        settings.didSaveFile(named: "Receipt", offered: "Shot 2")
        #expect(settings.nextFileName(date: date, appName: nil, windowTitle: nil) == "Shot 2")
        // And the count outlives the app.
        #expect(SettingsStore(defaults: defaults).nextFileNumber == 2)
    }

    @Test func aPatternWithNoCounterTakesNoNumbers() throws {
        let (settings, _, cleanUp) = try makeSettings()
        defer { cleanUp() }
        settings.didSaveFile(named: "OhMyShot", offered: "OhMyShot")
        #expect(settings.nextFileNumber == 1)
    }
}

@MainActor
struct CopyLinkSettingTests {
    @Test func theLinkIsCopiedAfterAnUploadUnlessTurnedOff() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.copyLinkAfterUpload)
        settings.copyLinkAfterUpload = false
        #expect(!SettingsStore(defaults: defaults).copyLinkAfterUpload)
    }
}

@MainActor
struct UploadAfterCaptureSettingTests {
    @Test func capturesAreNotUploadedUnlessAskedFor() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(!settings.uploadAfterCapture)
        settings.uploadAfterCapture = true
        #expect(SettingsStore(defaults: defaults).uploadAfterCapture)
    }
}
