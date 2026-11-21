import CoreImage
import Foundation
import OMSCore
import OSLog
import Vision

/// Where the person is in the camera's frames, for the camera's Blur and Cutout backgrounds: Vision's person
/// segmentation, on this Mac, with no model of our own. The preview asks for its fast matte, which leaves the
/// frame builder room to keep up with the camera's 30 frames a second, and the export for its accurate one.
///
/// One request is used for frame after frame, as Vision carries what it saw from one frame of a sequence to the
/// next, so the edge holds steady as the movie plays; a frame that isn't the next (the playhead moved, or the
/// movie went back) starts a request afresh, so nothing of another moment shows in it. The matte is made the
/// frame's size and its edge feathered by `feather`. The last `kept` mattes are kept with the camera's frames
/// they were made from, so a frame drawn again (the movie's 60 frames a second over the camera's 30, or a
/// still preview drawn again) asks Vision nothing; holding the frame keeps the decoder from filling it with
/// another.
nonisolated final class StudioCameraMatte: @unchecked Sendable {
    enum Quality: Sendable {
        case preview
        case export
    }

    /// How far the matte's edge is feathered, as a share of the frame's shorter side.
    static let feather = 0.004
    /// A frame further on than this from the one before, or before it, starts a sequence of its own.
    static let jump = 0.25
    /// How many mattes are kept with their frames.
    static let kept = 3

    private let quality: Quality
    /// Tests stand in for Vision: the matte of a frame, at any size, and whether it starts a sequence.
    private let segmenter: (@Sendable (CIImage, Bool) -> CIImage?)?
    private let lock = NSLock()
    private var request: VNGeneratePersonSegmentationRequest?
    private var lastTime = -Double.infinity
    private var recent: [(frame: CVPixelBuffer, matte: CIImage?)] = []
    private var reportedFailure = false

    init(quality: Quality, segmenter: (@Sendable (CIImage, Bool) -> CIImage?)? = nil) {
        self.quality = quality
        self.segmenter = segmenter
    }

    /// The person in `frame`, the camera's frame shown at `time` (the recording's seconds): white where they are,
    /// clear of them black, over the frame's extent; nil when they can't be told apart, so the frame shows as it was.
    func matte(for frame: CIImage, at time: Double) -> CIImage? {
        lock.withLock {
            let buffer = frame.pixelBuffer
            if let buffer, let found = recent.first(where: { $0.frame === buffer }) { return found.matte }
            let fresh = time < lastTime || time - lastTime > Self.jump
            lastTime = time
            let extent = frame.extent
            let made = segment(frame, fresh: fresh).flatMap { matte -> CIImage? in
                guard matte.extent.width > 0, matte.extent.height > 0, extent.width > 0, extent.height > 0 else { return nil }
                return matte
                    .transformed(by: CGAffineTransform(translationX: -matte.extent.minX, y: -matte.extent.minY))
                    .transformed(by: CGAffineTransform(scaleX: extent.width / matte.extent.width, y: extent.height / matte.extent.height))
                    .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
                    .clampedToExtent()
                    .applyingGaussianBlur(sigma: min(extent.width, extent.height) * Self.feather)
                    .cropped(to: extent)
            }
            if let buffer {
                recent.append((buffer, made))
                if recent.count > Self.kept { recent.removeFirst() }
            }
            return made
        }
    }

    /// Vision's matte of `frame`, from the request that saw the frames before it unless `fresh`. Under `lock`.
    private func segment(_ frame: CIImage, fresh: Bool) -> CIImage? {
        if let segmenter { return segmenter(frame, fresh) }
        let request: VNGeneratePersonSegmentationRequest
        if !fresh, let current = self.request {
            request = current
        } else {
            request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = quality == .export ? .accurate : .fast
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            self.request = request
        }
        let handler = frame.pixelBuffer.map { VNImageRequestHandler(cvPixelBuffer: $0) } ?? VNImageRequestHandler(ciImage: frame)
        do {
            try handler.perform([request])
            guard let matte = request.results?.first?.pixelBuffer else { return nil }
            return CIImage(cvPixelBuffer: matte)
        } catch {
            if !reportedFailure {
                reportedFailure = true
                Log.studio.error("The person couldn't be found in the camera's frame: \(String(describing: error), privacy: .public)")
            }
            self.request = nil
            return nil
        }
    }
}
