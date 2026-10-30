import CoreGraphics
import Foundation
import Testing
@testable import OMSStudio

/// How a Studio recording writes the pointer down, at the times and places its events carry, and how drags
/// place zooms.
struct StudioPointerTests {
    /// A recorder over 800 × 600 points whose bottom-left corner is at (100, 200) on screen.
    private func recorder() -> TelemetryRecorder {
        let recorder = TelemetryRecorder()
        recorder.begin(area: CGRect(x: 100, y: 200, width: 800, height: 600), pixelsPerPoint: 2)
        return recorder
    }

    /// The place `x`, `y` points from the recording's top-left corner, on screen.
    private func screen(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: 100 + x, y: 800 - y)
    }

    private func times(_ samples: [StudioTelemetry.Sample]) -> [Double] {
        samples.map(\.time)
    }

    @Test func aClickTakesItsEventsTimeAndPlaceAndItsRelease() {
        let recorder = recorder()
        recorder.click(.primary, number: 0, at: 5.25, location: screen(200, 100))
        recorder.release(number: 0, at: 5.4, location: screen(201, 101))
        let clicks = recorder.stop().clicks
        #expect(clicks == [.init(time: 5.25, x: 200, y: 100, button: .primary, releaseTime: 5.4, releaseX: 201, releaseY: 101)])
        // Released a point or two from where it was pressed: a click, not a drag.
        #expect(!clicks[0].isDrag)
    }

    @Test func eachReleaseEndsItsOwnButtonsPress() {
        let recorder = recorder()
        recorder.click(.primary, number: 0, at: 1, location: screen(100, 100))
        recorder.click(.secondary, number: 1, at: 1.1, location: screen(300, 300))
        recorder.release(number: 1, at: 1.2, location: screen(300, 300))
        // Released without a press, as when it was pressed before recording began: nothing to end.
        recorder.release(number: 2, at: 1.3, location: screen(10, 10))
        recorder.release(number: 0, at: 2, location: screen(400, 100))
        // Still held when recording stops: no release.
        recorder.click(.other, number: 2, at: 3, location: screen(50, 50))
        let clicks = recorder.stop().clicks
        #expect(clicks.count == 3)
        #expect(clicks[0].releaseTime == 2 && clicks[0].releaseX == 400 && clicks[0].releaseY == 100 && clicks[0].isDrag)
        #expect(clicks[1].releaseTime == 1.2 && !clicks[1].isDrag)
        #expect(clicks[2].button == .other && clicks[2].releaseTime == nil && clicks[2].releaseX == nil)
    }

    @Test func pointerEventsTakeTheirOwnTimesAndArrivingLateTakeTheirPlace() {
        // The pointer moves; the main thread is busy from 1.02 s to 1.3 s, when the timer reads the pointer
        // first and then the moves it held up arrive, each with its own time.
        let recorder = recorder()
        recorder.move(at: 1.0, location: screen(10, 10))
        recorder.sample(at: 1.02, location: screen(10, 10), cursor: 0)
        recorder.sample(at: 1.3, location: screen(40, 10), cursor: 0)
        recorder.move(at: 1.1, location: screen(20, 10))
        recorder.move(at: 1.2, location: screen(30, 10))
        recorder.move(at: 1.29, location: screen(40, 10))
        let samples = recorder.stop().samples
        // In time order, each the pointer's place when it was there: the timer's late reading of the last
        // place is left out.
        #expect(times(samples) == [1.0, 1.1, 1.2, 1.29], "\(samples)")
        #expect(samples.map(\.x) == [10, 20, 30, 40])
    }

    @Test func theTimerLeavesThePlaceToEventsButWritesTheCursorsLook() {
        let recorder = recorder()
        recorder.sample(at: 0, location: screen(10, 10), cursor: 0)
        recorder.move(at: 0.01, location: screen(12, 10))
        // The timer's reading after a move would stamp the place with its own, later time: left to the events.
        recorder.sample(at: 0.017, location: screen(13, 10), cursor: 0)
        recorder.move(at: 0.02, location: screen(14, 10))
        // The cursor changed look: the timer writes that down where the pointer is, and moves after carry it.
        recorder.sample(at: 0.033, location: screen(14, 10), cursor: 1)
        recorder.move(at: 0.04, location: screen(16, 10))
        let samples = recorder.stop().samples
        #expect(times(samples) == [0, 0.01, 0.02, 0.033, 0.04], "\(samples)")
        #expect(samples.map(\.cursor) == [0, 0, 0, 1, 1])
    }

    @Test func theTimerReadsThePointerWhereNoEventsCome() {
        // Over a window that hears no moves, the timer alone places the pointer, sixty times a second.
        let recorder = recorder()
        for tick in 0..<4 {
            recorder.sample(at: Double(tick) / 60, location: screen(10 + Double(tick), 10), cursor: 0)
        }
        #expect(recorder.stop().samples.map(\.x) == [10, 11, 12, 13])
    }

    @Test func aPointerAtRestWritesNothing() {
        let recorder = recorder()
        recorder.sample(at: 0, location: screen(10, 10), cursor: 0)
        recorder.move(at: 0.5, location: screen(10, 10))
        for tick in 1...30 {
            recorder.sample(at: Double(tick) / 60, location: screen(10, 10), cursor: 0)
        }
        recorder.move(at: 1, location: screen(11, 10))
        #expect(times(recorder.stop().samples) == [0, 1])
    }

    @Test func readingsAreOrderedAndThoseAtRestLeftOut() {
        let samples: [StudioTelemetry.Sample] = [
            .init(time: 2, x: 5, y: 5, cursor: 0),
            .init(time: 1, x: 1, y: 1, cursor: 0),
            .init(time: 1.5, x: 1, y: 1, cursor: 0),
            // Two at once: the one written down last stands.
            .init(time: 3, x: 6, y: 6, cursor: 0),
            .init(time: 3, x: 7, y: 7, cursor: 0),
            .init(time: 4, x: 7, y: 7, cursor: 1),
        ]
        let ordered = TelemetryRecorder.inOrder(samples)
        #expect(ordered == [
            .init(time: 1, x: 1, y: 1, cursor: 0), .init(time: 2, x: 5, y: 5, cursor: 0),
            .init(time: 3, x: 7, y: 7, cursor: 0), .init(time: 4, x: 7, y: 7, cursor: 1),
        ])
    }

    @Test func theTapsEventsAreTakenInAtTheirOwnTimesAndPlaces() {
        // What the tap heard while the main thread was busy, taken in at the next tick: moves, a drag with the
        // left button, and a press and release of a third button, each with the time and place it carries.
        func heard(_ type: CGEventType, _ time: Double, _ x: Double, _ y: Double, button: Int = 0) -> PointerTap.Event {
            .init(type: type, button: button, time: time, location: screen(x, y), arrived: 1.3)
        }
        let recorder = recorder()
        recorder.take([
            heard(.mouseMoved, 1.0, 10, 10),
            heard(.mouseMoved, 1.05, 20, 10),
            heard(.leftMouseDown, 1.1, 30, 10),
            heard(.leftMouseDragged, 1.15, 60, 12),
            heard(.leftMouseUp, 1.2, 90, 14),
            heard(.otherMouseDown, 1.25, 90, 14, button: 2),
            heard(.otherMouseUp, 1.28, 90, 14, button: 2),
        ])
        // The timer's tick after them leaves the place to them.
        recorder.sample(at: 1.3, location: screen(90, 14), cursor: 0)
        let telemetry = recorder.stop()
        #expect(times(telemetry.samples) == [1.0, 1.05, 1.1, 1.15, 1.2], "\(telemetry.samples)")
        #expect(telemetry.samples.map(\.x) == [10, 20, 30, 60, 90])
        #expect(telemetry.clicks == [
            .init(time: 1.1, x: 30, y: 10, button: .primary, releaseTime: 1.2, releaseX: 90, releaseY: 14),
            .init(time: 1.25, x: 90, y: 14, button: .other, releaseTime: 1.28, releaseX: 90, releaseY: 14),
        ])
        #expect(telemetry.clicks[0].isDrag && !telemetry.clicks[1].isDrag)
    }

    @Test func pressesOnOhMyShotsOwnWindowsAreNoClicks() {
        // The recording bar's Stop, pressed and released: the recording leaves the bar out, so it places the
        // pointer and nothing more, while a click elsewhere still counts.
        var stop = PointerTap.Event(type: .leftMouseDown, button: 0, time: 2.0, location: screen(400, 20), arrived: 2.01)
        stop.isOnOwnWindow = true
        var released = stop
        released.type = .leftMouseUp
        released.time = 2.1
        let recorder = recorder()
        recorder.take([
            .init(type: .leftMouseDown, button: 0, time: 1.0, location: screen(100, 100), arrived: 1.01),
            .init(type: .leftMouseUp, button: 0, time: 1.05, location: screen(100, 100), arrived: 1.06),
            stop, released,
        ])
        let telemetry = recorder.stop()
        #expect(telemetry.clicks.map(\.time) == [1.0])
        #expect(telemetry.samples.last.map { ($0.time, $0.x) } ?? (0, 0) == (2.0, 400))
    }

    @Test func clicksAreHandedOverInTimeOrder() {
        // The two monitors can deliver out of turn.
        let recorder = recorder()
        recorder.click(.primary, number: 0, at: 2, location: screen(10, 10))
        recorder.click(.secondary, number: 1, at: 1, location: screen(20, 20))
        recorder.release(number: 0, at: 2.1, location: screen(10, 10))
        let clicks = recorder.stop().clicks
        #expect(clicks.map(\.time) == [1, 2])
        // The release still found its own press.
        #expect(clicks[1].releaseTime == 2.1 && clicks[0].releaseTime == nil)
    }

    // MARK: Drags and zooms

    /// A pointer moving right at 200 pt/s from (100, 400), read 60 times a second, with `clicks`.
    private func moving(for seconds: Double, clicks: [StudioTelemetry.Click]) -> StudioTelemetry {
        let samples = stride(from: 0.0, through: seconds, by: 1.0 / 60).map {
            StudioTelemetry.Sample(time: $0, x: 100 + 200 * $0, y: 400, cursor: 0)
        }
        return StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 2, samples: samples, clicks: clicks)
    }

    /// A drag along the pointer's path from `start` to `end` seconds.
    private func drag(from start: Double, to end: Double) -> StudioTelemetry.Click {
        .init(time: start, x: 100 + 200 * start, y: 400, button: .primary, releaseTime: end, releaseX: 100 + 200 * end, releaseY: 400)
    }

    @Test func aDragIsItsPressItsReleaseAndThePointerBetween() {
        let events = AutoZoom.events(in: moving(for: 6, clicks: [drag(from: 2, to: 3)]))
        let expected = [2, 2.2, 2.4, 2.6, 2.8, 3]
        #expect(events.count == expected.count, "\(events)")
        #expect(zip(events.map(\.time), expected).allSatisfy { abs($0 - $1) < 1e-9 }, "\(events.map(\.time))")
        // Between, where the pointer was then, the last reading at or before (within a sixtieth of a second).
        #expect(zip(events.map(\.x), expected.map { 100 + 200 * $0 }).allSatisfy { $0 <= $1 + 1e-9 && $1 - $0 <= 200.0 / 60 + 1e-9 },"\(events.map(\.x))")
        #expect(events.first?.x == 500 && events.last?.x == 700)
        #expect(events.allSatisfy { !$0.isKey && $0.y == 400 })
    }

    @Test func clicksReleasedWhereTheyWerePressedZoomAsBefore() {
        // The same clicks as `StudioMotionTests` uses, with and without releases a point or two away.
        let cases: [[(Double, Double, Double)]] = [
            [(2, 500, 400), (3, 520, 420), (3.5, 540, 400), (9.2, 1200, 700), (9.5, 1210, 700)],
            [(3, 800, 100)],
            [(3, 800, 100), (3.4, 800, 100), (3.8, 800, 100), (4.2, 800, 100)],
            [(2, 300, 500), (2.2, 1000, 500), (2.4, 300, 500), (2.6, 1000, 500)],
            [(2, 800, 100), (2.2, 800, 100), (7.1, 800, 100), (7.3, 800, 100)],
        ]
        for clicks in cases {
            let without = moving(for: 10, clicks: clicks.map { .init(time: $0.0, x: $0.1, y: $0.2, button: .primary) })
            let with = moving(for: 10, clicks: clicks.map {
                .init(time: $0.0, x: $0.1, y: $0.2, button: .primary, releaseTime: $0.0 + 0.12, releaseX: $0.1 + 2, releaseY: $0.2 - 1)
            })
            // Each zoom has an identity of its own: the rest of it is the same.
            func placed(_ telemetry: StudioTelemetry) -> [[Double]] {
                AutoZoom.zooms(for: telemetry, duration: 10).map { [$0.start, $0.end, $0.scale, $0.isAutomatic ? 1 : 0] }
            }
            func events(_ telemetry: StudioTelemetry) -> [[Double]] {
                AutoZoom.events(in: telemetry).map { [$0.time, $0.x, $0.y, $0.isKey ? 1 : 0] }
            }
            #expect(placed(with) == placed(without), "\(clicks)")
            #expect(events(with) == events(without), "\(clicks)")
        }
    }

    @Test func aLoneDragPlacesAZoomFramingAllOfIt() {
        // A lone click places none, but a drag is two places at least: its press and its release.
        let short = AutoZoom.zooms(for: moving(for: 8, clicks: [drag(from: 3, to: 3.3)]), duration: 8)
        #expect(short.count == 1, "\(short)")
        #expect(abs(short[0].start - (3 - AutoZoom.leadIn)) < 1e-9 && abs(short[0].end - (3.3 + AutoZoom.hold)) < 1e-9)
        #expect(short[0].scale == AutoZoom.lightScale)
        // One held a second has enough places in it to count as busy, and zooms in as far as typing does.
        let long = AutoZoom.zooms(for: moving(for: 8, clicks: [drag(from: 3, to: 4)]), duration: 8)
        #expect(long.count == 1, "\(long)")
        #expect(abs(long[0].start - (3 - AutoZoom.leadIn)) < 1e-9 && abs(long[0].end - (4 + AutoZoom.hold)) < 1e-9)
        #expect(long[0].scale == AutoZoom.standardScale)
    }
}
