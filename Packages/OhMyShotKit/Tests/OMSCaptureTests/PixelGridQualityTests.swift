import CoreGraphics
import Foundation
import OMSCore
import Testing
@testable import OMSCapture

/// Expectations describe the geometry drawn into synthetic screenshots, independent of the detector.
/// The same image rendered at 1× and 2× must identify the same object in display points.
struct PixelGridQualityTests {
    private let width = 180
    private let height = 120
    private let selection = CGRect(x: 8, y: 6, width: 160, height: 106)

    private func contains(_ rect: CGRect, x: Int, y: Int) -> Bool {
        CGFloat(x) >= rect.minX && CGFloat(x) < rect.maxX && CGFloat(y) >= rect.minY && CGFloat(y) < rect.maxY
    }

    private func rasterRect(_ rect: CGRect, scale: Int) -> CGRect {
        CGRect(x: rect.minX * CGFloat(scale), y: rect.minY * CGFloat(scale), width: rect.width * CGFloat(scale), height: rect.height * CGFloat(scale))
    }

    private func grid(scale: Int, level: (Int, Int) -> Double) -> PixelGrid {
        let pixels = (0..<(height * scale)).flatMap { y in
            (0..<(width * scale)).map { x in
                let value = UInt32(min(255, max(0, level(x / scale, y / scale).rounded())))
                return 0xFF00_0000 | value << 16 | value << 8 | value
            }
        }
        return PixelGrid(width: width * scale, height: height * scale, pixels: pixels, pixelsPerPoint: CGFloat(scale))
    }

    @Test func aClosedLowContrastCardIsRecoveredOverAGentleGradientAtBothScales() {
        let card = CGRect(x: 36, y: 24, width: 96, height: 56)
        for scale in [1, 2] {
            let grid = grid(scale: scale) { x, y in
                Double(240 + x / 30 - (contains(card, x: x, y: y) ? 9 : 0))
            }
            // Every card edge is only nine levels darker than its neighboring background. The
            // background's one-level steps are not edges; the long, closed card perimeter is.
            #expect(grid.contentBounds(in: rasterRect(selection, scale: scale), tolerance: .medium) == rasterRect(card, scale: scale))
        }
    }

    @Test func aLongFaintSeparatorIsPreservedAtBothScales() {
        let separator = CGRect(x: 78, y: 17, width: 1, height: 81)
        for scale in [1, 2] {
            let grid = grid(scale: scale) { x, y in contains(separator, x: x, y: y) ? 236 : 245 }
            // A one-point line has a long supported edge, even though it is too narrow for a
            // four-sided card detector. It must not disappear under area noise rejection.
            #expect(grid.contentBounds(in: rasterRect(selection, scale: scale), tolerance: .medium) == rasterRect(separator, scale: scale))
        }
    }

    @Test func aStrongRoundedCardIgnoresIsolatedMarginPixelsOnlyWithAClosedPerimeter() {
        let card = CGRect(x: 36, y: 26, width: 100, height: 64)
        for scale in [1, 2] {
            let grid = grid(scale: scale) { x, y in
                if (x == 14 && y == 16) || (x == 158 && y == 98) { return 80 }
                let distance = roundedDistance(x: x, y: y, rect: card, radius: 10)
                if distance <= -1 { return 248 }
                if distance <= 0 { return 178 }
                return 246 - 16 * exp(-distance / 5)
            }
            // The intended target is the coherent, closed card border, excluding its penumbra.
            // The two isolated dots would be ambiguous without that strong rectangular evidence;
            // this expectation does not justify deleting disconnected text or icons generally.
            #expect(grid.contentBounds(in: rasterRect(selection, scale: scale), tolerance: .medium) == rasterRect(card, scale: scale))
        }
    }

    @Test func anOffCenterTargetAndAStrongThinLineRemainDetectable() {
        let targets = [CGRect(x: 116, y: 18, width: 36, height: 60), CGRect(x: 78, y: 17, width: 1, height: 81)]
        for target in targets {
            for scale in [1, 2] {
                let grid = grid(scale: scale) { x, y in contains(target, x: x, y: y) ? 96 : 246 }
                #expect(grid.contentBounds(in: rasterRect(selection, scale: scale), tolerance: .medium) == rasterRect(target, scale: scale))
            }
        }
    }

    @Test func aGentleBackgroundAndAnUnborderedSoftPatchDoNotInventEdges() {
        for scale in [1, 2] {
            let background = grid(scale: scale) { x, y in Double(220 + x / 12 + y / 20) }
            #expect(background.contentBounds(in: rasterRect(selection, scale: scale), tolerance: .medium) == nil)

            let softPatch = grid(scale: scale) { x, y in
                let dx = max(36 - x, 0, x - 131)
                let dy = max(24 - y, 0, y - 79)
                if dx == 0 && dy == 0 { return 231 }
                return 240 - 9 * exp(-hypot(Double(dx), Double(dy)) / 10)
            }
            // A smooth nine-level patch has no unique crisp perimeter. Abstain so the caller
            // retains the user's drawn rectangle instead of selecting an arbitrary blur contour.
            #expect(softPatch.contentBounds(in: rasterRect(selection, scale: scale), tolerance: .medium) == nil)
        }
    }

    private func roundedDistance(x: Int, y: Int, rect: CGRect, radius: Double) -> Double {
        let qx = abs(Double(x) + 0.5 - Double(rect.midX)) - (Double(rect.width) / 2 - radius)
        let qy = abs(Double(y) + 0.5 - Double(rect.midY)) - (Double(rect.height) / 2 - radius)
        return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
    }
}
