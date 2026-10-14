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

    /// This app's windows that captures take in anyway, as they are on screen: the pins, when Settings
    /// says so. Everything else of this app (the overlay, cards, the countdown) stays out.
    public var includedWindowIDs: (() -> Set<CGWindowID>)?

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

    /// What a recording streams: the content filter, the part of it, and the frame's size in pixels.
    public struct RecordingSource {
        public let filter: SCContentFilter
        /// The recorded part of the display, in points from its top-left corner; nil for all of it, and for
        /// a window, which is recorded whole.
        public let sourceRect: CGRect?
        /// The frame's size in pixels, both sides even: an area is trimmed by a pixel to make them so,
        /// never scaled, so every pixel is recorded as it is.
        public let pixelWidth: Int
        public let pixelHeight: Int
        /// Where the recorded part is, in AppKit's global space; a window's frame when recording began.
        public let frame: CGRect
        public let displayID: CGDirectDisplayID
    }

    /// The source for recording `target` on `display`. Areas and displays are recorded as the screen
    /// shows them, without this app's windows except the pins (as captures take them) and `including`
    /// (what a recording shows on purpose); a window is recorded on its own, without what covers it.
    public func recordingSource(
        for target: RecordingTarget, on display: DisplayInfo, including: Set<CGWindowID> = []
    ) async throws -> RecordingSource {
        switch target {
        case .window(let window):
            content.refresh()
            guard let found = try await content.current().windows.first(where: { $0.windowID == window.id }) else {
                throw CaptureError.windowNotFound(window.id)
            }
            let filter = SCContentFilter(desktopIndependentWindow: found)
            let scale = CGFloat(filter.pointPixelScale)
            let width = Int((filter.contentRect.width * scale).rounded()), height = Int((filter.contentRect.height * scale).rounded())
            return RecordingSource(
                filter: filter, sourceRect: nil, pixelWidth: max(2, width - width % 2), pixelHeight: max(2, height - height % 2),
                frame: window.frame, displayID: display.id
            )
        case .area, .display:
            let scDisplay = try await content.display(id: display.id)
            let excluded = try await content.ownApplication().map { [$0] } ?? []
            let included = (includedWindowIDs?() ?? []).union(including)
            let excepted = included.isEmpty ? [] : try await content.windows(withIDs: included)
            let filter = SCContentFilter(display: scDisplay, excludingApplications: excluded, exceptingWindows: excepted)
            let scale = display.pixelsPerPoint
            var area = display.frame
            if case .area(let rect) = target { area = rect.intersection(display.frame) }
            guard !area.isNull, area.width > 0, area.height > 0 else { throw CaptureError.emptyResult }
            var width = Int((area.width * scale).rounded()), height = Int((area.height * scale).rounded())
            // Even sides, by leaving out the last column or row of pixels.
            if width % 2 == 1 { width -= 1; area.size.width = CGFloat(width) / scale }
            if height % 2 == 1 { height -= 1; area.origin.y += 1 / scale; area.size.height = CGFloat(height) / scale }
            let isWhole = area.size == display.frame.size
            return RecordingSource(
                filter: filter, sourceRect: isWhole ? nil : Self.displayLocalRect(area, on: display),
                pixelWidth: max(2, width), pixelHeight: max(2, height), frame: area, displayID: display.id
            )
        }
    }

    /// What scrolling capture streams for `area` (global points) on `display`: the screen as it shows it,
    /// with none of this app's windows, pins included, which would stay put over what scrolls.
    public func scrollingSource(for area: CGRect, on display: DisplayInfo) async throws -> ScrollingCapture.Source {
        let scDisplay = try await content.display(id: display.id)
        let excluded = try await content.ownApplication().map { [$0] } ?? []
        let filter = SCContentFilter(display: scDisplay, excludingApplications: excluded, exceptingWindows: [])
        let rect = area.intersection(display.frame)
        let scale = display.pixelsPerPoint
        let width = Int((rect.width * scale).rounded()), height = Int((rect.height * scale).rounded())
        guard !rect.isNull, width >= 8, height >= 8 else { throw CaptureError.emptyResult }
        return ScrollingCapture.Source(
            filter: filter, sourceRect: Self.displayLocalRect(rect, on: display), pixelWidth: width, pixelHeight: height,
            pixelsPerPoint: scale, frame: rect, displayID: display.id
        )
    }

    /// The rounded corners `area` (global points, on `display`) shares with the window under its middle (or `windowID`),
    /// as the window's own picture has them, its corners clear: a window chosen with Space is captured as its frame, its
    /// corners showing what is behind it. Nil when it shares none, or they cannot be told.
    public func windowCorners(for area: CGRect, on display: DisplayInfo, layout: DisplayLayout, windowID: CGWindowID? = nil) async -> ViewCorners? {
        let windows = WindowCatalog.snapshot(layout: layout, excludingPID: getpid())
        let found = windowID.map { id in windows.first { $0.id == id } } ?? WindowCatalog.target(at: CGPoint(x: area.midX, y: area.midY), in: windows)
        guard let target = found else { return nil }
        let frame = target.frame
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 1 }
        var shared: Set<ViewCorners.Corner> = []
        if near(area.minX, frame.minX), near(area.maxY, frame.maxY) { shared.insert(.topLeft) }
        if near(area.maxX, frame.maxX), near(area.maxY, frame.maxY) { shared.insert(.topRight) }
        if near(area.minX, frame.minX), near(area.minY, frame.minY) { shared.insert(.bottomLeft) }
        if near(area.maxX, frame.maxX), near(area.minY, frame.minY) { shared.insert(.bottomRight) }
        guard !shared.isEmpty else { return nil }
        content.refresh()
        guard let window = try? await content.current().windows.first(where: { $0.windowID == target.id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        // Its pixels are the stream's only at the display's scale.
        guard CGFloat(filter.pointPixelScale) == display.pixelsPerPoint else { return nil }
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        configuration.ignoreShadows = true
        guard let output = try? await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration),
              let image = output.sdrImage,
              let corners = ViewCorners(alphaOf: image, most: Int((64 * display.pixelsPerPoint).rounded()))?.only(shared), !corners.isEmpty
        else { return nil }
        return corners
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
        let included = includingOwnWindows ? [] : includedWindowIDs?() ?? []
        let excepted = included.isEmpty ? [] : try await content.windows(withIDs: included)
        let filter = SCContentFilter(display: scDisplay, excludingApplications: excluded, exceptingWindows: excepted)

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
