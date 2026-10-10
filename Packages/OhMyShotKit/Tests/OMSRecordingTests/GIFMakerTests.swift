import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import Testing
@testable import OMSRecording

struct GIFMakerTests {
    @Test func aStillStretchIsOneFrameShownForAsLong() async throws {
        let movie = try await Self.movie(seconds: 2) { second in
            [TestMedia.frame(at: 0, gray: 40), TestMedia.frame(at: 1, gray: 200)].filter { _ in second == 0 }
        }
        let url = Self.temporaryGIF()
        defer { [movie, url].forEach { try? FileManager.default.removeItem(at: $0) } }

        let gif = try await GIFMaker.make(from: movie, to: url, options: .init(framesPerSecond: 10))
        let frames = try Self.frames(of: url)
        #expect(frames.count == 2, "\(frames)")
        #expect(frames.first?.delay == 100)
        #expect(frames.map(\.delay).reduce(0, +) == 200)
        #expect(gif.frameCount == frames.count)
        #expect(abs(gif.duration - 2) < 0.01)
        #expect((gif.pixelWidth, gif.pixelHeight) == (320, 240))
        // The second picture differs everywhere, so it is written whole and opaque.
        #expect(frames.last.map { ($0.width, $0.height, $0.transparent) } ?? (0, 0, true) == (320, 240, false))
        #expect(try Self.size(of: url) == gif.byteCount)
    }

    @Test func onlyWhatChangedIsWritten() async throws {
        let movie = try await Self.movie(seconds: 2) { second in
            second == 0 ? [
                TestMedia.frame(at: 0, gray: 128),
                TestMedia.frame(at: 1, gray: 128, squares: [(x: 100, y: 80, size: 40, gray: 235)]),
            ] : []
        }
        let url = Self.temporaryGIF()
        defer { [movie, url].forEach { try? FileManager.default.removeItem(at: $0) } }

        _ = try await GIFMaker.make(from: movie, to: url, options: .init(framesPerSecond: 10))
        let frames = try Self.frames(of: url)
        let square = try #require(frames.count == 2 ? frames[1] : nil, "\(frames)")
        // The square and a few pixels the codec smudged around it, nothing more.
        #expect(square.x >= 80 && square.y >= 60 && square.width <= 80 && square.height <= 80, "\(square)")
        #expect(square.x <= 100 && square.y <= 80 && square.x + square.width >= 140 && square.y + square.height >= 120, "\(square)")

        // Played back, the square is on the page and the page is as it was.
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let picture = try #require(CGImageSourceCreateImageAtIndex(source, 1, nil))
        #expect(try Self.gray(of: picture, x: 120, y: 100) > 220)
        let page = try Self.gray(of: picture, x: 20, y: 20)
        #expect(page > 110 && page < 150, "\(page)")
    }

    @Test func changesFarApartLeaveWhatIsBetweenThemTransparent() async throws {
        let movie = try await Self.movie(seconds: 2) { second in
            second == 0 ? [
                TestMedia.frame(at: 0, gray: 128),
                TestMedia.frame(at: 1, gray: 128, squares: [(x: 8, y: 8, size: 16, gray: 235), (x: 296, y: 216, size: 16, gray: 30)]),
            ] : []
        }
        let url = Self.temporaryGIF()
        defer { [movie, url].forEach { try? FileManager.default.removeItem(at: $0) } }

        _ = try await GIFMaker.make(from: movie, to: url, options: .init(framesPerSecond: 10))
        let frames = try Self.frames(of: url)
        let corners = try #require(frames.count == 2 ? frames[1] : nil, "\(frames)")
        // One frame from corner to corner, mostly transparent.
        #expect(corners.transparent)
        #expect(corners.width >= 280 && corners.height >= 200, "\(corners)")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let picture = try #require(CGImageSourceCreateImageAtIndex(source, 1, nil))
        #expect(try Self.gray(of: picture, x: 16, y: 16) > 220)
        #expect(try Self.gray(of: picture, x: 304, y: 224) < 40)
        let middle = try Self.gray(of: picture, x: 160, y: 120)
        #expect(middle > 110 && middle < 150, "\(middle)")
    }

    @Test func aPartScaledDown() async throws {
        let movie = try await Self.movie(seconds: 2) { second in
            second == 0 ? (0..<20).map { TestMedia.frame(at: Double($0) / 10, gray: UInt8(40 + $0 * 8)) } : []
        }
        let url = Self.temporaryGIF()
        defer { [movie, url].forEach { try? FileManager.default.removeItem(at: $0) } }

        let range = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600), end: CMTime(seconds: 1.5, preferredTimescale: 600))
        let gif = try await GIFMaker.make(from: movie, to: url, options: .init(framesPerSecond: 10, scale: 0.5, timeRange: range))
        #expect((gif.pixelWidth, gif.pixelHeight) == (160, 120))
        #expect(abs(gif.duration - 1) < 0.01)
        let frames = try Self.frames(of: url)
        #expect(frames.map(\.delay).reduce(0, +) == 100)
        #expect(frames.count == 10, "\(frames.map(\.delay))")
        // It begins with the frame shown half a second in.
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let expected = Self.fullRange(40 + 5 * 8)
        #expect(abs(try Self.gray(of: first, x: 80, y: 60) - expected) < 10)
    }

    @Test func cancellingRemovesTheFile() async throws {
        let movie = try await Self.movie(seconds: 2) { second in
            second == 0 ? (0..<20).map { TestMedia.frame(at: Double($0) / 10, gray: UInt8(40 + $0 * 8)) } : []
        }
        let url = Self.temporaryGIF()
        defer { [movie, url].forEach { try? FileManager.default.removeItem(at: $0) } }

        let task = Task { try await GIFMaker.make(from: movie, to: url) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func sizeFitsTheLongestSide() {
        #expect(GIFMaker.pixelSize(width: 2000, height: 1280, options: .init(scale: 0.5)) == (1000, 640))
        #expect(GIFMaker.pixelSize(width: 6880, height: 2880, options: .init(scale: 0.5)) == (1920, 804))
        #expect(GIFMaker.pixelSize(width: 640, height: 480, options: .init(scale: 2)) == (640, 480))
    }

    @Test func framesBeginOnTicksAndTheGIFLastsAsLongAsTheRecording() {
        let timeline = Timeline(framesPerSecond: 15, length: 10.06)
        #expect(timeline.tickCount == 151)
        #expect(timeline.centiseconds(at: 1) == 7)
        #expect(timeline.centiseconds(at: 2) == 13)
        #expect(timeline.centiseconds(at: timeline.tickCount) == 1006)
        // A last tick shorter than two hundredths of a second is left out.
        #expect(Timeline(framesPerSecond: 10, length: 1.01).tickCount == 10)
        #expect(Timeline(framesPerSecond: 120, length: 1).framesPerSecond == 50)
    }

    // MARK: Helpers

    /// A movie of `seconds` written as a recording is: each second's frames come from `frames(second)`.
    private static func movie(seconds: Int, frames: (Int) -> [CMSampleBuffer]) async throws -> URL {
        let url = TestMedia.temporaryMovie()
        let writer = try TestMedia.writer(url: url)
        for second in 0..<seconds {
            for frame in frames(second) {
                nonisolated(unsafe) let sample = frame
                try await TestMedia.append(sample, to: writer)
            }
        }
        try await writer.finish(at: TestMedia.time(Double(seconds)))
        return url
    }

    private static func temporaryGIF() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "OMSRecordingTests-\(UUID().uuidString).gif")
    }

    private static func size(of url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    /// Each frame's place, how long it shows (in hundredths of a second), and whether it has a transparent
    /// index, read from the file's blocks.
    private static func frames(of url: URL) throws -> [(x: Int, y: Int, width: Int, height: Int, delay: Int, transparent: Bool)] {
        let bytes = [UInt8](try Data(contentsOf: url))
        func word(_ index: Int) -> Int { Int(bytes[index]) | Int(bytes[index + 1]) << 8 }
        var frames: [(x: Int, y: Int, width: Int, height: Int, delay: Int, transparent: Bool)] = []
        var index = 13 + (bytes[10] & 0x80 != 0 ? 3 << (Int(bytes[10] & 7) + 1) : 0)
        var delay = 0, transparent = false
        while index < bytes.count {
            switch bytes[index] {
            case 0x21:
                if bytes[index + 1] == 0xF9 {
                    delay = word(index + 4)
                    transparent = bytes[index + 3] & 1 != 0
                }
                var cursor = index + 2
                while bytes[cursor] != 0 { cursor += Int(bytes[cursor]) + 1 }
                index = cursor + 1
            case 0x2C:
                frames.append((word(index + 1), word(index + 3), word(index + 5), word(index + 7), delay, transparent))
                var cursor = index + 10 + (bytes[index + 9] & 0x80 != 0 ? 3 << (Int(bytes[index + 9] & 7) + 1) : 0) + 1
                while bytes[cursor] != 0 { cursor += Int(bytes[cursor]) + 1 }
                index = cursor + 1
            default:
                index = bytes.count
            }
        }
        return frames
    }

    /// The green value of one pixel, as the GIF shows it.
    private static func gray(of image: CGImage, x: Int, y: Int) throws -> Double {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let pixel = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Double(pixel[1])
    }

    /// A video-range luma level as the full-range gray it decodes to.
    private static func fullRange(_ luma: Int) -> Double {
        Double(luma - 16) * 255 / 219
    }
}
