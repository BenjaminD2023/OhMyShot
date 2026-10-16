import CoreGraphics
import Foundation
import Testing
@testable import OMSCore

struct WindowBackgroundTests {
    @Test func eachChoiceAndShiftTheOtherWayRound() {
        #expect(WindowBackground.asScreenshots.resolved(automaticPreset: true, shiftHeld: false) == .preset)
        #expect(WindowBackground.asScreenshots.resolved(automaticPreset: false, shiftHeld: false) == .none)
        #expect(WindowBackground.transparent.resolved(automaticPreset: true, shiftHeld: false) == .none)
        #expect(WindowBackground.desktopWallpaper.resolved(automaticPreset: false, shiftHeld: false) == .wallpaper)
        // Shift: none where there would be one, the desktop picture where there would be none.
        #expect(WindowBackground.asScreenshots.resolved(automaticPreset: true, shiftHeld: true) == .none)
        #expect(WindowBackground.transparent.resolved(automaticPreset: false, shiftHeld: true) == .wallpaper)
        #expect(WindowBackground.desktopWallpaper.resolved(automaticPreset: false, shiftHeld: true) == .none)
    }

    @MainActor @Test func settingsDefaultToTheShadowAndScreenshotsBackground() {
        let defaults = UserDefaults(suiteName: "WindowBackgroundTests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.windowShadow)
        #expect(settings.windowBackground == .asScreenshots)
        settings.windowBackground = .desktopWallpaper
        #expect(SettingsStore(defaults: defaults).windowBackground == .desktopWallpaper)
    }
}

/// The desktop picture behind a window: around it, as large as the finished picture, on the display.
struct WallpaperCropTests {
    /// A 2× display 1000 × 800 points at the origin.
    private let display = DisplayInfo(
        id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), pixelSize: CGSize(width: 2000, height: 1600),
        backingScale: 2, maximumPotentialEDR: 1
    )

    @Test func theRegionIsAroundTheWindowWithItsRoom() throws {
        // A 400 × 300 pt window captured at 2×, 800 × 600 px; room 0.1 of its measure (692.8 px) all round.
        let window = CGRect(x: 300, y: 250, width: 400, height: 300)
        let region = try #require(WallpaperCrop.region(around: window, picturePixels: CGSize(width: 800, height: 600), padding: 0.1, on: display))
        let room = 0.1 * (800.0 * 600).squareRoot()
        // Whole pixels, outward: up to 2 more each way.
        #expect(abs(region.width - (800 + 2 * room)) <= 2 && abs(region.height - (600 + 2 * room)) <= 2)
        // Centered on the window's middle, (500, 400) pt, which is (1000, 800) px from the top-left.
        #expect(abs(region.midX - 1000) <= 1 && abs(region.midY - 800) <= 1)
    }

    @Test func aWindowAtTheEdgeIsCutToTheDisplay() throws {
        let window = CGRect(x: 0, y: 600, width: 300, height: 200)
        let region = try #require(WallpaperCrop.region(around: window, picturePixels: CGSize(width: 600, height: 400), padding: 0.1, on: display))
        #expect(region.minX == 0 && region.minY == 0)
        #expect(CGRect(x: 0, y: 0, width: 2000, height: 1600).contains(region))
    }

    @Test func aWindowOffTheDisplayHasNone() {
        #expect(WallpaperCrop.region(around: CGRect(x: 5000, y: 5000, width: 10, height: 10), picturePixels: CGSize(width: 20, height: 20), padding: 0.1, on: display) == nil)
    }

    /// A 2× capture of a 200 × 100 pt window with a shadow 20 px deep above it, 60 px below, and 40 px each side.
    private func shadowedWindow(opaqueMiddle: Bool = true) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 480, height: 280, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0, alpha: 0.4))
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 280))
        // Drawn y up: the window's foot is 60 px above the capture's.
        context.clear(CGRect(x: 40, y: 60, width: 400, height: 200))
        context.setFillColor(CGColor(gray: 1, alpha: opaqueMiddle ? 1 : 0.3))
        context.fill(CGRect(x: 40, y: 60, width: 400, height: 200))
        return try #require(context.makeImage())
    }

    /// The capture lies where its window does, its shadow's room around it: lower than centered, as the shadow
    /// below is deeper.
    @Test func aShadowedWindowsCaptureLiesAroundTheWindowAsItsShadowFalls() throws {
        let window = CGRect(x: 300, y: 400, width: 200, height: 100)
        let picture = WallpaperCrop.pictureFrame(of: try shadowedWindow(), window: window, pixelsPerPoint: 2)
        #expect(picture == CGRect(x: 280, y: 370, width: 240, height: 140))
    }

    /// A window clear in the middle cannot be found in its capture: the capture is centered on it.
    @Test func aWindowNotFoundInItsCaptureIsCenteredOn() throws {
        let window = CGRect(x: 300, y: 400, width: 200, height: 100)
        let picture = WallpaperCrop.pictureFrame(of: try shadowedWindow(opaqueMiddle: false), window: window, pixelsPerPoint: 2)
        #expect(picture == CGRect(x: 280, y: 380, width: 240, height: 140))
    }
}
