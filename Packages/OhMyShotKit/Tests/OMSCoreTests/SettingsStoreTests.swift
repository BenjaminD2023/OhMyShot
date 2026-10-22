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

    /// The recording bar opens with the last of Video and GIF; a Studio take is never kept for the next.
    @Test func studioIsNotKeptForTheNextRecording() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.recordingOutput == .video)
        settings.recordingOutput = .gif
        settings.recordingOutput = .studio
        #expect(settings.recordingOutput == .gif)
        #expect(SettingsStore(defaults: defaults).recordingOutput == .gif)
        // Kept by a version before this one.
        defaults.set(RecordingOutput.studio.rawValue, forKey: "recordingOutput")
        #expect(SettingsStore(defaults: defaults).recordingOutput == .video)
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
        let first = settings.reserveFileName(date: date, appName: nil, windowTitle: nil)
        #expect(first.name == "Shot 1" && first.number == 1)
        #expect(settings.nextFileName(date: date, appName: nil, windowTitle: nil) == "Shot 2")
        // A name the person typed is no file of the pattern's: the number goes back.
        let typed = settings.reserveFileName(date: date, appName: nil, windowTitle: nil)
        #expect(typed.name == "Shot 2")
        settings.release(typed)
        #expect(settings.nextFileName(date: date, appName: nil, windowTitle: nil) == "Shot 2")
        // And the count outlives the app.
        #expect(SettingsStore(defaults: defaults).nextFileNumber == 2)
    }

    /// Two files named while the first still waits (its name asked for, a Save As panel up) take two numbers: the number
    /// is taken at once, not when the file is saved.
    @Test func filesNamedAtTheSameTimeTakeNumbersOfTheirOwn() throws {
        let (settings, _, cleanUp) = try makeSettings()
        defer { cleanUp() }
        settings.fileNamePattern = "Shot {counter}"
        let date = Date(timeIntervalSince1970: 1_791_419_110)
        let first = settings.reserveFileName(date: date, appName: nil, windowTitle: nil)
        let second = settings.reserveFileName(date: date, appName: nil, windowTitle: nil)
        let third = settings.reserveFileName(date: date, appName: nil, windowTitle: nil)
        #expect([first.name, second.name, third.name] == ["Shot 1", "Shot 2", "Shot 3"])
        // The latest number can be taken back, and is the next file's again.
        settings.release(third)
        #expect(settings.nextFileNumber == 3)
        // One a later file has gone past is left a gap: that file's number stays its own.
        settings.release(first)
        #expect(settings.nextFileNumber == 3)
        let fourth = settings.reserveFileName(date: date, appName: nil, windowTitle: nil)
        #expect(fourth.name == "Shot 3")
        #expect(settings.nextFileNumber == 4)
    }

    @Test func aPatternWithNoCounterTakesNoNumbers() throws {
        let (settings, _, cleanUp) = try makeSettings()
        defer { cleanUp() }
        let date = Date(timeIntervalSince1970: 1_791_419_110)
        let reserved = settings.reserveFileName(date: date, appName: nil, windowTitle: nil)
        #expect(reserved.number == nil)
        settings.release(reserved)
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

@MainActor
struct SelectingSettingsTests {
    @Test func screenshotsLeaveOutThePointerUnlessAskedFor() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(!settings.screenshotShowsCursor)
        settings.screenshotShowsCursor = true
        #expect(SettingsStore(defaults: defaults).screenshotShowsCursor)
    }

    /// Shift keeps a square until Settings name another shape; a value that is no shape is a square too.
    @Test func shiftKeepsASquareUnlessAnotherShapeIsKept() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.areaShape.isEmpty && settings.areaRatio == nil)
        settings.areaShape = "16:9"
        #expect(settings.areaRatio == AspectRatio(width: 16, height: 9))
        let reopened = SettingsStore(defaults: defaults)
        #expect(reopened.areaShape == "16:9" && reopened.areaRatio == AspectRatio(width: 16, height: 9))
        defaults.set("wide", forKey: "areaShape")
        let garbled = SettingsStore(defaults: defaults)
        #expect(garbled.areaShape.isEmpty && garbled.areaRatio == nil)
    }

    /// Only a shape the picker lists is kept: a square is the empty one, and an absurd or unlisted shape is a square.
    @Test func onlyAShapeThePickerListsIsKept() throws {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for shape in AspectRatio.presets.dropFirst().map(\.label) {
            defaults.set(shape, forKey: "areaShape")
            #expect(SettingsStore(defaults: defaults).areaShape == shape, "\(shape)")
        }
        for shape in ["1:1", "5:4", "1e300:1", "1e-9:1", "16 : 9", "16:9:1"] {
            defaults.set(shape, forKey: "areaShape")
            let settings = SettingsStore(defaults: defaults)
            #expect(settings.areaShape.isEmpty && settings.areaRatio == nil, "\(shape)")
        }
    }
}
