import AVFoundation
import CoreGraphics
import Foundation
import Observation

/// Owns only the thumbnails needed by an open timeline. SwiftUI cancels `load` when the viewport changes.
@Observable
final class StudioTimelineFilmstrip {
    typealias ReadFrames = @Sendable (URL, [StudioFilmstripRequest.Sample], Double) -> AsyncStream<Frame>
    private(set) var images: [Int64: CGImage] = [:]
    @ObservationIgnored private var cache = StudioFrameCache<CGImage>()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let readFrames: ReadFrames

    init(readFrames: @escaping ReadFrames = StudioTimelineFilmstrip.frames) {
        self.readFrames = readFrames
    }

    func load(source: URL, request: StudioFilmstripRequest) async {
        generation += 1
        let mine = generation
        var cached: [Int64: CGImage] = [:]
        for sample in request.samples {
            if let image = cache.value(for: sample.id) { cached[sample.id] = image }
        }
        images = cached
        let missing = request.samples.filter { cached[$0.id] == nil }
        guard !missing.isEmpty else { return }
        // A fast pan or zoom doesn't start a decoder for every intermediate position.
        do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
        guard !Task.isCancelled, mine == generation else { return }
        for await frame in readFrames(source, missing, request.tolerance) {
            guard !Task.isCancelled, mine == generation else { return }
            cache.insert(frame.image, for: frame.key, cost: frame.image.bytesPerRow * frame.image.height)
            images[frame.key] = frame.image
        }
    }

    nonisolated struct Frame: Sendable {
        let key: Int64
        let image: CGImage
    }

    /// Image generation runs on one task; AVFoundation permits cancellation from another task.
    private nonisolated final class Decoder: @unchecked Sendable {
        let generator: AVAssetImageGenerator

        init(source: URL, tolerance: Double) {
            generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.maximumSize = CGSize(width: 640, height: 80)
            generator.appliesPreferredTrackTransform = true
            let allowed = CMTime(seconds: tolerance, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = allowed
            generator.requestedTimeToleranceAfter = allowed
        }
    }

    private nonisolated static func frames(
        source: URL, samples: [StudioFilmstripRequest.Sample], tolerance: Double
    ) -> AsyncStream<Frame> {
        AsyncStream(bufferingPolicy: .bufferingOldest(65)) { continuation in
            let task = Task.detached(priority: .utility) {
                let decoder = Decoder(source: source, tolerance: tolerance)
                await withTaskCancellationHandler { @Sendable in
                    for sample in samples {
                        guard !Task.isCancelled else { break }
                        let time = CMTime(value: sample.id, timescale: 600)
                        if let result = try? await decoder.generator.image(at: time), !Task.isCancelled {
                            continuation.yield(Frame(key: sample.id, image: result.image))
                        }
                    }
                } onCancel: {
                    decoder.generator.cancelAllCGImageGeneration()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
