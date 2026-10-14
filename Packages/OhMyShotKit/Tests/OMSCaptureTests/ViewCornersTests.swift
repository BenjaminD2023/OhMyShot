import CoreGraphics
import Foundation
import Testing
@testable import OMSCapture

struct ViewCornersTests {
    /// A window `width` × `height` filled opaque in a rounded rectangle of `radius`, its top corners square (above the
    /// picture), and with `translucentLeft` columns at the left edge drawn see-through (a sidebar).
    private static func window(width: Int, height: Int, radius: CGFloat, translucentLeft: Int = 0) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        // Taller than the picture by the radius: in its own coordinates (y up), only the bottom corners show rounded.
        context.addPath(CGPath(
            roundedRect: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) + 2 * radius), cornerWidth: radius,
            cornerHeight: radius, transform: nil
        ))
        context.fillPath()
        if translucentLeft > 0 {
            context.setBlendMode(.copy)
            context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 0.8))
            context.fill(CGRect(x: 0, y: 0, width: translucentLeft, height: height))
        }
        return context.makeImage()!
    }

    @Test func theCornersAreMeasuredFromTheWindowsAlpha() throws {
        let radius = 24.0
        let corners = try #require(ViewCorners(alphaOf: Self.window(width: 200, height: 160, radius: radius), most: 64))
        #expect(corners.topLeft.isEmpty && corners.topRight.isEmpty)
        #expect(corners.bottomLeft == corners.bottomRight)
        let insets = corners.bottomLeft
        #expect(zip(insets, insets.dropFirst()).allSatisfy { $0 >= $1 }, "\(insets)")
        // Row k from the bottom: the circle's edge along the row's outer side, every pixel short of it not wholly covered.
        for (row, inset) in insets.enumerated() {
            let y = radius - Double(row)
            let edge = radius - (radius * radius - y * y).squareRoot()
            #expect(abs(Double(inset) - edge.rounded(.up)) <= 1, "row \(row): \(inset) against \(edge)")
        }
        #expect(abs(insets.count - Int(radius)) <= 1, "\(insets)")
    }

    @Test func aSeeThroughEdgeIsNoCorner() throws {
        // A translucent sidebar down the left edge: nothing there tells the corner's shape. The right one still does.
        let corners = try #require(ViewCorners(alphaOf: Self.window(width: 200, height: 160, radius: 24, translucentLeft: 30), most: 64))
        #expect(corners.bottomLeft.isEmpty)
        #expect(!corners.bottomRight.isEmpty)
        // Square everywhere: nothing to fill.
        #expect(ViewCorners(alphaOf: Self.window(width: 200, height: 160, radius: 0), most: 64) == nil)
        #expect(corners.only([.bottomLeft]).isEmpty)
    }

    @Test func theCornersReadBackFromTheirDescription() throws {
        let corners = ViewCorners(topRight: [5, 3, 1], bottomLeft: [48, 27, 22, 1, 1])
        #expect(corners.description == "corners tl=- tr=5,3,1 bl=48,27,22,1,1 br=-")
        #expect(ViewCorners(description: corners.description) == corners)
        // Insets further in never exceed those nearer the edge.
        #expect(ViewCorners(bottomRight: [4, 6, 2, 0, 3]).bottomRight == [4, 4, 2])
    }

    @Test func aViewTurnedIsFilledAsItIsStraight() throws {
        // The same view taken as rows and as columns turned a quarter: every pixel the same in both after the fill.
        let width = 64, height = 48
        var state: UInt64 = 3
        let pixels = (0..<width * height).map { _ -> UInt32 in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return 0xFF00_0000 | UInt32(truncatingIfNeeded: state >> 40)
        }
        let corners = ViewCorners(topLeft: [6, 3, 1], topRight: [2, 1], bottomLeft: [9, 5, 3, 2, 1, 1], bottomRight: [4, 2, 1])
        try pixels.withUnsafeBytes { buffer in
            let source = try #require(buffer.baseAddress)
            let straight = try #require(Lines.make(source, bytesPerRow: width * 4, width: width, height: height, turned: false, margin: 4, corners: corners))
            let turned = try #require(Lines.make(source, bytesPerRow: width * 4, width: width, height: height, turned: true, margin: 4, corners: corners))
            var differ = 0, filled = 0
            for y in 0..<height {
                for x in 0..<width {
                    let a = straight.line(y).load(fromByteOffset: x * 4, as: UInt32.self)
                    let b = turned.line(x).load(fromByteOffset: (height - 1 - y) * 4, as: UInt32.self)
                    if a != b { differ += 1 }
                    if a != pixels[y * width + x] { filled += 1 }
                }
            }
            #expect(differ == 0)
            // Every pixel past the shape took the one inside it along its column: the bottom left corner's outermost
            // column takes the pixel six rows up.
            #expect(filled > 0)
            #expect(straight.line(height - 1).load(as: UInt32.self) == pixels[(height - 7) * width])
            #expect(straight.line(0).load(fromByteOffset: (width - 1) * 4, as: UInt32.self) == pixels[2 * width + width - 1])
        }
    }
}
