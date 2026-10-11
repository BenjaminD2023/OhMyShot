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
}
