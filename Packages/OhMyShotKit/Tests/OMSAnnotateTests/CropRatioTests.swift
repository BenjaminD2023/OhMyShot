import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

struct CropRatioTests {
    private func ratio(of rect: CGRect) -> CGFloat { rect.width / rect.height }

    @Test func theMenuOffersFreeTheOriginalAndTheCommonShapes() {
        #expect(CropRatio.presets == [.free, .original, .fixed(1, 1), .fixed(4, 3), .fixed(3, 2), .fixed(16, 9), .fixed(9, 16)])
    }

    @Test func originalIsTheShapeOfThePictureAndFreeHasNone() {
        let picture = CGSize(width: 1600, height: 900)
        func value(_ ratio: CropRatio) -> Double? { ratio.value(forPicture: picture).map { Double($0) } }
        #expect(CropRatio.free.value(forPicture: picture) == nil)
        #expect(abs((value(.original) ?? 0) - 1600.0 / 900.0) < 1e-9)
        #expect(abs((value(.fixed(4, 3)) ?? 0) - 4.0 / 3.0) < 1e-9)
        #expect(abs((value(.fixed(9, 16)) ?? 0) - 9.0 / 16.0) < 1e-9)
        #expect(CropRatio.original.value(forPicture: .zero) == nil)
        #expect(CropRatio.fixed(0, 3).value(forPicture: picture) == nil)
    }

    @Test func choosingARatioFitsTheLargestCenteredFrame() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        #expect(CropRatio.fitted(1, in: frame) == CGRect(x: 50, y: 0, width: 100, height: 100))
        #expect(CropRatio.fitted(2, in: frame) == frame)
        let tall = CropRatio.fitted(9.0 / 16.0, in: frame)
        #expect(tall.height == 100 && abs(tall.width - 56.25) < 0.001 && abs(tall.midX - 100) < 0.001)
        let wide = CropRatio.fitted(16.0 / 9.0, in: CGRect(x: 10, y: 20, width: 90, height: 160))
        #expect(wide.width == 90 && abs(wide.height - 50.625) < 0.001 && abs(wide.midY - 100) < 0.001)
        // Within a frame that is itself in the way: a crop dragged part way.
        #expect(CropRatio.fitted(1, in: CGRect(x: 30, y: 30, width: 40, height: 80)) == CGRect(x: 30, y: 50, width: 40, height: 40))
    }

    @Test func aCornerHoldsTheOppositeOneAndGrowsAlongTheLongerDrag() {
        let ratio = 16.0 / 9.0
        let frame = CGRect(x: 100, y: 100, width: 160, height: 90)
        // Further across than down: the width leads.
        let wide = CropRatio.resized(frame, dragging: .bottomRight, to: CGPoint(x: 420, y: 200), ratio: ratio)
        #expect(wide.origin == frame.origin && wide.width == 320 && abs(wide.height - 180) < 0.001)
        // Further down than across: the height leads.
        let tall = CropRatio.resized(frame, dragging: .bottomRight, to: CGPoint(x: 200, y: 400), ratio: ratio)
        #expect(tall.origin == frame.origin && tall.height == 300 && abs(tall.width - 533.333) < 0.01)
        // The other corners hold the corner across from them.
        let up = CropRatio.resized(frame, dragging: .topLeft, to: CGPoint(x: 20, y: 90), ratio: ratio)
        #expect(up.maxX == frame.maxX && up.maxY == frame.maxY && abs(self.ratio(of: up) - ratio) < 0.0001)
        let upRight = CropRatio.resized(frame, dragging: .topRight, to: CGPoint(x: 300, y: 40), ratio: ratio)
        #expect(upRight.minX == frame.minX && upRight.maxY == frame.maxY && abs(self.ratio(of: upRight) - ratio) < 0.0001)
        let downLeft = CropRatio.resized(frame, dragging: .bottomLeft, to: CGPoint(x: 60, y: 240), ratio: ratio)
        #expect(downLeft.maxX == frame.maxX && downLeft.minY == frame.minY && abs(self.ratio(of: downLeft) - ratio) < 0.0001)
    }

    @Test func aFrameDraggedOutOfNothingTakesTheRatioAtOnce() {
        let start = CGPoint(x: 40, y: 40)
        let seed = CGRect(origin: start, size: .zero)
        for ratio in [1.0, 4.0 / 3.0, 3.0 / 2.0, 16.0 / 9.0, 9.0 / 16.0] {
            for end in [CGPoint(x: 140, y: 100), CGPoint(x: 10, y: 5), CGPoint(x: 60, y: 200), CGPoint(x: 5, y: 90)] {
                let rect = CropRatio.resized(seed, dragging: .bottomRight, to: end, ratio: ratio)
                #expect(rect.width > 0 && rect.height > 0)
                #expect(abs(self.ratio(of: rect) - ratio) < 0.0001)
                // Dragged back past the start, the frame goes the other way, still anchored on the start.
                #expect(rect.minX == start.x || rect.maxX == start.x)
                #expect(rect.minY == start.y || rect.maxY == start.y)
            }
        }
        // Not yet moved: it goes the way the handle points, with no size.
        let still = CropRatio.resized(seed, dragging: .bottomRight, to: start, ratio: 1)
        #expect(still.size == .zero)
    }

    @Test func aSideMovesAloneAndTheOtherDimensionFollowsAboutTheMiddle() {
        let frame = CGRect(x: 100, y: 100, width: 160, height: 90)
        let right = CropRatio.resized(frame, dragging: .right, to: CGPoint(x: 420, y: 0), ratio: 16.0 / 9.0)
        #expect(right.minX == 100 && right.width == 320 && abs(right.height - 180) < 0.001 && abs(right.midY - frame.midY) < 0.001)
        let left = CropRatio.resized(frame, dragging: .left, to: CGPoint(x: 180, y: 0), ratio: 16.0 / 9.0)
        #expect(left.maxX == 260 && left.width == 80 && abs(left.height - 45) < 0.001 && abs(left.midY - frame.midY) < 0.001)
        let bottom = CropRatio.resized(frame, dragging: .bottom, to: CGPoint(x: 0, y: 280), ratio: 1)
        #expect(bottom.minY == 100 && bottom.height == 180 && bottom.width == 180 && abs(bottom.midX - frame.midX) < 0.001)
        let top = CropRatio.resized(frame, dragging: .top, to: CGPoint(x: 0, y: 150), ratio: 1)
        #expect(top.maxY == 190 && top.height == 40 && top.width == 40 && abs(top.midX - frame.midX) < 0.001)
    }

    @Test func aSideDraggedPastTheOtherFlipsTheFrameWithoutBreakingTheRatio() {
        let frame = CGRect(x: 100, y: 100, width: 160, height: 90)
        let across = CropRatio.resized(frame, dragging: .right, to: CGPoint(x: 40, y: 0), ratio: 16.0 / 9.0)
        #expect(across.maxX == 100 && across.minX == 40 && abs(ratio(of: across) - 16.0 / 9.0) < 0.0001)
    }

    @Test func nonsenseRatiosAndHandlesChangeNothing() {
        let frame = CGRect(x: 10, y: 10, width: 50, height: 20)
        #expect(CropRatio.resized(frame, dragging: .bottomRight, to: CGPoint(x: 90, y: 90), ratio: 0) == frame)
        #expect(CropRatio.resized(frame, dragging: .bend, to: CGPoint(x: 90, y: 90), ratio: 1) == frame)
        #expect(CropRatio.fitted(0, in: frame) == frame)
    }
}
