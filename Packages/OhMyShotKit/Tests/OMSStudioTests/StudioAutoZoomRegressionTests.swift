import Foundation
import Testing
@testable import OMSStudio

struct StudioAutoZoomRegressionTests {
    private func key(_ time: Double, _ character: String = "a", modifiers: UInt = 0) -> StudioTelemetry.Key {
        .init(time: time, keyCode: 0, modifiers: modifiers, characters: character, keyCharacters: character, isRepeat: false)
    }

    private func peakPan(for track: StudioTrack, width: Double, from start: Double = 0, to end: Double? = nil) -> Double {
        let lower = max(1, Int((start * track.rate).rounded(.down)))
        let upper = min(track.frames.count - 1, Int(((end ?? Double(track.frames.count - 1) / track.rate) * track.rate).rounded(.up)))
        guard lower <= upper else { return 0 }
        var peak = 0.0
        for index in lower...upper {
            let a = track.frames[index - 1], b = track.frames[index]
            let view = width / max(a.zoom, 1)
            peak = max(peak, hypot(b.centerX - a.centerX, b.centerY - a.centerY) * track.rate / view)
        }
        return peak
    }

    @Test func aDragAcrossTheScreenPlacesNoAutomaticZoom() {
        let samples = (0...360).map { index -> StudioTelemetry.Sample in
            let time = Double(index) / 60
            let progress = min(max((time - 2) / 2, 0), 1)
            return .init(time: time, x: 100 + 1400 * progress, y: 500, cursor: 0)
        }
        let telemetry = StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 1, samples: samples, clicks: [
            .init(time: 2, x: 100, y: 500, button: .primary, releaseTime: 4, releaseX: 1500, releaseY: 500),
        ])
        #expect(AutoZoom.zooms(for: telemetry, duration: 6).isEmpty)
        // Manual zooms still receive the drag's events so StudioFraming can follow it.
        #expect(!AutoZoom.events(in: telemetry).isEmpty)
    }

    @Test func distantPairsCloseInTimePullBackInsteadOfWhippingAcrossTheScreen() {
        let telemetry = StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 1, clicks: [
            .init(time: 2, x: 100, y: 100, button: .primary), .init(time: 2.2, x: 120, y: 100, button: .primary),
            .init(time: 2.4, x: 1450, y: 900, button: .primary), .init(time: 2.6, x: 1470, y: 900, button: .primary),
        ])
        let zooms = AutoZoom.zooms(for: telemetry, duration: 8)
        #expect(zooms.count == 2)
        #expect(abs(zooms[0].end - zooms[1].start) < 1e-9)
        let track = StudioTrack(telemetry: telemetry, project: StudioProject(zooms: zooms), duration: 8)
        // At the boundary between the two distant clusters the camera pulls back to 1x.
        #expect(track.frame(at: zooms[0].end).zoom == 1)
        // Peak pan must stay near the baseline (~2.3 views/s), never the ~18.7 views/s whip from unscoped handover.
        #expect(peakPan(for: track, width: telemetry.width) < 4.0)
    }

    @Test func typingAfterAClickAnchorsToTheClickWhenThePointerMovesAway() {
        let samples = (0...600).map { index -> StudioTelemetry.Sample in
            let time = Double(index) / 60
            let progress = min(max((time - 2.2) / 0.5, 0), 1)
            return .init(time: time, x: 300 + 800 * progress, y: 200 + 500 * progress, cursor: 0)
        }
        let keys = (0..<40).map { key(3 + Double($0) * 0.1) }
        let telemetry = StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 1, samples: samples, clicks: [
            .init(time: 2, x: 300, y: 200, button: .primary),
        ], keys: keys)
        let zooms = AutoZoom.zooms(for: telemetry, duration: 10)
        #expect(zooms.count == 1)
        #expect(zooms[0].scale == AutoZoom.standardScale)
        let track = StudioTrack(telemetry: telemetry, project: StudioProject(zooms: zooms), duration: 10)
        // At 2x on 1600x1000, framing (300, 200) clamps to center (400, 250) and keeps (300, 200) squarely in view,
        // without drifting toward the parked pointer at (1100, 700).
        let midTyping = track.frame(at: 5)
        #expect(abs(midTyping.centerX - 400) < 1)
        #expect(abs(midTyping.centerY - 250) < 1)
    }

    @Test func keyboardOnlyTypingWithoutANearbyClickPlacesNoZoom() {
        let samples = (0...600).map { StudioTelemetry.Sample(time: Double($0) / 60, x: 1500, y: 950, cursor: 0) }
        let keys = [key(2, "l", modifiers: 1 << 20)] + (0..<20).map { key(2.5 + Double($0) * 0.1) }
        let telemetry = StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 1, samples: samples, keys: keys)
        #expect(AutoZoom.zooms(for: telemetry, duration: 10).isEmpty)
    }

    @Test func shortcutsDoNotTriggerATypingZoom() {
        let samples = (0...480).map { StudioTelemetry.Sample(time: Double($0) / 60, x: 800, y: 500, cursor: 0) }
        let shortcuts = [key(2, "c", modifiers: 1 << 20), key(3, "v", modifiers: 1 << 20)]
        let alone = StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 1, samples: samples, keys: shortcuts)
        #expect(AutoZoom.zooms(for: alone, duration: 8).isEmpty)
        let withOneClick = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 1, samples: samples,
            clicks: [.init(time: 1.8, x: 800, y: 500, button: .primary)], keys: shortcuts
        )
        #expect(AutoZoom.zooms(for: withOneClick, duration: 8).isEmpty)
    }

    @Test func abuttingZoomsHandOverOnOnePlaceAndPullBackAcrossDistance() {
        let still = (0...480).map { StudioTelemetry.Sample(time: Double($0) / 60, x: 400, y: 300, cursor: 0) }
        let samePlace = StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 1, samples: still, clicks: [
            .init(time: 2, x: 400, y: 300, button: .primary), .init(time: 5, x: 400, y: 300, button: .primary),
        ])
        let sameTrack = StudioTrack(telemetry: samePlace, project: StudioProject(zooms: [
            .init(start: 1, end: 4, scale: 2, isAutomatic: false), .init(start: 4, end: 7, scale: 1.5, isAutomatic: false),
        ]), duration: 8)
        // Same place: hands over at the gentler scale (1.5x) without dipping back to 1x.
        #expect(abs(sameTrack.frame(at: 4).zoom - 1.5) < 1e-6)
        #expect(sameTrack.frame(at: 3.75).zoom > 1.5 && sameTrack.frame(at: 3.75).zoom < 2.0)
        for sample in stride(from: 3.4, through: 4.6, by: 0.05) {
            #expect(sameTrack.frame(at: sample).zoom >= 1.5 - 1e-6)
        }
        #expect(peakPan(for: sameTrack, width: samePlace.width, from: 3.4, to: 4.6) < 1.1)

        // Distant places: pulls back to 1x at the boundary instead of whipping across the screen.
        let travel = (0...480).map { index -> StudioTelemetry.Sample in
            let time = Double(index) / 60
            let t = min(max((time - 4.0) / 0.8, 0), 1)
            let eased = t * t * t * (10 - 15 * t + 6 * t * t)
            return .init(time: time, x: 300 + 1000 * eased, y: 300 + 400 * eased, cursor: 0)
        }
        let farApart = StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 1, samples: travel, clicks: [
            .init(time: 2, x: 300, y: 300, button: .primary), .init(time: 5, x: 1300, y: 700, button: .primary),
        ])
        let farTrack = StudioTrack(telemetry: farApart, project: StudioProject(zooms: [
            .init(start: 1, end: 4, scale: 2, isAutomatic: false), .init(start: 4, end: 7, scale: 2, isAutomatic: false),
        ]), duration: 8)
        #expect(farTrack.frame(at: 4).zoom == 1)
    }

    @Test func cameraNeverLeavesBeforeThePreviousShotsLastEvent() {
        let samples = (0...360).map { index -> StudioTelemetry.Sample in
            let time = Double(index) / 60
            let progress = min(max((time - 2) / 0.25, 0), 1)
            return .init(time: time, x: 200 + 1200 * progress, y: 500, cursor: 0)
        }
        let telemetry = StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 1, samples: samples, clicks: [
            .init(time: 2, x: 200, y: 500, button: .primary), .init(time: 2.25, x: 1400, y: 500, button: .primary),
        ])
        let track = StudioTrack(telemetry: telemetry, project: StudioProject(zooms: [
            .init(start: 1, end: 5, scale: 2, isAutomatic: false),
        ]), duration: 6)
        // At t=2.00 (the first click), x=200 must still be comfortably inside the 800-pt wide view.
        let atFirstClick = track.frame(at: 2.0)
        let leftEdge = atFirstClick.centerX - (telemetry.width / atFirstClick.zoom) / 2
        let rightEdge = atFirstClick.centerX + (telemetry.width / atFirstClick.zoom) / 2
        #expect(leftEdge <= 200 && 200 <= rightEdge)
        // And without the early-leave snap, peak pan stays well below the 12+ views/s baseline.
        #expect(peakPan(for: track, width: telemetry.width) < 9.0)
    }

    @Test func aHandPlacedZoomSplitsSurroundingAutomaticZoomsInsteadOfCancelingThem() {
        // N-19: hand-placed zoom overlapping the second burst keeps the first burst's automatic zoom.
        let hand = [StudioProject.Zoom(start: 4.8, end: 7, scale: 2, isAutomatic: false)]
        let near = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 1,
            clicks: [1.0, 1.5, 4.5, 5.0].map { .init(time: $0, x: 400, y: 300, button: .primary) }
        )
        let nearAuto = AutoZoom.zooms(for: near, duration: 10, around: hand)
        #expect(!nearAuto.isEmpty)
        #expect(nearAuto.allSatisfy { auto in !hand.contains { $0.start < auto.end && auto.start < $0.end } })

        // A-20: a short hand-placed zoom in the middle of steady clicking keeps automatic zooms on both sides.
        let short = [StudioProject.Zoom(start: 5, end: 5.5, scale: 2, isAutomatic: false)]
        let steady = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 1,
            clicks: (1...9).map { .init(time: Double($0), x: 400, y: 300, button: .primary) }
        )
        let split = AutoZoom.zooms(for: steady, duration: 12, around: short)
        #expect(split.count == 2, "\(split)")
        #expect(split[0].end <= 5.0 + 1e-9)
        #expect(split[1].start >= 5.5 - 1e-9)
        #expect(split.allSatisfy { auto in !short.contains { $0.start < auto.end && auto.start < $0.end } })
    }

    @Test func offAreaClickDoesNotSwallowTypingZooms() throws {
        let samples = (0...600).map { index -> StudioTelemetry.Sample in
            let time = Double(index) / 60
            return .init(time: time, x: -120, y: 200, cursor: 0)
        }
        let keys = (0..<25).map { key(3.0 + Double($0) * 0.1) }
        let telemetry = StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 1,
            samples: samples,
            clicks: [
                .init(time: 2.0, x: 300, y: 200, button: .primary),
                .init(time: 2.5, x: -120, y: 200, button: .primary),
            ],
            keys: keys
        )
        let zooms = AutoZoom.zooms(for: telemetry, duration: 10)
        #expect(zooms.count == 1)
        let zoom = try #require(zooms.first)
        #expect(zoom.scale == AutoZoom.standardScale)
        let track = StudioTrack(telemetry: telemetry, project: StudioProject(zooms: zooms), duration: 10)
        let midTyping = track.frame(at: 4.5)
        #expect(abs(midTyping.centerX - 400) < 1)
        #expect(abs(midTyping.centerY - 250) < 1)
    }
}
