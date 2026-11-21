import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import OMSStudio

/// Stretches played faster or slower: the movie's clock against the recording's, across cuts and speeds, and the
/// movie made so. One at a time, as the export tests are.
@Suite(.serialized)
struct StudioSpeedTests {
    // MARK: The clock

    @Test func theRecordingIsLaidOutAcrossCutsAndSpeeds() {
        // 1–4 at 2×, 6–8 at half speed, 2–3 cut.
        let segments = StudioComposition.keptSegments(
            duration: 10, cuts: [2...3], speeds: [.init(start: 1, end: 4, rate: 2), .init(start: 6, end: 8, rate: 0.5)]
        )
        #expect(segments == [
            .init(movieStart: 0, sourceStart: 0, duration: 1, speed: 1),
            .init(movieStart: 1, sourceStart: 1, duration: 0.5, speed: 2),
            .init(movieStart: 1.5, sourceStart: 3, duration: 0.5, speed: 2),
            .init(movieStart: 2, sourceStart: 4, duration: 2, speed: 1),
            .init(movieStart: 4, sourceStart: 6, duration: 4, speed: 0.5),
            .init(movieStart: 8, sourceStart: 8, duration: 2, speed: 1),
        ])
    }

    @Test func theMoviesTimeAndTheRecordingsGoThroughTheSamePartsAtTheirSpeeds() {
        let segments = StudioComposition.keptSegments(
            duration: 10, cuts: [2...3], speeds: [.init(start: 1, end: 4, rate: 2), .init(start: 6, end: 8, rate: 0.5)]
        )
        let pairs: [(movie: Double, recording: Double)] = [
            (0, 0), (1, 1), (1.25, 1.5), (1.5, 3), (1.75, 3.5), (2, 4), (4, 6), (6, 7), (8, 8), (9, 9), (10, 10),
        ]
        for (movie, recording) in pairs {
            #expect(abs(StudioComposition.sourceTime(movie, in: segments) - recording) < 1e-9, "movie \(movie)")
            #expect(abs(StudioComposition.movieTime(forSource: recording, in: segments) - movie) < 1e-9, "recording \(recording)")
        }
        // Inside the cut, where it was left out, which shows the cut's end.
        #expect(abs(StudioComposition.movieTime(forSource: 2.5, in: segments) - 1.5) < 1e-9)
        // Without speeds the clock is the one the cuts alone make.
        #expect(StudioComposition.keptSegments(duration: 10, cuts: [2...3]) == StudioComposition.keptSegments(duration: 10, cuts: [2...3], speeds: []))
    }

    @Test func speedsAreKeptInsideTheRecordingInOrderAndApart() {
        let speeds = StudioProject.normalizedSpeeds([
            .init(start: 5, end: 7, rate: 3),
            .init(start: -1, end: 2, rate: 2),
            .init(start: 1, end: 3, rate: 4),
            .init(start: 8, end: 12, rate: 10),
            .init(start: 3, end: 4, rate: 1),
            .init(start: 9.5, end: 9.5, rate: 2),
        ], duration: 10)
        // The first keeps where two overlap; as recorded is no speed; past the offered speeds is the fastest.
        #expect(speeds == [
            .init(start: 0, end: 2, rate: 2), .init(start: 2, end: 3, rate: 4), .init(start: 5, end: 7, rate: 3), .init(start: 8, end: 10, rate: 4),
        ])
    }

    @Test func theCameraKeepsInStepWithTheSpeed() {
        // 1–3 of the recording at 2×; the camera began at 0.5 s.
        let segments = StudioComposition.keptSegments(duration: 4, cuts: [], speeds: [.init(start: 1, end: 3, rate: 2)])
        let ranges = StudioComposition.cameraRanges(segments: segments, cameraStart: 0.5, cameraDuration: 10)
        #expect(ranges.count == 3)
        // The camera's 0.5–2.5 is the movie's 1–2, played at 2×.
        #expect(abs(ranges[1].cameraStart - 0.5) < 1e-9 && abs(ranges[1].movieStart - 1) < 1e-9)
        #expect(abs(ranges[1].duration - 2) < 1e-9 && ranges[1].speed == 2)
        #expect(abs(ranges[2].movieStart - 2) < 1e-9 && ranges[2].speed == 1)
    }

    // MARK: Editing

    @MainActor @Test func aStretchChosenOnTheClipPlaysAtTheSpeedSetAndTakesOverTheSpeedsItMeets() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioSpeedTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = StudioDocument(
            source: folder.appending(path: "none.mp4"), telemetry: StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2),
            project: StudioProject(speeds: [.init(start: 1, end: 5, rate: 3)]), duration: 10, recordingSize: CGSize(width: 320, height: 200),
            folder: folder, hasBeenExported: true, background: { _, _ in nil }
        )
        #expect(!document.canSetSpeed)
        document.selection = .range(2...3)
        #expect(document.canSetSpeed && document.chosenRate == 1)
        document.setSpeed(2)
        #expect(document.project.speeds == [.init(start: 1, end: 2, rate: 3), .init(start: 2, end: 3, rate: 2), .init(start: 3, end: 5, rate: 3)])
        #expect(document.selection == .speed(2) && document.chosenRate == 2)
        // The movie is shorter by what the speeds take out of it: 10 s less 1 s at 2× and 3 s at 3×.
        #expect(abs(document.movieTime(10) - (10 - 0.5 - 2)) < 1e-9)
        document.setSpeed(0.5)
        #expect(document.project.speeds[1] == .init(start: 2, end: 3, rate: 0.5))
        // As recorded again, and Delete on the others.
        document.setSpeed(1)
        #expect(document.project.speeds == [.init(start: 1, end: 2, rate: 3), .init(start: 3, end: 5, rate: 3)] && document.selection == .none)
        document.selection = .speed(3)
        document.deleteSelection()
        #expect(document.project.speeds == [.init(start: 1, end: 2, rate: 3)])
    }

    @MainActor @Test func aSpeedLeftShortByAnotherStillChangesAndGoes() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OMSStudioSpeedTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = StudioDocument(
            source: folder.appending(path: "none.mp4"), telemetry: StudioTelemetry(width: 160, height: 100, pixelsPerPoint: 2),
            project: StudioProject(), duration: 10, recordingSize: CGSize(width: 320, height: 200),
            folder: folder, hasBeenExported: true, background: { _, _ in nil }
        )
        document.selection = .range(1...3)
        document.setSpeed(2)
        document.selection = .range(1.03...2)
        document.setSpeed(3)
        // Three hundredths of a second left of the first, chosen on the timeline: a new stretch that short would be refused.
        #expect(document.project.speeds.first == .init(start: 1, end: 1.03, rate: 2))
        document.selection = .range(4...4.02)
        document.setSpeed(2)
        #expect(document.project.speeds.count == 3)
        document.selection = .speed(1)
        document.setSpeed(0.5)
        #expect(document.project.speeds.first == .init(start: 1, end: 1.03, rate: 0.5))
        document.setSpeed(1)
        #expect(document.project.speeds.map(\.start) == [1.03, 2] && document.selection == .none)
    }

    @Test func aCutSaysHowMuchShorterTheMovieIsAtTheSpeedItsStretchPlays() {
        let project = StudioProject(speeds: [.init(start: 1, end: 5, rate: 4)])
        #expect(abs(project.playedLength(of: 2...4) - 0.5) < 1e-9)
        #expect(abs(project.playedLength(of: 0...2) - 1.25) < 1e-9)
        #expect(abs(project.playedLength(of: 6...8) - 2) < 1e-9)
    }

    @Test func aSpeedBandDrawnWiderThanItsStretchIsHitWhereItIsDrawn() {
        // 240 s over 1000 pt: half a second is about 2 pt, drawn 6 pt wide.
        let viewport = StudioTimelineViewport(duration: 240)
        let speed = StudioProject.Speed(start: 100, end: 100.5, rate: 2)
        let start = 16 + 1000 * 100 / 240.0
        let foot = 64 + 40 - 8.0
        #expect(StudioTimeline.laneHit(at: CGPoint(x: start + 3, y: foot), width: 1032, viewport: viewport, zooms: [], cuts: [], speeds: [speed]) == .speed(100))
        #expect(StudioTimeline.laneHit(at: CGPoint(x: start + 8, y: foot), width: 1032, viewport: viewport, zooms: [], cuts: [], speeds: [speed]) == .clipRange)
        // A cut over it keeps its place on top.
        #expect(StudioTimeline.laneHit(
            at: CGPoint(x: start + 3, y: foot), width: 1032, viewport: viewport, zooms: [], cuts: [99...101], speeds: [speed]
        ) == .cut(99))
    }

    @Test func aProjectFromBeforeSpeedsPlaysAsRecorded() throws {
        let old = try JSONDecoder().decode(StudioProject.self, from: Data(#"{"padding": 0.1}"#.utf8))
        #expect(old.speeds.isEmpty)
        let project = StudioProject(speeds: [.init(start: 1, end: 2, rate: 1.5)])
        #expect(try JSONDecoder().decode(StudioProject.self, from: JSONEncoder().encode(project)) == project)
    }

    // MARK: The movie

    @Test func theMovieAndEachOfItsSoundsPlayAtTheSpeedSet() async throws {
        let movie = try await StudioSoundTests.movie(seconds: 2, sounds: [(2, 0.2), (1, 0.2)])
        let camera = try await StudioSoundTests.movie(seconds: 2, sounds: [])
        let folder = try StudioSoundTests.folder()
        defer { [movie, camera, folder].forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try await StudioSound.keep(from: movie, in: folder)
        let sounds = StudioSound.files(in: folder).map { StudioComposition.SoundSource(sound: $0.sound, asset: AVURLAsset(url: $0.url)) }

        // The first second at 2×, a quarter second of the next cut.
        let speeds = [StudioProject.Speed(start: 0, end: 1, rate: 2)]
        let composition = try await StudioComposition.make(
            source: AVURLAsset(url: movie), renderer: StudioSoundTests.renderer(StudioProject(), duration: 2), cuts: [1.5...1.75], speeds: speeds,
            camera: .init(asset: AVURLAsset(url: camera), start: 0), sounds: sounds
        )
        #expect(abs(composition.duration - 1.25) < 1e-9)
        for track in try await composition.asset.loadTracks(withMediaType: .video) + composition.asset.loadTracks(withMediaType: .audio) {
            #expect(abs(try await track.load(.timeRange).end.seconds - 1.25) < 0.02, "track \(track.trackID)")
        }
    }

    @Test func theExportFollowsTheNewClockAndKeepsThePitch() async throws {
        // A gray stepping up each second, and a 440 Hz tone as the system's sound.
        let movie = try await StudioSoundTests.movie(seconds: 2, sounds: [(2, 0.3)])
        let folder = try StudioSoundTests.folder()
        var made: [URL] = []
        defer { ([movie, folder] + made).forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try await StudioSound.keep(from: movie, in: folder)
        let sounds = StudioSound.files(in: folder).map { StudioComposition.SoundSource(sound: $0.sound, asset: AVURLAsset(url: $0.url)) }
        func export(_ speeds: [StudioProject.Speed]) async throws -> URL {
            var project = StudioProject(background: .color(red: 1, green: 1, blue: 1), padding: 0)
            project.speeds = speeds
            let composition = try await StudioComposition.make(
                source: AVURLAsset(url: movie), renderer: StudioSoundTests.renderer(project, duration: 2), cuts: [], speeds: speeds, sounds: sounds
            )
            let url = try await StudioSoundTests.exported(composition)
            made.append(url)
            return url
        }
        func gray(of url: URL, at seconds: Double) async throws -> Int {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try #require(CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
            return Int(pixel[1])
        }

        let asRecorded = try await export([])
        let twice = try await export([.init(start: 0, end: 2, rate: 2)])
        #expect(abs(try await AVURLAsset(url: twice).load(.duration).seconds - 1) < 0.05)
        // 0.6 s into the movie is 1.2 s into the recording at 2×, past the step up; as recorded, before it.
        let recordedGray = try await gray(of: asRecorded, at: 0.6), twiceGray = try await gray(of: twice, at: 0.6)
        #expect(twiceGray > recordedGray + 20, "\(twiceGray) against \(recordedGray)")

        // The tone stays at 440 Hz, its pitch, as the movie plays it in half the time.
        let samples = try #require(try await StudioSoundTests.samples(of: twice))
        #expect(abs(Double(samples.count) / 48_000 - 1) < 0.1)
        let middle = samples[samples.count / 5 ..< samples.count * 4 / 5]
        let crossings = zip(middle, middle.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
        let frequency = Double(crossings) / 2 / (Double(middle.count) / 48_000)
        #expect(abs(frequency - 440) < 30, "\(frequency) Hz")
    }

    @Test func thePitchHoldsAtHalfAndFourTimesTheSpeedOnEitherSideOfWhereTheyMeet() async throws {
        let movie = try await StudioSoundTests.movie(seconds: 2, sounds: [(2, 0.3)])
        let folder = try StudioSoundTests.folder()
        var made: [URL] = []
        defer { ([movie, folder] + made).forEach { try? FileManager.default.removeItem(at: $0) } }
        _ = try await StudioSound.keep(from: movie, in: folder)
        let sounds = StudioSound.files(in: folder).map { StudioComposition.SoundSource(sound: $0.sound, asset: AVURLAsset(url: $0.url)) }
        // The first second at half speed, two seconds of the movie; the next at 4×, a quarter second of it.
        let speeds = [StudioProject.Speed(start: 0, end: 1, rate: 0.5), StudioProject.Speed(start: 1, end: 2, rate: 4)]
        var project = StudioProject(background: .color(red: 1, green: 1, blue: 1), padding: 0)
        project.speeds = speeds
        let composition = try await StudioComposition.make(
            source: AVURLAsset(url: movie), renderer: StudioSoundTests.renderer(project, duration: 2), cuts: [], speeds: speeds, sounds: sounds
        )
        let url = try await StudioSoundTests.exported(composition)
        made.append(url)

        let samples = try #require(try await StudioSoundTests.samples(of: url))
        try #require(samples.count > Int(2.2 * 48_000), "\(samples.count) samples")
        func frequency(from start: Double, to end: Double) -> Double {
            let part = samples[Int(start * 48_000) ..< Int(end * 48_000)]
            let crossings = zip(part, part.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
            return Double(crossings) / 2 / (Double(part.count) / 48_000)
        }
        // Away from where the speeds meet, where the two blend.
        let slow = frequency(from: 0.3, to: 1.7), fast = frequency(from: 2.06, to: 2.19)
        #expect(abs(slow - 440) < 30, "\(slow) Hz at 0.5×")
        #expect(abs(fast - 440) < 30, "\(fast) Hz at 4×")
    }
}
