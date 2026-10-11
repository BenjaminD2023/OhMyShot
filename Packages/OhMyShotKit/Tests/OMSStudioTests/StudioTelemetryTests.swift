import Foundation
import Testing
@testable import OMSStudio

struct StudioTelemetryTests {
    private func telemetry() -> StudioTelemetry {
        StudioTelemetry(
            width: 800, height: 500, pixelsPerPoint: 2,
            samples: [
                .init(time: 99.0, x: 10, y: 10, cursor: 0),
                .init(time: 100.5, x: 20, y: 30, cursor: 0),
                .init(time: 101.0, x: 25, y: 35, cursor: 1),
                .init(time: 102.0, x: 40, y: 50, cursor: 1),
            ],
            clicks: [
                .init(time: 99.5, x: 10, y: 10, button: .primary),
                .init(time: 100.6, x: 20, y: 30, button: .primary),
                .init(time: 101.2, x: 25, y: 35, button: .secondary),
                .init(time: 101.9, x: 40, y: 50, button: .primary),
            ],
            keys: [.init(time: 101.8, keyCode: 4, modifiers: 0, characters: "h", keyCharacters: "h", isRepeat: false)]
        )
    }

    @Test func timesMoveOntoTheMovieWithPausesCutOut() {
        // The movie starts at 100 s on the host clock; recording was paused from 100.8 to 101.5 s.
        let moved = telemetry().retimed(start: 100, pauses: [100.8...101.5])
        // The pointer's place before the start begins the movie; what came during the pause is left out.
        #expect(zip(moved.samples.map(\.time), [0, 0.5, 1.3]).allSatisfy { abs($0 - $1) < 1e-9 } && moved.samples.count == 3, "\(moved.samples.map(\.time))")
        #expect(moved.samples.first.map { ($0.x, $0.y) } ?? (0, 0) == (10, 10))
        #expect(moved.clicks.count == 2)
        #expect(abs(moved.clicks[0].time - 0.6) < 1e-9)
        #expect(abs(moved.clicks[1].time - 1.2) < 1e-9)
        #expect(moved.keys.count == 1)
        #expect(abs((moved.keys.first?.time ?? 0) - 1.1) < 1e-9)
    }

    @Test func aPointerAtRestBeforeTheStartStillHasAPlace() {
        let still = StudioTelemetry(width: 100, height: 100, pixelsPerPoint: 1, samples: [.init(time: 5, x: 1, y: 2, cursor: 0)])
        let moved = still.retimed(start: 10, pauses: [])
        #expect(moved.samples == [.init(time: 0, x: 1, y: 2, cursor: 0)])
    }

    @Test func itIsKeptAsJSON() throws {
        let original = telemetry()
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(StudioTelemetry.self, from: data) == original)
    }

    @Test func theCamerasTimesSpanThePauses() {
        // The camera's movie began 0.2 s before the screen's; it filled what was recorded from inside the
        // pause to the end, and once before the movie began.
        var raw = telemetry()
        raw.camera = .init(start: 99.8, fills: [99.0...99.5, 101.0...103.0], bubble: StudioProject.Camera())
        let moved = raw.retimed(start: 100, pauses: [100.8...101.5])
        let camera = try! #require(moved.camera)
        #expect(abs(camera.start + 0.2) < 1e-9)
        // A time within the pause takes the movie's time where the pause was cut out; nothing before 0.
        #expect(camera.fills.count == 1)
        #expect(abs(camera.fills[0].lowerBound - 0.8) < 1e-9 && abs(camera.fills[0].upperBound - 2.3) < 1e-9, "\(camera.fills)")
    }

    @Test func theCamerasPartsFollowTheKeptOnes() {
        // Kept: 0–2 and 2.5–4 of the recording; the camera began at 1 s and lasts 2.5 s.
        let segments = StudioComposition.keptSegments(duration: 4, cuts: [2...2.5])
        let ranges = StudioComposition.cameraRanges(segments: segments, cameraStart: 1, cameraDuration: 2.5)
        #expect(ranges.count == 2)
        // 1–2 of the recording is the camera's 0–1, at the movie's 1–2; 2.5–3.5 is its 1.5–2.5, at 2–3.
        #expect(abs(ranges[0].cameraStart) < 1e-9 && abs(ranges[0].movieStart - 1) < 1e-9 && abs(ranges[0].duration - 1) < 1e-9)
        #expect(abs(ranges[1].cameraStart - 1.5) < 1e-9 && abs(ranges[1].movieStart - 2) < 1e-9 && abs(ranges[1].duration - 1) < 1e-9)
        // A camera that began first starts inside its own movie.
        let early = StudioComposition.cameraRanges(segments: segments, cameraStart: -0.5, cameraDuration: 10)
        #expect(abs(early[0].cameraStart - 0.5) < 1e-9 && early[0].movieStart == 0)
    }
}
