import CoreGraphics
import Testing
@testable import OMSUI

/// What a Quick Access card shows of a capture whose shape the card can't hold.
struct CaptureCardPictureTests {
    /// A picture whose top half is red and bottom half blue, or left half red and right half blue.
    private func picture(width: Int, height: Int, splitsAcross: Bool) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        // Context space is y up: the top half is the upper one.
        context.fill(splitsAcross ? CGRect(x: 0, y: height / 2, width: width, height: height / 2) : CGRect(x: 0, y: 0, width: width / 2, height: height))
        return context.makeImage()!
    }

    private func isRed(_ image: CGImage) -> Bool {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[0] > 200 && pixel[2] < 50
    }

    @Test func aScrollingCaptureShowsItsTop() throws {
        let tall = picture(width: 220, height: 3000, splitsAcross: true)
        let shown = try #require(CaptureCardView.shownPart(of: tall))
        #expect(shown.width == 220 && shown.height == 172)
        #expect(isRed(shown))
    }

    @Test func aWideCaptureShowsItsLeftEnd() throws {
        let wide = picture(width: 4000, height: 100, splitsAcross: false)
        let shown = try #require(CaptureCardView.shownPart(of: wide))
        #expect(shown.width == 220 && shown.height == 100)
        #expect(isRed(shown))
    }

    @Test func ordinaryCapturesAreShownWhole() throws {
        for (width, height) in [(800, 600), (600, 1200), (3440, 1440)] {
            let image = picture(width: width, height: height, splitsAcross: true)
            #expect(CaptureCardView.shownPart(of: image) === image)
        }
    }
}
