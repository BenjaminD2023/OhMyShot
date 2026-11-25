import CoreMedia
import Foundation
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

    @Test func gifExportOptionsDefaultsAndClamping() {
        let defaults = GIFExportOptions()
        #expect(defaults.framesPerSecond == 15)
        #expect(defaults.scale == 1.0)

        let tooLow = GIFExportOptions(framesPerSecond: 1, scale: 0.05)
        #expect(tooLow.framesPerSecond == 5)
        #expect(tooLow.scale == 0.25)

        let tooHigh = GIFExportOptions(framesPerSecond: 120, scale: 2.5)
        #expect(tooHigh.framesPerSecond == 60)
        #expect(tooHigh.scale == 1.0)
    }

    @Test func gifOptionsAloneDoNotMarkRecordingAsEdited() {
        let edit = RecordingEdit(gifOptions: GIFExportOptions(framesPerSecond: 30, scale: 0.5))
        #expect(edit.isNone)
        #expect(edit.gifOptions == GIFExportOptions(framesPerSecond: 30, scale: 0.5))
    }

    @Test func gifDimensionsRespectRetinaStandardAndToolbarResize() {
        let model = RecordingWindowModel()
        // Retina 2× recording: on-screen 1× size is half the native pixels.
        model.pixelWidth = 2880
        model.pixelHeight = 1800
        model.pixelsPerPoint = 2.0
        model.scale = 1.0
        #expect(model.gifDimensions(scale: 1.0) == "1440 × 900")
        #expect(model.gifDimensions(scale: 0.75) == "1080 × 674")
        #expect(model.gifDimensions(scale: 0.5) == "720 × 450")

        // When the toolbar Size is already smaller than on-screen 1× (0.25 < 0.5), GIF scales from that smaller size.
        model.scale = 0.25
        #expect(model.gifDimensions(scale: 1.0) == "720 × 450")
        #expect(model.gifDimensions(scale: 0.5) == "360 × 224")

        // Standard 1× recording: on-screen 1× size equals native pixels.
        model.pixelWidth = 1280
        model.pixelHeight = 720
        model.pixelsPerPoint = 1.0
        model.scale = 1.0
        #expect(model.gifDimensions(scale: 1.0) == "1280 × 720")
        #expect(model.gifDimensions(scale: 0.75) == "960 × 540")
        #expect(model.gifDimensions(scale: 0.5) == "640 × 360")

        // Toolbar Size at 0.5 on a 1× display scales further by the popover's GIF scale.
        model.scale = 0.5
        #expect(model.gifDimensions(scale: 1.0) == "640 × 360")
        #expect(model.gifDimensions(scale: 0.5) == "320 × 180")
    }

    @Test func gifFrameRateOptionsPreserveCustomDefaultSortedUniquely() {
        let model = RecordingWindowModel()
        model.defaultGIFFrameRate = 24
        model.gifFrameRate = 24
        #expect(model.gifFrameRateOptions == [10, 15, 20, 24, 30])
        model.gifFrameRate = 15
        #expect(model.gifFrameRateOptions == [10, 15, 20, 24, 30])
    }

    @Test func makeGIFPassesOneOffOptionsWithoutMarkingUnkeptEdits() async {
        let url = URL(fileURLWithPath: "/tmp/ohmyshot-gif-override-test.mp4")

        // Explicit one-off GIFExportOptions passed to makeGIF(options:).
        do {
            var capturedEdit: RecordingEdit?
            var continuation: CheckedContinuation<Void, Never>?
            let controller = RecordingWindowController(
                fileURL: url, title: "Test", pixelWidth: 2880, pixelHeight: 1800,
                pixelsPerPoint: 2, hasOriginal: false, defaultGIFFrameRate: 15,
                actions: .init(
                    keep: { _, _ in url },
                    revert: { url },
                    makeGIF: { edit, progress in
                        capturedEdit = edit
                        progress(1)
                        continuation?.resume()
                        continuation = nil
                    },
                    save: { _ in nil },
                    copy: { _ in }
                )
            )
            defer { controller.close {} }

            #expect(!controller.hasUnkeptEdits)
            let override = GIFExportOptions(framesPerSecond: 30, scale: 0.75)
            await withCheckedContinuation { cont in
                continuation = cont
                controller.makeGIF(options: override)
            }
            #expect(capturedEdit?.gifOptions == override)
            #expect(capturedEdit?.isNone == true)
            #expect(!controller.hasUnkeptEdits)
        }

        // Calling makeGIF() with nil options uses the controller's defaultGIFFrameRate and model scale.
        do {
            var capturedEdit: RecordingEdit?
            var continuation: CheckedContinuation<Void, Never>?
            let controller = RecordingWindowController(
                fileURL: url, title: "Test", pixelWidth: 2880, pixelHeight: 1800,
                pixelsPerPoint: 2, hasOriginal: false, defaultGIFFrameRate: 20,
                actions: .init(
                    keep: { _, _ in url },
                    revert: { url },
                    makeGIF: { edit, progress in
                        capturedEdit = edit
                        progress(1)
                        continuation?.resume()
                        continuation = nil
                    },
                    save: { _ in nil },
                    copy: { _ in }
                )
            )
            defer { controller.close {} }

            await withCheckedContinuation { cont in
                continuation = cont
                controller.makeGIF()
            }
            #expect(capturedEdit?.gifOptions == GIFExportOptions(framesPerSecond: 20, scale: 1.0))
            #expect(capturedEdit?.isNone == true)
            #expect(!controller.hasUnkeptEdits)
        }
    }
}
