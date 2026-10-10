import Accelerate
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Makes an animated GIF from a recording, for the chats, issues, and documents that show pictures but
/// not movies.
///
/// The recording is read once, in order. GIF frames come at a steady rate, each showing what the recording
/// showed when it begins, and a run of them with the same picture becomes one frame shown longer, so a
/// screen that sits still costs one frame however long it sits. Every frame after the first holds only the
/// part of the picture that changed; when less than half of that part changed, the pixels left as they
/// were are transparent, so a pointer moving over a still page adds next to nothing. Pictures are scaled
/// with high-quality resampling, which keeps small text readable. Memory stays the same however long the
/// recording is: one frame is held at a time.
public enum GIFMaker {
    public struct Options: Equatable, Sendable {
        /// GIF frames per second, 1 to 50: browsers show no frame for less than two hundredths of a second.
        public var framesPerSecond: Int
        /// The GIF's size against the recording's: 0.5 makes a Retina recording as large as it was on screen.
        public var scale: Double
        /// The longest side the GIF may have, in pixels; a larger one is scaled down to fit.
        public var maxPixelSide: Int
        /// The part of the recording to make into a GIF; nil for all of it.
        public var timeRange: CMTimeRange?

        public init(framesPerSecond: Int = 15, scale: Double = 1, maxPixelSide: Int = 1920, timeRange: CMTimeRange? = nil) {
            self.framesPerSecond = framesPerSecond
            self.scale = scale
            self.maxPixelSide = maxPixelSide
            self.timeRange = timeRange
        }
    }

    public struct GIF: Equatable, Sendable {
        public let url: URL
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let frameCount: Int
        /// How long it plays once through.
        public let duration: TimeInterval
        public let byteCount: Int
    }

    public enum GIFError: Error, Equatable {
        case noVideo
        /// The recording, or the part asked for, has no frames.
        case empty
        case readingFailed(String)
        case encodingFailed
    }

    /// Makes a GIF at `destination` (replacing anything there) from the movie at `source`. `progress` is told
    /// how far along it is, from 0 to 1, now and then. Cancelling the task stops it and removes the file.
    @concurrent
    public static func make(
        from source: URL, to destination: URL, options: Options = Options(), progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> GIF {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw GIFError.noVideo }
        let natural = try await track.load(.naturalSize)
        let whole = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let range = options.timeRange.map { $0.intersection(whole) } ?? whole
        guard range.duration.seconds > 0 else { throw GIFError.empty }
        let size = pixelSize(width: Int(natural.width.rounded()), height: Int(natural.height.rounded()), options: options)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw GIFError.readingFailed(String(describing: reader.error)) }

        let writer = try GIFFileWriter(url: destination, width: size.width, height: size.height)
        let timeline = Timeline(framesPerSecond: options.framesPerSecond, length: range.duration.seconds)
        let assembler = Assembler(writer: writer, width: size.width, height: size.height, timeline: timeline)
        do {
            // The newest frame read and its number: what shows from its time until the next one's.
            var shown: (pixels: CVPixelBuffer, number: Int)?
            var count = 0
            var tick = 0
            var reported = 0.0
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let pixels = sample.imageBuffer else { continue }
                let time = sample.presentationTimeStamp.seconds - range.start.seconds
                // The ticks that begin before this frame show the one before it. A frame within a millisecond
                // of a tick is taken as on it: times in a movie are rarely exact.
                while let current = shown, tick < timeline.tickCount, timeline.time(of: tick) < time - 0.001 {
                    try assembler.show(current.pixels, number: current.number, at: tick)
                    tick += 1
                }
                shown = (pixels, count)
                count += 1
                if let progress, time / timeline.length - reported >= 0.01 {
                    reported = min(time / timeline.length, 1)
                    progress(reported)
                }
            }
            guard reader.status != .failed else { throw GIFError.readingFailed(String(describing: reader.error)) }
            while let current = shown, tick < timeline.tickCount {
                try assembler.show(current.pixels, number: current.number, at: tick)
                tick += 1
            }
            try assembler.finish()
        } catch {
            reader.cancelReading()
            writer.abandon()
            throw error
        }
        progress?(1)
        return GIF(
            url: destination, pixelWidth: size.width, pixelHeight: size.height, frameCount: writer.frameCount,
            duration: timeline.length, byteCount: writer.byteCount
        )
    }

    /// The GIF's size for a recording `width` × `height` pixels: scaled, then made to fit the longest side.
    static func pixelSize(width: Int, height: Int, options: Options) -> (width: Int, height: Int) {
        var scale = min(max(options.scale, 0.01), 1)
        let longest = Double(max(width, height)) * scale
        if longest > Double(options.maxPixelSide) { scale *= Double(options.maxPixelSide) / longest }
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }
}

/// When each GIF frame begins: ticks at the frame rate, from the start of the recording to its end.
struct Timeline {
    let framesPerSecond: Double
    /// The GIF's length in seconds.
    let length: Double
    let tickCount: Int

    init(framesPerSecond: Int, length: Double) {
        self.framesPerSecond = Double(min(max(framesPerSecond, 1), 50))
        self.length = length
        // Every tick begins at least two hundredths of a second before the end, so the last one shows.
        tickCount = max(1, Int(((length - 0.02) * self.framesPerSecond).rounded(.up)))
    }

    func time(of tick: Int) -> Double {
        Double(tick) / framesPerSecond
    }

    /// Where `tick` begins in hundredths of a second, as GIF counts time; the tick after the last is the end.
    /// Rounding where frames begin, rather than how long each lasts, keeps the GIF as long as the recording.
    func centiseconds(at tick: Int) -> Int {
        Int(((tick >= tickCount ? length : time(of: tick)) * 100).rounded())
    }
}

/// Turns the frames shown at each tick into GIF frames: scaled, compared with the picture before, and
/// written once the next different picture says how long each shows.
private final class Assembler {
    private let writer: GIFFileWriter
    private let width: Int
    private let height: Int
    private let timeline: Timeline
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// The picture the GIF shows now, and the one being made, as BGRA pixels at the GIF's size.
    private var previous: [UInt32]
    private var current: [UInt32]
    private var hasPrevious = false
    /// The recording's frame shown last, by its number: the reader reuses pixel buffers, so they can't tell.
    private var lastNumber = -1
    /// The newest GIF frame, held until the next one says how long it shows.
    private var pending: (frame: GIFFileWriter.Frame, tick: Int)?

    init(writer: GIFFileWriter, width: Int, height: Int, timeline: Timeline) {
        self.writer = writer
        self.width = width
        self.height = height
        self.timeline = timeline
        previous = [UInt32](repeating: 0, count: width * height)
        current = previous
    }

    /// Shows the recording's frame `number` (in `pixels`) from `tick`.
    func show(_ pixels: CVPixelBuffer, number: Int, at tick: Int) throws {
        guard number != lastNumber else { return }
        lastNumber = number
        scale(pixels)
        // The same picture as before after scaling: the frame before shows on.
        guard let frame = try makeFrame() else { return }
        try flush(at: tick)
        pending = (frame, tick)
        swap(&previous, &current)
        hasPrevious = true
    }

    /// Writes the last frame and ends the file.
    func finish() throws {
        guard pending != nil else { throw GIFMaker.GIFError.empty }
        try flush(at: timeline.tickCount)
        try writer.finish()
    }

    private func flush(at tick: Int) throws {
        guard let pending else { return }
        let delay = timeline.centiseconds(at: tick) - timeline.centiseconds(at: pending.tick)
        try writer.write(pending.frame, delay: max(delay, 2))
        self.pending = nil
    }

    private func scale(_ pixels: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        var source = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(pixels), height: vImagePixelCount(CVPixelBufferGetHeight(pixels)),
            width: vImagePixelCount(CVPixelBufferGetWidth(pixels)), rowBytes: CVPixelBufferGetBytesPerRow(pixels)
        )
        current.withUnsafeMutableBytes { bytes in
            var target = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            if source.width == target.width, source.height == target.height {
                vImageCopyBuffer(&source, &target, 4, vImage_Flags(kvImageNoFlags))
            } else {
                vImageScale_ARGB8888(&source, &target, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
    }

    /// The GIF frame for the picture now made: all of it the first time, then the part that differs from
    /// the picture before; nil when no pixel does.
    private func makeFrame() throws -> GIFFileWriter.Frame? {
        var box = (x: 0, y: 0, width: width, height: height)
        var transparent = false
        if hasPrevious {
            guard let difference = difference() else { return nil }
            box = (difference.x, difference.y, difference.width, difference.height)
            // Pixels left as they were are made transparent when they are most of the part: long runs of one
            // index compress well, while scattered ones (a page scrolling under a still background) cost more
            // than they save. Runs of pixels stand in for pixels in the count.
            let firstRun = box.x / Self.run, lastRun = (box.x + box.width - 1) / Self.run
            transparent = difference.changedRuns * 2 < (lastRun - firstRun + 1) * box.height
        }
        if transparent, let image = picture(box, transparent: true), let frame = GIFFileWriter.encode(image, x: box.x, y: box.y),
           frame.transparentIndex != nil {
            return frame
        }
        guard let image = picture(box, transparent: false), var frame = GIFFileWriter.encode(image, x: box.x, y: box.y) else {
            throw GIFMaker.GIFError.encodingFailed
        }
        frame.transparentIndex = nil
        return frame
    }

    /// Pixels compared at a time. Rows are compared a run at a time with `memcmp` and copied with `memcpy`,
    /// fast in a build without optimization too; pixels are looked at one by one only inside runs that
    /// changed.
    private static let run = 32

    /// The smallest box holding every pixel that differs from the picture before, and how many runs of
    /// pixels differ.
    private func difference() -> (x: Int, y: Int, width: Int, height: Int, changedRuns: Int)? {
        previous.withUnsafeBufferPointer { before in
            current.withUnsafeBufferPointer { now in
                guard let before = before.baseAddress, let now = now.baseAddress else { return nil }
                var minX = width, minY = height, maxX = -1, maxY = -1, changedRuns = 0
                for y in 0..<height {
                    let row = y * width
                    guard memcmp(before + row, now + row, width * 4) != 0 else { continue }
                    minY = min(minY, y)
                    maxY = y
                    var x = 0
                    while x < width {
                        let count = min(Self.run, width - x)
                        if memcmp(before + row + x, now + row + x, count * 4) != 0 {
                            changedRuns += 1
                            if x < minX {
                                var first = x
                                while before[row + first] == now[row + first] { first += 1 }
                                minX = min(minX, first)
                            }
                            if x + count - 1 > maxX {
                                var last = x + count - 1
                                while before[row + last] == now[row + last] { last -= 1 }
                                maxX = max(maxX, last)
                            }
                        }
                        x += count
                    }
                }
                guard maxX >= 0 else { return nil }
                return (minX, minY, maxX - minX + 1, maxY - minY + 1, changedRuns)
            }
        }
    }

    /// The part `box` of the picture now made, opaque; with `transparent`, the pixels the same as before
    /// are clear.
    private func picture(_ box: (x: Int, y: Int, width: Int, height: Int), transparent: Bool) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: box.width, height: box.height, bitsPerComponent: 8, bytesPerRow: box.width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            let data = context.data
        else { return nil }
        let target = data.bindMemory(to: UInt32.self, capacity: box.width * box.height)
        previous.withUnsafeBufferPointer { before in
            current.withUnsafeBufferPointer { now in
                guard let before = before.baseAddress, let now = now.baseAddress else { return }
                for row in 0..<box.height {
                    let source = (box.y + row) * width + box.x
                    let destination = target + row * box.width
                    // The decoder's pixels are opaque already.
                    memcpy(destination, now + source, box.width * 4)
                    guard transparent else { continue }
                    var x = 0
                    while x < box.width {
                        let count = min(Self.run, box.width - x)
                        if memcmp(before + source + x, now + source + x, count * 4) == 0 {
                            memset(destination + x, 0, count * 4)
                        } else {
                            for column in x..<x + count where before[source + column] == now[source + column] {
                                destination[column] = 0
                            }
                        }
                        x += count
                    }
                }
            }
        }
        return context.makeImage()
    }
}
