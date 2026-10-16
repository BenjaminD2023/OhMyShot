import CoreMedia
import OMSCore
import Testing
@testable import OMSUI

/// What the recording window counts as an edit of a recording, and what it hands the export.
struct RecordingEditTests {
    private let trim = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 600), end: CMTime(seconds: 3, preferredTimescale: 600))

    @Test func aRecordingLeftAloneHasNoEdits() {
        #expect(RecordingEdit().isNone)
        #expect(RecordingEdit(volume: 1, quality: .medium).isNone)
    }

    @Test func everyChangeIsAnEdit() {
        #expect(!RecordingEdit(timeRange: trim).isNone)
        #expect(!RecordingEdit(keepsAudio: false).isNone)
        #expect(!RecordingEdit(scale: 0.5).isNone)
        #expect(!RecordingEdit(volume: 0.5).isNone)
        #expect(!RecordingEdit(quality: .low).isNone)
        #expect(!RecordingEdit(quality: .high).isNone)
    }

    @Test func aVolumeBroughtBackToFullIsNoEdit() {
        // The slider moves in whole percents; its last step is full volume.
        let model = RecordingWindowModel()
        model.hasAudio = true
        model.setVolume(0.6)
        #expect(model.edit(timeRange: nil).volume == 0.6 && !model.edit(timeRange: nil).isNone && model.isEdited)
        model.setVolume(1)
        #expect(model.edit(timeRange: nil).isNone && !model.isEdited)
    }

    @Test func theVolumeStaysBetweenSilenceAndFullAndMovesInWholePercents() {
        let model = RecordingWindowModel()
        model.setVolume(0.123456)
        #expect(model.volume == 0.12)
        model.setVolume(7)
        #expect(model.volume == 1)
        model.setVolume(-3)
        #expect(model.volume == 0)
    }

    @Test func aRecordingWithoutSoundHasNoVolumeToChange() {
        let model = RecordingWindowModel()
        model.hasAudio = false
        model.setVolume(0.2)
        let edit = model.edit(timeRange: nil)
        #expect(edit.keepsAudio && edit.volume == 1)
        #expect(edit.isNone)
    }

    @Test func theQualityGoesWithTheEdit() {
        let model = RecordingWindowModel()
        model.quality = .low
        model.scale = 0.75
        let edit = model.edit(timeRange: trim)
        #expect(edit.quality == .low && edit.scale == 0.75 && edit.timeRange == trim)
        #expect(model.isEdited)
    }

    @Test func eachQualityHasItsOwnNames() {
        let titles = RecordingQuality.allCases.map(\.title)
        let menuTitles = RecordingQuality.allCases.map(\.menuTitle)
        #expect(Set(titles).count == 3 && Set(menuTitles).count == 3)
    }
}
