import CoreImage
import Foundation
import Testing
@testable import OMSStudio

/// Opt in with OMS_STUDIO_BENCHMARK=1 and run in Release. Fixed inputs, three runs, median reported;
/// timings are observations, not pass/fail thresholds that depend on the machine running the suite.
@Suite(.serialized)
struct StudioAlgorithmBenchmarks {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMS_STUDIO_BENCHMARK"] == "1"))
    func longRecordingTrackAndRandomSeek() {
        for duration in [600.0, 3600.0] {
            let zoomCount = duration == 600 ? 300 : 600
            let samples = (0...Int(duration * 60)).map { index in
                StudioTelemetry.Sample(time: Double(index) / 60, x: 800 + 300 * sin(Double(index) / 120), y: 500, cursor: 0)
            }
            let clicks = (0..<Int(duration / 3)).map { index in
                StudioTelemetry.Click(time: Double(index) * 3 + 0.317, x: 800, y: 500, button: .primary)
            }
            let keys = (0..<Int(duration * 2)).map { index in
                StudioTelemetry.Key(time: Double(index) / 2, keyCode: 0, modifiers: 0, characters: "a", keyCharacters: "a", isRepeat: false)
            }
            let telemetry = StudioTelemetry(width: 1600, height: 1000, pixelsPerPoint: 1, samples: samples, clicks: clicks, keys: keys)
            var project = StudioProject(zooms: (0..<zoomCount).map { index in
                let start = Double(index) * duration / Double(zoomCount)
                return .init(start: start, end: start + 1.5, scale: 1.5 + Double(index % 3) * 0.2, isAutomatic: false)
            })
            project.motionBlur = false
            var times: [Double] = []
            var checksum = 0.0
            for _ in 0..<3 {
                let start = Date.timeIntervalSinceReferenceDate
                let track = StudioTrack(telemetry: telemetry, project: project, duration: duration)
                times.append(Date.timeIntervalSinceReferenceDate - start)
                checksum += track.frame(at: duration / 2).centerX
                #expect(track.frames.count == Int(duration * 120) + 1)
            }
            let renderer = StudioRenderer(telemetry: telemetry, project: project, duration: duration, recordingSize: CGSize(width: 1600, height: 1000), background: nil)
            let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 1000))
            var seekTimes: [Double] = []
            for _ in 0..<3 {
                let start = Date.timeIntervalSinceReferenceDate
                for index in 0..<300 {
                    let time = Double((index * 7919) % 300) / 300 * duration
                    checksum += renderer.image(source: source, at: time).extent.width
                }
                seekTimes.append(Date.timeIntervalSinceReferenceDate - start)
            }
            print("STUDIO_BENCH duration=\(Int(duration)) zooms=\(zoomCount) track_median_ms=\(times.sorted()[1] * 1000) random_300_seek_ms=\(seekTimes.sorted()[1] * 1000) track_payload_bytes=\((Int(duration * 120) + 1) * MemoryLayout<StudioTrack.Frame>.stride) checksum=\(checksum)")
            #expect(checksum > 0)
        }
    }
}
