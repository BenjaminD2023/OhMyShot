import AppKit
import CoreGraphics
import Foundation
import OMSCore
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

    @MainActor
    @Test func swipeFeedbackCountdownRingAndCompactShortCardLayout() {
        let thumb = picture(width: 400, height: 120, splitsAcross: true)
        let item = QuickAccessItem(
            id: UUID(), kind: .screenshot, fileURL: URL(filePath: "/tmp/test.png"),
            thumbnail: thumb, pixelWidth: 400, pixelHeight: 120, displayID: 1
        )
        let card = CaptureCardView(item: item, size: .medium)
        card.frame = CGRect(x: 0, y: 0, width: 220, height: 100)
        card.layout()
        // Short card (< 124 pt) uses compact 26 pt pills with 4 pt spacing.
        #expect(card.copyButton.pillHeight == 26)
        #expect(card.actions.spacing == 4)

        // Countdown ring shows while counting and hides when cleared.
        #expect(!card.isCountdownRingVisible)
        card.setCountdown((remaining: 5, interval: 10))
        #expect(card.isCountdownRingVisible)
        card.setCountdown(nil)
        #expect(!card.isCountdownRingVisible)

        // Swipe translation follows gesture, springs back under threshold, and closes past threshold.
        var closed = 0
        card.onClose = { closed += 1 }
        card.applySwipePhase(.began, deltaX: 0)
        card.applySwipePhase(.changed, deltaX: -30)
        #expect(card.swipeTranslation == -30)
        card.applySwipePhase(.ended, deltaX: 0)
        #expect(closed == 0 && card.swipeTranslation == 0)

        card.applySwipePhase(.began, deltaX: 0)
        card.applySwipePhase(.changed, deltaX: -65)
        card.applySwipePhase(.ended, deltaX: 0)
        #expect(closed == 1)
    }
}
