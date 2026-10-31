import Foundation
import Testing
@testable import OMSStudio

/// Where the camera looks while zoomed: what it frames, that it keeps the cursor and the clicks in view, and
/// that it zooms about one point.
struct StudioFramingTests {
    private let width = 1600.0, height = 1000.0

    /// A pointer read 60 times a second for `seconds`, moving straight from one of `stops` (time, x, y) to the
    /// next and resting at each, and clicking at `clicks` (time, x, y).
    private func path(_ stops: [(Double, Double, Double)], seconds: Double, clicks: [(Double, Double, Double)] = []) -> StudioTelemetry {
        let samples = (0...Int(seconds * 60)).map { reading -> StudioTelemetry.Sample in
            let time = Double(reading) / 60
            guard let next = stops.firstIndex(where: { $0.0 > time }) else { return .init(time: time, x: stops.last!.1, y: stops.last!.2, cursor: 0) }
            guard next > 0 else { return .init(time: time, x: stops[0].1, y: stops[0].2, cursor: 0) }
            let a = stops[next - 1], b = stops[next]
            let t = (time - a.0) / (b.0 - a.0)
            return .init(time: time, x: a.1 + (b.1 - a.1) * t, y: a.2 + (b.2 - a.2) * t, cursor: 0)
        }
        return StudioTelemetry(
            width: width, height: height, pixelsPerPoint: 2, samples: samples,
            clicks: clicks.map { .init(time: $0.0, x: $0.1, y: $0.2, button: .primary) }
        )
    }

    private func track(_ telemetry: StudioTelemetry, zooms: [StudioProject.Zoom], duration: Double) -> StudioTrack {
        var project = StudioProject(zooms: zooms)
        project.cursor.hidesWhenIdle = false
        return StudioTrack(telemetry: telemetry, project: project, duration: duration)
    }

    /// How far inside what the camera shows in `frame` a point is, as a share of what it shows across or down,
    /// whichever is less: 0.5 in the middle, negative outside.
    private func inset(_ x: Double, _ y: Double, in frame: StudioTrack.Frame) -> Double {
        let halfWidth = width / frame.zoom / 2, halfHeight = height / frame.zoom / 2
        return min((halfWidth - abs(x - frame.centerX)) / (2 * halfWidth), (halfHeight - abs(y - frame.centerY)) / (2 * halfHeight))
    }

    private func isInsideTheRecording(_ frame: StudioTrack.Frame) -> Bool {
        let halfWidth = width / frame.zoom / 2, halfHeight = height / frame.zoom / 2
        return frame.centerX >= halfWidth - 1e-6 && frame.centerX <= width - halfWidth + 1e-6
            && frame.centerY >= halfHeight - 1e-6 && frame.centerY <= height - halfHeight + 1e-6
    }

    @Test func theCursorStaysInViewWhileZoomedHoweverFastItMoves() {
        // Zoomed in twice from 1 s to 6 s, the pointer rests, then crosses most of the recording at 2 s.
        for speed in [500.0, 1000, 2000] {
            let distance = hypot(900.0, 450)
            let telemetry = path([(2, 400, 300), (2 + distance / speed, 1300, 750)], seconds: 7)
            let track = track(telemetry, zooms: [.init(start: 1, end: 6, scale: 2, isAutomatic: false)], duration: 7)
            let held = track.frames.filter { abs($0.zoom - 2) < 1e-9 }
            #expect(held.count > 400)
            let worst = held.map { inset($0.cursorX, $0.cursorY, in: $0) }.min() ?? -1
            #expect(worst >= 0.05, "at \(speed) pt/s the cursor came to \(worst) of the view from its edge")
            #expect(track.frames.allSatisfy(isInsideTheRecording))
        }
    }

    @Test func everyClickLandsWellInsideTheView() {
        // The pointer rushes from the top left to a button and clicks it twice, then to another a little way off.
        let telemetry = path(
            [(2.2, 300, 250), (2.9, 1200, 700), (3.9, 1200, 700), (4.3, 1000, 640), (4.7, 1000, 640), (4.75, 1005, 650)], seconds: 8,
            clicks: [(3, 1200, 700), (3.4, 1200, 700), (4.4, 1000, 640), (4.8, 1005, 650)]
        )
        let zooms = AutoZoom.zooms(for: telemetry, duration: 8)
        #expect(zooms.count == 1, "\(zooms)")
        let track = track(telemetry, zooms: zooms, duration: 8)
        for click in telemetry.clicks {
            let frame = track.frame(at: click.time)
            #expect(inset(click.x, click.y, in: frame) >= 0.1, "the click at \(click.time) s came to \(inset(click.x, click.y, in: frame))")
        }
    }

    @Test func theCameraHoldsStillOnceZoomedWhenWhatHappensFitsTheView() {
        // The pointer arrives from far off as the zoom begins, then clicks three times close together, wandering a
        // little between them.
        let telemetry = path(
            [(2.3, 150, 150), (2.9, 700, 450), (3.1, 700, 450), (3.4, 760, 480), (3.6, 760, 480), (3.9, 720, 430)], seconds: 8,
            clicks: [(3, 700, 450), (3.5, 760, 480), (4, 720, 430)]
        )
        let zooms = AutoZoom.zooms(for: telemetry, duration: 8)
        #expect(zooms.count == 1, "\(zooms)")
        let zoom = zooms[0]
        let track = track(telemetry, zooms: zooms, duration: 8)
        let length = StudioTrack.transitionLength(zoom)
        let held = track.frames.indices
            .filter { Double($0) / track.rate >= zoom.start + length && Double($0) / track.rate <= zoom.end - length }
            .map { track.frames[$0] }
        #expect(held.count > 200)
        let xs = held.map(\.centerX), ys = held.map(\.centerY)
        #expect(xs.max()! - xs.min()! < 0.5, "the camera panned \(xs.max()! - xs.min()!) pt across while zoomed")
        #expect(ys.max()! - ys.min()! < 0.5, "the camera panned \(ys.max()! - ys.min()!) pt down while zoomed")
    }

    @Test func betweenShotsTheCameraMovesOnceAndArrivesBeforeTheClick() {
        // Zoomed in twice by hand, two clicks at the top left, then two at the bottom right, too far apart to show
        // together: the camera holds on each pair and moves between them once, there before the second pair.
        let telemetry = path(
            [(3.2, 400, 300), (3.7, 1200, 700)], seconds: 10,
            clicks: [(2, 400, 300), (2.3, 400, 300), (4, 1200, 700), (4.3, 1200, 700)]
        )
        let track = track(telemetry, zooms: [.init(start: 1, end: 9, scale: 2, isAutomatic: false)], duration: 10)
        for click in telemetry.clicks {
            let frame = track.frame(at: click.time)
            #expect(inset(click.x, click.y, in: frame) >= 0.1, "the click at \(click.time) s came to \(inset(click.x, click.y, in: frame))")
        }
        func centers(from start: Double, to end: Double) -> [(x: Double, y: Double)] {
            track.frames.indices.filter { Double($0) / track.rate >= start && Double($0) / track.rate <= end }
                .map { (track.frames[$0].centerX, track.frames[$0].centerY) }
        }
        for (start, end) in [(1.6, 3.1), (4 - StudioFraming.arriveEarly, 8.4)] {
            let held = centers(from: start, to: end)
            #expect(held.map(\.x).max()! - held.map(\.x).min()! < 0.5, "panned across from \(start) s to \(end) s")
            #expect(held.map(\.y).max()! - held.map(\.y).min()! < 0.5, "panned down from \(start) s to \(end) s")
        }
        // One move between, without turning back.
        let moving = centers(from: 3.1, to: 4).map(\.x)
        #expect(zip(moving, moving.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 })
        #expect(moving.last! - moving.first! > 700)
        #expect(track.frames.allSatisfy(isInsideTheRecording))
    }

    @Test func aZoomScalesAboutOnePoint() {
        // The pointer rests left of the middle and clicks twice: zooming in and out, one point of the recording
        // stays where it is on the movie, so nothing slides sideways.
        let telemetry = path([(0, 700, 450)], seconds: 8, clicks: [(3, 700, 450), (3.3, 700, 450)])
        let zooms = AutoZoom.zooms(for: telemetry, duration: 8)
        #expect(zooms.count == 1, "\(zooms)")
        expectScalingAboutOnePoint(track(telemetry, zooms: zooms, duration: 8), zoom: zooms[0])
    }

    @Test func aZoomThatMadeRoomForTheCursorStillScalesAboutOnePoint() {
        // The camera moved to keep a cursor that crossed the recording in view: going out, it stays on where it
        // was, rather than drifting back as it zooms out.
        let telemetry = path([(2, 400, 300), (3, 1300, 750)], seconds: 7)
        let zoom = StudioProject.Zoom(start: 1, end: 6, scale: 2, isAutomatic: false)
        let track = track(telemetry, zooms: [zoom], duration: 7)
        #expect(track.frame(at: 5).centerX > 900)
        expectScalingAboutOnePoint(track, zoom: zoom)
    }

    private func expectScalingAboutOnePoint(_ track: StudioTrack, zoom: StudioProject.Zoom) {
        let length = StudioTrack.transitionLength(zoom)
        for (from, to) in [(zoom.start, zoom.start + length), (zoom.end - length, zoom.end)] {
            let frames = track.frames.indices
                .filter { Double($0) / track.rate >= from - 1e-9 && Double($0) / track.rate <= to + 1e-9 }
                .map { track.frames[$0] }
            let a = frames.first!, b = frames.last!
            #expect(abs(a.zoom - b.zoom) > 0.3)
            // The point that is drawn at the same place in both: (p − c)·z alike.
            let pivotX = (b.centerX * b.zoom - a.centerX * a.zoom) / (b.zoom - a.zoom)
            let pivotY = (b.centerY * b.zoom - a.centerY * a.zoom) / (b.zoom - a.zoom)
            for frame in frames {
                #expect(abs((pivotX - frame.centerX) * frame.zoom - (pivotX - a.centerX) * a.zoom) < 1e-6, "x at zoom \(frame.zoom)")
                #expect(abs((pivotY - frame.centerY) * frame.zoom - (pivotY - a.centerY) * a.zoom) < 1e-6, "y at zoom \(frame.zoom)")
            }
        }
    }

    @Test func aZoomEasesEvenlyInScale() {
        // Halfway in, a zoom to 2 is at √2: each step of the ease enlarges the picture by the same proportion.
        let zoom = StudioProject.Zoom(start: 2, end: 6, scale: 2, isAutomatic: false)
        #expect(abs(StudioTrack.zoom(at: 2.25, zooms: [zoom]) - 2.0.squareRoot()) < 1e-9)
        #expect(StudioTrack.zoom(at: 2, zooms: [zoom]) == 1)
        #expect(StudioTrack.zoom(at: 4, zooms: [zoom]) == 2)
    }

    @Test func unzoomedTheCameraShowsTheWholeRecording() {
        let telemetry = path([(1, 100, 100), (3, 1500, 900)], seconds: 4)
        let track = track(telemetry, zooms: [], duration: 4)
        #expect(track.frames.allSatisfy { $0.zoom == 1 && $0.centerX == width / 2 && $0.centerY == height / 2 })
    }
}
