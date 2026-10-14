import CoreImage
import Foundation
import Testing
@testable import OMSStudio

struct StudioMotionTests {
    /// A pointer moving right at 200 pt/s from (100, 100) for `seconds`, read 60 times a second.
    private func moving(for seconds: Double, clicks: [(Double, Double, Double)] = [], keys: [Double] = []) -> StudioTelemetry {
        let samples = stride(from: 0.0, through: seconds, by: 1.0 / 60).map {
            StudioTelemetry.Sample(time: $0, x: 100 + 200 * $0, y: 100, cursor: 0)
        }
        return StudioTelemetry(
            width: 1600, height: 1000, pixelsPerPoint: 2, samples: samples,
            clicks: clicks.map { .init(time: $0.0, x: $0.1, y: $0.2, button: .primary) },
            keys: keys.map { .init(time: $0, keyCode: 0, modifiers: 0, characters: "a", keyCharacters: "a", isRepeat: false) }
        )
    }

    /// Clicks at `times`, all in one place, on the line the pointer moves along.
    private func clicks(at times: [Double]) -> [(Double, Double, Double)] {
        times.map { ($0, 800, 100) }
    }

    @Test func clicksCloseTogetherMakeOneZoom() {
        let telemetry = moving(for: 10, clicks: [(2, 500, 400), (3, 520, 420), (3.5, 540, 400), (9.2, 1200, 700), (9.5, 1210, 700)])
        let zooms = AutoZoom.zooms(for: telemetry, duration: 10)
        #expect(zooms.count == 2, "\(zooms)")
        #expect(abs(zooms[0].start - (2 - AutoZoom.leadIn)) < 1e-9)
        #expect(abs(zooms[0].end - (3.5 + AutoZoom.hold)) < 1e-9)
        #expect(zooms[0].scale == AutoZoom.lightScale)
        // The last two clicks: at least the shortest zoom, held within the movie.
        #expect(zooms[1].end <= 10 && zooms[1].end - zooms[1].start >= AutoZoom.shortest - 1e-9)
        #expect(zooms.allSatisfy { $0.isAutomatic })
    }

    @Test func aLoneClickPlacesNoZoom() {
        // One click; clicks too far apart to be neighbors; and a click whose neighbor was on another display,
        // which does not count.
        #expect(AutoZoom.zooms(for: moving(for: 8, clicks: clicks(at: [3])), duration: 8).isEmpty)
        #expect(AutoZoom.zooms(for: moving(for: 14, clicks: clicks(at: [2, 6, 10])), duration: 14).isEmpty)
        #expect(AutoZoom.zooms(for: moving(for: 8, clicks: [(3, 800, 500), (3.5, 2400, 300)]), duration: 8).isEmpty)
    }

    @Test func aSingleKeyPlacesNoZoomButTypingDoes() {
        #expect(AutoZoom.zooms(for: moving(for: 8, keys: [3]), duration: 8).isEmpty)
        let typing = AutoZoom.zooms(for: moving(for: 8, keys: [3, 3.3]), duration: 8)
        #expect(typing.map(\.scale) == [AutoZoom.standardScale], "\(typing)")
    }

    @Test func twoOrThreeClicksZoomGentlyAndBusierStretchesOrTypingZoomMore() {
        func scales(clicks times: [Double] = [], keys: [Double] = []) -> [Double] {
            AutoZoom.zooms(for: moving(for: 8, clicks: clicks(at: times), keys: keys), duration: 8).map(\.scale)
        }
        #expect(scales(clicks: [3, 3.4]) == [AutoZoom.lightScale])
        #expect(scales(clicks: [3, 3.4, 3.8]) == [AutoZoom.lightScale])
        #expect(scales(clicks: [3, 3.4, 3.8, 4.2]) == [AutoZoom.standardScale])
        #expect(scales(keys: [3, 3.4]) == [AutoZoom.standardScale])
        // A click and a key: typing is in it.
        #expect(scales(clicks: [3], keys: [3.4]) == [AutoZoom.standardScale])
    }

    @Test func zoomsAFewSecondsApartAreOneZoomThatStaysIn() {
        // Two pairs of clicks 2.5 s apart: the zooms have 0.5 s between them, and the camera would go out and
        // back in within a second and a half.
        let close = AutoZoom.zooms(for: moving(for: 10, clicks: clicks(at: [2, 2.3, 4.8, 5.1])), duration: 10)
        #expect(close.count == 1, "\(close)")
        #expect(abs(close[0].start - (2 - AutoZoom.leadIn)) < 1e-9)
        #expect(abs(close[0].end - (5.1 + AutoZoom.hold)) < 1e-9)
        // A busy stretch and a light one with 2.5 s between their zooms: one zoom, at the gentler scale.
        let mixed = AutoZoom.zooms(for: moving(for: 12, clicks: clicks(at: [2, 2.2, 2.4, 2.6, 7.1, 7.3])), duration: 12)
        #expect(mixed.count == 1, "\(mixed)")
        #expect(abs(mixed[0].start - (2 - AutoZoom.leadIn)) < 1e-9)
        #expect(abs(mixed[0].end - (7.3 + AutoZoom.hold)) < 1e-9)
        #expect(mixed[0].scale == AutoZoom.lightScale)
        // The same the other way round: the gentler scale wins whichever comes first.
        let reversed = AutoZoom.zooms(for: moving(for: 12, clicks: clicks(at: [2, 2.2, 6.5, 6.7, 6.9, 7.1])), duration: 12)
        #expect(reversed.count == 1, "\(reversed)")
        #expect(abs(reversed[0].end - (7.1 + AutoZoom.hold)) < 1e-9)
        #expect(reversed[0].scale == AutoZoom.lightScale)
    }

    @Test func zoomsJoinUpToThreeSecondsApartAndNoFurther() {
        // The first zoom ends at 3.6 s; the second begins 2.9 s after that, or 3.1 s.
        let inside = AutoZoom.zooms(for: moving(for: 12, clicks: clicks(at: [2, 2.2, 7.1, 7.3])), duration: 12)
        #expect(inside.count == 1, "\(inside)")
        let outside = AutoZoom.zooms(for: moving(for: 12, clicks: clicks(at: [2, 2.2, 7.3, 7.5])), duration: 12)
        #expect(outside.count == 2, "\(outside)")
    }

    @Test func zoomsMoreThanThreeSecondsApartStayTwo() {
        // The first zoom ends at 3.6 s; the second begins 3.5 s after that, or 4 s.
        let near = AutoZoom.zooms(for: moving(for: 12, clicks: clicks(at: [2, 2.2, 7.7, 7.9])), duration: 12)
        #expect(near.count == 2, "\(near)")
        let far = AutoZoom.zooms(for: moving(for: 12, clicks: clicks(at: [2, 2.2, 8.2, 8.4])), duration: 12)
        #expect(far.count == 2, "\(far)")
        #expect(abs(far[1].start - far[0].end - 4) < 1e-9)
    }

    @Test func activitySpreadWideZoomsLessOrNotAtAll() {
        // Four clicks 700 pt apart fit a gentler zoom than the standard (1600 / (700 + 160) is 1.86, down to
        // 1.8), and two 1000 pt apart one gentler than the light (1.38, down to 1.3); clicks at opposite
        // corners fit none.
        let apart = AutoZoom.zooms(for: moving(for: 6, clicks: [(2, 300, 500), (2.2, 1000, 500), (2.4, 300, 500), (2.6, 1000, 500)]), duration: 6)
        #expect(apart.map(\.scale) == [1.8], "\(apart)")
        let wide = AutoZoom.zooms(for: moving(for: 6, clicks: [(2, 300, 500), (2.5, 1300, 500)]), duration: 6)
        #expect(wide.map(\.scale) == [1.3], "\(wide)")
        let corners = AutoZoom.zooms(for: moving(for: 6, clicks: [(2, 20, 20), (2.5, 1580, 980)]), duration: 6)
        #expect(corners.isEmpty)
    }

    @Test func clicksOutsideTheRecordingPlaceNoZoom() {
        // Two clicks each on another display, left of the recording, and below it; only the last two are inside.
        let zooms = AutoZoom.zooms(for: moving(for: 12, clicks: [
            (1, 2400, 300), (1.3, 2420, 300), (4, -40, 500), (4.3, -30, 500), (7, 800, 1060), (7.3, 810, 1060), (10, 800, 500), (10.3, 820, 500),
        ]), duration: 12)
        #expect(zooms.count == 1, "\(zooms)")
        #expect(abs(zooms[0].start - (10 - AutoZoom.leadIn)) < 1e-9)
    }

    @Test func typingZoomsWhereThePointerIs() {
        let zooms = AutoZoom.zooms(for: moving(for: 8, keys: [3, 3.2, 3.4, 3.6]), duration: 8)
        #expect(zooms.count == 1)
        #expect(abs(zooms[0].start - 2.4) < 1e-9)
    }

    @Test func zoomsEaseInAndOut() {
        let zoom = StudioProject.Zoom(start: 2, end: 6, scale: 2, isAutomatic: false)
        #expect(StudioTrack.zoom(at: 1.9, zooms: [zoom]) == 1)
        #expect(StudioTrack.zoom(at: 2, zooms: [zoom]) == 1)
        #expect(abs(StudioTrack.zoom(at: 2.25, zooms: [zoom]) - 1.5) < 1e-9)
        #expect(StudioTrack.zoom(at: 4, zooms: [zoom]) == 2)
        #expect(StudioTrack.zoom(at: 6, zooms: [zoom]) == 1)
    }

    @Test func theCameraNeverShowsPastTheRecording() {
        // The pointer runs to the right edge while zoomed: the camera stops where the recording ends.
        let telemetry = moving(for: 8)
        var project = StudioProject(zooms: [.init(start: 1, end: 7, scale: 2, isAutomatic: false)])
        project.cursor.smoothing = 0
        let track = StudioTrack(telemetry: telemetry, project: project, duration: 8)
        for frame in track.frames {
            let halfWidth = 1600 / frame.zoom / 2, halfHeight = 1000 / frame.zoom / 2
            #expect(frame.centerX >= halfWidth - 1e-6 && frame.centerX <= 1600 - halfWidth + 1e-6)
            #expect(frame.centerY >= halfHeight - 1e-6 && frame.centerY <= 1000 - halfHeight + 1e-6)
        }
        // Fully zoomed, the cursor stays in view.
        let middle = track.frame(at: 5)
        #expect(abs(middle.cursorX - middle.centerX) <= 1600 / middle.zoom / 2)
    }

    @Test func smoothingCalmsTheCursorButCatchesUp() {
        // A pointer that jumps 300 pt at 1 s and rests.
        let samples = [StudioTelemetry.Sample(time: 0, x: 100, y: 100, cursor: 0), .init(time: 1, x: 400, y: 100, cursor: 0)]
        let telemetry = StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 2, samples: samples)
        var raw = StudioProject()
        raw.cursor.smoothing = 0
        let exact = StudioTrack(telemetry: telemetry, project: raw, duration: 3)
        #expect(exact.frame(at: 1.01).cursorX == 400)
        let smooth = StudioTrack(telemetry: telemetry, project: StudioProject(), duration: 3)
        let soon = smooth.frame(at: 1.02).cursorX
        #expect(soon > 100 && soon < 400, "\(soon)")
        #expect(abs(smooth.frame(at: 2).cursorX - 400) < 1)
    }

    @Test func aRestingCursorFadesAndComesBack() {
        let samples = [StudioTelemetry.Sample(time: 0, x: 100, y: 100, cursor: 0), .init(time: 4, x: 300, y: 100, cursor: 0)]
        let telemetry = StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 2, samples: samples)
        let track = StudioTrack(telemetry: telemetry, project: StudioProject(), duration: 5)
        #expect(track.frame(at: 0.5).cursorOpacity == 1)
        #expect(track.frame(at: 3.5).cursorOpacity == 0)
        #expect(track.frame(at: 4.3).cursorOpacity == 1)
    }

    @Test func thePictureTravelsMostAtTheCornersWhenZooming() {
        // A pan of 10 recording pixels at twice the size moves everything 20 movie pixels.
        let frame = CGSize(width: 1000, height: 600)
        #expect(abs(StudioRenderer.travel(from: .init(x: 100, y: 50, scale: 2), to: .init(x: 110, y: 50, scale: 2), across: frame) - 20) < 1e-9)
        // Zooming about the frame's corner moves its far corner by a tenth of the diagonal.
        let zoom = StudioRenderer.travel(from: .init(x: 0, y: 0, scale: 1), to: .init(x: 0, y: 0, scale: 1.1), across: frame)
        #expect(abs(zoom - 0.1 * hypot(1000, 600)) < 1e-6)
    }

    @Test func motionBlurOnlyWhileTheCameraMoves() throws {
        // A zoom from 1 s to 3 s: still before it, moving through its first half second.
        var project = StudioProject(background: .color(red: 1, green: 1, blue: 1), padding: 0, zooms: [.init(start: 1, end: 3, scale: 2, isAutomatic: false)])
        project.shadow = 0
        project.cornerRadius = 0
        project.cursor.hidesWhenIdle = false
        let telemetry = StudioTelemetry(width: 400, height: 250, pixelsPerPoint: 2, samples: [.init(time: 0, x: 120, y: 125, cursor: 0)])
        let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: 4, recordingSize: CGSize(width: 800, height: 500), background: nil)
        #expect(renderer.exposures(at: 0.5).count == 1)
        #expect(renderer.exposures(at: 2).count == 1)
        let moving = renderer.exposures(at: 1.25)
        #expect(moving.count > 4 && moving.count <= StudioRenderer.mostExposures, "\(moving.count)")

        // Black and white stripes 40 pixels wide: still, a stripe's edge stays crisp, blurred or not; while
        // zooming in, edges near the frame's edge smear only with the blur on.
        let stripes = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor.black, "inputColor1": CIColor.white, "inputWidth": 40, "inputSharpness": 1,
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 800, height: 500))
        var still = project
        still.motionBlur = false
        let sharp = StudioRenderer(telemetry: telemetry, project: still, duration: 4, recordingSize: CGSize(width: 800, height: 500), background: nil)
        let context = CIContext()
        func row(_ renderer: StudioRenderer, at time: Double) throws -> [Double] {
            let image = try #require(context.createCGImage(renderer.image(source: stripes, at: time), from: CGRect(x: 0, y: 0, width: 800, height: 500)))
            let data = try #require(image.dataProvider?.data as Data?)
            // The row through the middle, the right part where a zoom moves things most: gray levels.
            return (600..<800).map { Double(data[250 * image.bytesPerRow + $0 * 4 + 1]) }
        }
        let grays = { (values: [Double]) in values.filter { $0 > 40 && $0 < 215 }.count }
        #expect(try row(renderer, at: 0.5) == row(sharp, at: 0.5))
        let blurredRow = try row(renderer, at: 1.25), crispRow = try row(sharp, at: 1.25)
        #expect(grays(blurredRow) >= grays(crispRow) + 10, "\(grays(blurredRow)) vs \(grays(crispRow))")
        // Smeared, not darkened: the stripes average the same gray either way.
        let mean = { (values: [Double]) in values.reduce(0, +) / Double(values.count) }
        #expect(abs(mean(blurredRow) - mean(crispRow)) < 12, "\(mean(blurredRow)) vs \(mean(crispRow))")
    }
}
