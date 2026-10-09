import CoreGraphics
import Foundation
import OMSCore
import ScreenCaptureKit

/// Takes screenshots through ScreenCaptureKit, always with a filter that leaves this app's own
/// windows out. The rect-only capture APIs take no filter and would capture the selection overlay.
public final class ScreenCapturer {
    public enum DynamicRange: Sendable {
        case sdr
        /// SDR plus an extended-range copy, for saving HDR captures.
        case sdrAndHDR
    }

    private let content: ShareableContentCache

    public init(content: ShareableContentCache) {
        self.content = content
    }

    /// Captures a whole display at its framebuffer resolution. `includingOwnWindows` is for rendering
    /// the overlay itself in scripted checks; real captures always leave this app out.
    public func captureDisplay(
        _ display: DisplayInfo,
        dynamicRange: DynamicRange = .sdr,
        showsCursor: Bool = false,
        includingOwnWindows: Bool = false
    ) async throws -> CapturedFrame {
        try await capture(display: display, region: nil, dynamicRange: dynamicRange, showsCursor: showsCursor, includingOwnWindows: includingOwnWindows)
    }

    /// Captures part of one display. `rect` is in AppKit's global space and must lie on `display`.
    public func captureRegion(
        _ rect: CGRect,
        on display: DisplayInfo,
        dynamicRange: DynamicRange = .sdr,
        showsCursor: Bool = false
    ) async throws -> CapturedFrame {
        try await capture(display: display, region: rect, dynamicRange: dynamicRange, showsCursor: showsCursor, includingOwnWindows: false)
    }

    /// Captures an area that may cross displays: each display's part, put together at the sharpest
    /// display's scale. An area on one display is a plain region capture.
    public func captureArea(_ rect: CGRect, in layout: DisplayLayout) async throws -> CapturedFrame {
        let displays = layout.displays.filter { !$0.frame.intersection(rect).isEmpty }
        guard let first = displays.first else { throw CaptureError.emptyResult }
        guard displays.count > 1 else { return try await captureRegion(rect, on: first) }
        var parts: [CapturedFrame] = []
        for display in displays {
            parts.append(try await captureRegion(rect, on: display))
        }
        let scale = displays.map(\.pixelsPerPoint).max() ?? first.pixelsPerPoint
        guard let stitched = CapturedFrame.stitched(parts, covering: rect, pixelsPerPoint: scale) else { throw CaptureError.emptyResult }
        return stitched
    }

    /// Captures one window on its own, with real transparency at its rounded corners, even when other
    /// windows cover it. With `shadow`, the image grows to hold the window's shadow.
    public func captureWindow(_ target: WindowTarget, shadow: Bool, layout: DisplayLayout) async throws -> CapturedFrame {
        // Windows come and go, so look this one up in fresh content.
        content.refresh()
        guard let window = try await content.current().windows.first(where: { $0.windowID == target.id }) else {
            throw CaptureError.windowNotFound(target.id)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        configuration.ignoreShadows = !shadow
        // No explicit size: the default is the window at its native scale plus, with a shadow, the
        // shadow's margin. Setting the window's own size would shrink a shadowed capture to fit.
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
        guard let image = output.sdrImage else { throw CaptureError.emptyResult }
        let displayID = layout.display(at: CGPoint(x: target.frame.midX, y: target.frame.midY))?.id ?? layout.primary?.id ?? 0
        return CapturedFrame(image: image, hdrImage: nil, displayID: displayID, frame: target.frame)
    }

    private func capture(
        display: DisplayInfo,
        region: CGRect?,
        dynamicRange: DynamicRange,
        showsCursor: Bool,
        includingOwnWindows: Bool
    ) async throws -> CapturedFrame {
        let scDisplay = try await content.display(id: display.id)
        let excluded = includingOwnWindows ? [] : try await content.ownApplication().map { [$0] } ?? []
        let filter = SCContentFilter(display: scDisplay, excludingApplications: excluded, exceptingWindows: [])

        let captured = region.map { $0.intersection(display.frame) } ?? display.frame
        guard !captured.isEmpty else { throw CaptureError.emptyResult }

        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = showsCursor
        configuration.dynamicRange = dynamicRange == .sdr ? .sdr : .bothSDRAndHDR
        if region != nil {
            configuration.sourceRect = Self.displayLocalRect(captured, on: display)
        }
        // Ask for framebuffer pixels explicitly so scaled display modes come out 1:1.
        configuration.width = Int((captured.width * display.pixelsPerPoint).rounded())
        configuration.height = Int((captured.height * display.pixelsPerPoint).rounded())

        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
        guard let image = output.sdrImage else { throw CaptureError.emptyResult }
        return CapturedFrame(image: image, hdrImage: output.hdrImage, displayID: display.id, frame: captured)
    }

    /// Converts a rect in AppKit's global space to the display's own logical space, which
    /// ScreenCaptureKit measures in points from the display's top-left corner.
    static func displayLocalRect(_ rect: CGRect, on display: DisplayInfo) -> CGRect {
        CGRect(
            x: rect.minX - display.frame.minX,
            y: display.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
