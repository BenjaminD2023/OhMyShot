import CoreGraphics
import Foundation
import Testing
@testable import OMSCapture

/// How long the stitcher takes a view the size of a Retina display's window (3500 × 2400 pixels) with a sidebar
/// and a timeline beside made-up text, in whatever build the tests are: OMS_STITCH_SPEED=1 swift test --filter
/// ScrollStitcherSpeedTests prints it. Docs/perf.md keeps what it measured.
struct ScrollStitcherSpeedTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMS_STITCH_SPEED"] != nil))
    func timePerView() throws {
        let width = 3500, height = 2400, pageHeight = 12000
        var page = [UInt32](repeating: 0xFFFF_FFFF, count: width * pageHeight)
        var state: UInt64 = 3
        func random(_ range: ClosedRange<Int>) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Int((state >> 33) % UInt64(range.count))
        }
        var top = 10
        while top + 28 < pageHeight {
            var x = 500 + random(0...40)
            while x < width - 400 {
                let word = min(random(20...120), width - 400 - x)
                let color = 0xFF00_0000 | UInt32(random(0x20...0x60)) * 0x010101
                for y in top + random(0...4) ..< top + 26 - random(0...4) { for column in x..<x + word where random(0...9) < 6 { page[y * width + column] = color } }
                x += word + random(10...24)
            }
            top += random(36...52)
        }
        func view(_ offset: Int) -> [UInt32] {
            var pixels = Array(page[offset * width ..< (offset + height) * width])
            for y in 0..<height {
                if y < 88 { for x in 0..<width { pixels[y * width + x] = 0xFF33_66CC } }
                else if y % 72 >= 20 && y % 72 < 48 { for x in 28..<280 { pixels[y * width + x] = 0xFF59_5966 &+ UInt32((x + y) % 3) } }
                if y > 150, y < 900 { for x in width - 220 ..< width - 200 { pixels[y * width + x] = 0xFFD0_D0D0 } }
            }
            return pixels
        }
        let stitcher = ScrollStitcher(width: width, height: height, pixelsPerPoint: 2, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var offset = 0
        _ = view(0).withUnsafeBytes { stitcher.add($0.baseAddress!, bytesPerRow: width * 4) }
        var spent: Duration = .zero
        var views = 0
        for step in Array(repeating: [80, 64, 96, 72, 88, 60, 100, 76, 84, 92, 68, 80, 74, 90, 66, 82, 98, 70, 86, 78, 94, 62, 88, 80, 72, 96, 84, 76, 90, 68], count: 3).joined() where offset + step + height <= pageHeight {
            offset += step
            let pixels = view(offset)
            let started = ContinuousClock.now
            let result = pixels.withUnsafeBytes { stitcher.add($0.baseAddress!, bytesPerRow: width * 4) }
            spent += ContinuousClock.now - started
            views += 1
            #expect(result == .scrolled(offset: step))
        }
        print("Stitched \(views) views of \(width) × \(height) pixels, \(spent / views) each; \(stitcher.summary)")
        // Then the page stops but for a video playing in it: a part of the view changes, nothing scrolls.
        let still = view(offset)
        spent = .zero
        for frame in 0..<30 {
            var pixels = still
            for y in 900..<1260 {
                for x in 1400..<2040 { pixels[y * width + x] = 0xFF00_0000 | UInt32((x * 5 + frame * 37) & 0xFF) * 0x010101 }
            }
            let started = ContinuousClock.now
            let result = pixels.withUnsafeBytes { stitcher.add($0.baseAddress!, bytesPerRow: width * 4) }
            spent += ContinuousClock.now - started
            #expect(result == .unchanged)
        }
        print("Then 30 views where only a video played, \(spent / 30) each")
    }
}
