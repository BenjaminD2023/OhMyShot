import CoreImage
import Foundation
import Testing
@testable import OMSStudio

struct StudioAlgorithmRegressionTests {
    private func moving(speed: Double, starts: Double = 0, keys: [StudioTelemetry.Key] = []) -> StudioTelemetry {
        StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 1, samples: (0...360).map {
            let time = Double($0) / 60
            return .init(time: time, x: 400 + speed * max(0, time - starts), y: 400, cursor: 0)
        }, keys: keys)
    }

    @Test func slowMovementRemainsVisibleAtEveryTrackRate() {
        for rate in [60.0, 120, 240] {
            for speed in [20.0, 40, 80] {
                let track = StudioTrack(telemetry: moving(speed: speed), project: StudioProject(), duration: 6, rate: rate)
                #expect(track.frame(at: 5).cursorOpacity == 1, "speed \(speed), rate \(rate)")
            }
        }
    }

    @Test func slowMovementAfterTypingRestoresTheCursor() {
        let telemetry = moving(speed: 20, starts: 2, keys: [.unrecorded(time: 1, isRepeat: false)])
        let track = StudioTrack(telemetry: telemetry, project: StudioProject(), duration: 6)
        #expect(track.frame(at: 1.5).cursorOpacity == 0)
        #expect(track.frame(at: 2.3).cursorOpacity == 1)
    }

    @Test func subPointJitterStillCountsAsRest() {
        let telemetry = StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 1, samples: (0...240).map {
            .init(time: Double($0) / 60, x: 400 + ($0.isMultiple(of: 2) ? 0.1 : -0.1), y: 400, cursor: 0)
        })
        let track = StudioTrack(telemetry: telemetry, project: StudioProject(), duration: 4)
        #expect(track.frame(at: 3).cursorOpacity == 0)
    }

    @Test func actualClickPositionsAnchorOffGridAndMultipleClicksWithinOneFrame() {
        let clicks: [StudioTelemetry.Click] = [
            .init(time: 0.997, x: 700, y: 600, button: .primary),
            .init(time: 1.001, x: 750, y: 650, button: .primary),
            .init(time: 1.004, x: 760, y: 640, button: .primary),
        ]
        let telemetry = StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 1, samples: [
            .init(time: 0, x: 100, y: 100, cursor: 0), .init(time: 1.1, x: 800, y: 700, cursor: 0),
        ], clicks: clicks)
        for smoothing in [0.0, 1] {
            var project = StudioProject()
            project.cursor.smoothing = smoothing
            let track = StudioTrack(telemetry: telemetry, project: project, duration: 2)
            for click in clicks.reversed() {
                let frame = track.frame(at: click.time)
                #expect(abs(frame.cursorX - click.x) < 1e-8)
                #expect(abs(frame.cursorY - click.y) < 1e-8)
                for time in [click.time - 1e-8, click.time + 1e-8] {
                    let near = track.frame(at: time)
                    #expect(abs(near.cursorX - click.x) < 0.01)
                    #expect(abs(near.cursorY - click.y) < 0.01)
                }
            }
        }
    }

    @Test func aClickWinsOverASimultaneousPointerSample() {
        let telemetry = StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 1, samples: [
            .init(time: 0, x: 100, y: 100, cursor: 0), .init(time: 1, x: 200, y: 200, cursor: 2),
        ], clicks: [.init(time: 1, x: 600, y: 500, button: .primary)])
        let track = StudioTrack(telemetry: telemetry, project: StudioProject(), duration: 2)
        #expect(track.frame(at: 1).cursorX == 600)
        #expect(track.frame(at: 1).cursorY == 500)
        #expect(track.frame(at: 1).cursor == 2)
    }

    @Test func activeZoomsPreserveOverlappingZoomSemantics() {
        let project = StudioProject(zooms: [
            .init(start: 1, end: 4, scale: 2, isAutomatic: false),
            .init(start: 0, end: 2, scale: 1.4, isAutomatic: false),
            .init(start: 1.3, end: 1.8, scale: 2.5, isAutomatic: false),
            .init(start: 4, end: 5, scale: 1.8, isAutomatic: false),
        ])
        let track = StudioTrack(telemetry: moving(speed: 200), project: project, duration: 6)
        for (index, frame) in track.frames.enumerated() {
            #expect(abs(frame.zoom - StudioTrack.zoom(at: Double(index) / track.rate, zooms: project.zooms)) < 1e-10)
        }
    }

    @Test func asynchronousAndSynchronousTracksAgree() async throws {
        let telemetry = moving(speed: 40)
        let expected = StudioTrack(telemetry: telemetry, project: StudioProject(), duration: 6)
        let actual = try await StudioTrack.make(telemetry: telemetry, project: StudioProject(), duration: 6)
        #expect(expected.frames == actual.frames)
    }

    @Test func trackConstructionCooperativelyChecksCancellation() {
        var checks = 0
        #expect(throws: CancellationError.self) {
            _ = try StudioTrack(telemetry: moving(speed: 40), project: StudioProject(), duration: 3600, rate: 120) {
                checks += 1
                if checks == 3 { throw CancellationError() }
            }
        }
        #expect(checks == 3)
    }

    @Test func aCancelledBackgroundTrackDoesNotReturnPartialFrames() async {
        let telemetry = moving(speed: 40)
        let task = Task { try await StudioTrack.make(telemetry: telemetry, project: StudioProject(), duration: 3600) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("A cancelled track unexpectedly completed")
        } catch {
            #expect(error is CancellationError)
        }
    }

    private func clicks(_ events: [(Double, Double, Double)]) -> StudioTelemetry {
        StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 1, clicks: events.map {
            .init(time: $0.0, x: $0.1, y: $0.2, button: .primary)
        })
    }

    @Test func distantActivityKeepsTwoLocalZoomsInsteadOfDiscardingTheWholeRun() {
        let telemetry = clicks([(2, 100, 100), (2.2, 120, 100), (2.4, 1450, 900), (2.6, 1470, 900)])
        let zooms = AutoZoom.zooms(for: telemetry, duration: 8)
        #expect(zooms.count == 2)
        #expect(zooms.allSatisfy { $0.scale == AutoZoom.lightScale })
        #expect(zooms[0].end <= zooms[1].start)
        #expect(zooms[0].end >= 2.2 && zooms[1].start <= 2.4)
    }

    @Test func adjacentGroupsOnlyMergeAtAScaleThatFitsBoth() {
        let separated = clicks([(2, 100, 100), (2.2, 120, 100), (5, 1450, 900), (5.2, 1470, 900)])
        #expect(AutoZoom.zooms(for: separated, duration: 8).count == 2)
        let nearby = clicks([(2, 300, 500), (2.2, 320, 500), (5, 1300, 500), (5.2, 1320, 500)])
        let merged = AutoZoom.zooms(for: nearby, duration: 8)
        #expect(merged.count == 1)
        #expect(merged.first?.scale == 1.3)
    }

    @Test func isolatedDistantClicksAndEventsOutsideTheMovieDoNotCreateZooms() {
        #expect(AutoZoom.zooms(for: clicks([(2, 100, 100), (2.2, 1500, 900)]), duration: 8).isEmpty)
        #expect(AutoZoom.zooms(for: clicks([(-1, 100, 100), (-0.8, 100, 100), (9, 100, 100), (9.2, 100, 100)]), duration: 8).isEmpty)
    }

    private func captionRenderer(keys: [StudioTelemetry.Key]) -> StudioRenderer {
        StudioRenderer(telemetry: StudioTelemetry(width: 800, height: 500, pixelsPerPoint: 1, keys: keys), project: StudioProject(), duration: 10,
                       recordingSize: CGSize(width: 800, height: 500), background: nil)
    }

    @Test func continuousTypingOnlyFadesAtTheEndsOfTheWholeRun() throws {
        for interval in [0.08, 0.12, 0.2] {
            let keys = (0..<8).map { StudioTelemetry.Key(time: 1 + Double($0) * interval, keyCode: 0, modifiers: 0, characters: "a", keyCharacters: "a", isRepeat: false) }
            let renderer = captionRenderer(keys: keys)
            for key in keys.dropFirst(2) {
                for time in [key.time - 0.001, key.time, key.time + 0.001] {
                    let index = try #require(renderer.captionIndex(at: time))
                    #expect(renderer.captionOpacity(at: time, index: index) == 1)
                }
            }
            #expect(renderer.captionOpacity(at: 1.06, index: 0) > 0.49)
            #expect(renderer.captionOpacity(at: 1.06, index: 0) < 0.51)
            let last = try #require(renderer.captions.last)
            #expect(renderer.captionOpacity(at: last.end - 0.06, index: renderer.captions.count - 1) < 0.51)
        }
    }

    @Test func indexedEventsAgreeWithLinearQueriesDuringOutOfOrderSeeks() {
        let events = (0..<100).map { (Double($0) * 0.1, 100.0, 100.0) }
        var telemetry = clicks(events)
        telemetry.keys = (0..<20).map { .init(time: Double($0) * 0.3, keyCode: 0, modifiers: 0, characters: "a", keyCharacters: "a", isRepeat: false) }
        let renderer = StudioRenderer(telemetry: telemetry, project: StudioProject(), duration: 12, recordingSize: CGSize(width: 1600, height: 1000), background: nil)
        let times = [0.0, 0.4, 0.5, 10, 3, 0, 0.3, 1.1, 9.9, 0.001, 8, -1, 20]
        for time in times {
            let expected = telemetry.clicks.filter { $0.time <= time && time - $0.time < renderer.project.cursor.clickEffect.lifetime }
            #expect(Array(renderer.activeClicks(at: time)) == expected)
            let index = renderer.captions.lastIndex { $0.start <= time && time < $0.end }
            #expect(renderer.captionIndex(at: time) == index)
        }
    }

    @Test func captionPicturesAreBoundedAndCanBeRecreatedWhenSeekingBack() {
        let keys = (0..<100).map { StudioTelemetry.Key(time: Double($0) * 2, keyCode: 0, modifiers: 0, characters: "word\($0)", keyCharacters: "a", isRepeat: false) }
        let renderer = captionRenderer(keys: keys)
        let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 500))
        for key in keys { _ = renderer.image(source: source, at: key.time + 0.2) }
        #expect(renderer.cachedCaptionCount == StudioRenderer.captionCacheLimit)
        let first = renderer.image(source: source, at: 0.2)
        #expect(first.extent.width > 0)
        #expect(renderer.cachedCaptionCount == StudioRenderer.captionCacheLimit)
    }

    @Test func aPreparedTrackIsReusedForDifferentRenderSizes() {
        let telemetry = moving(speed: 40)
        let track = StudioTrack(telemetry: telemetry, project: StudioProject(), duration: 6)
        for size in [640.0, 1920] {
            let renderer = StudioRenderer(telemetry: telemetry, project: StudioProject(), duration: 6,
                                          recordingSize: CGSize(width: 1600, height: 1000), background: nil, largestSide: size, preparedTrack: track)
            #expect(renderer.track.frames == track.frames)
        }
    }
}
