import CoreGraphics

/// One attached display.
public struct DisplayInfo: Sendable, Equatable, Identifiable {
    public let id: CGDirectDisplayID
    public let name: String
    /// Frame in AppKit's global space: points, origin at the bottom-left corner of the primary display, y up.
    public let frame: CGRect
    /// The framebuffer's real pixel size, which is what a capture of this display produces.
    public let pixelSize: CGSize
    public let backingScale: CGFloat
    /// The largest EDR component value this display can ever show. Above 1 means it can show HDR.
    public let maximumPotentialEDR: CGFloat

    public init(
        id: CGDirectDisplayID,
        name: String,
        frame: CGRect,
        pixelSize: CGSize,
        backingScale: CGFloat,
        maximumPotentialEDR: CGFloat
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.pixelSize = pixelSize
        self.backingScale = backingScale
        self.maximumPotentialEDR = maximumPotentialEDR
    }

    /// Framebuffer pixels per point. Unusual display modes make this differ from the backing scale,
    /// so capture sizes are always derived from this, never from the frame times the backing scale.
    public var pixelsPerPoint: CGFloat {
        frame.width > 0 ? pixelSize.width / frame.width : backingScale
    }

    public var supportsHDR: Bool { maximumPotentialEDR > 1 }
}

/// The arrangement of every attached display. The first one is the primary display: it holds the
/// menu bar and anchors both of macOS's global coordinate spaces.
public struct DisplayLayout: Sendable, Equatable {
    public let displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) {
        self.displays = displays
    }

    public var primary: DisplayInfo? { displays.first }

    /// Converts a rect between AppKit's global space (y up) and Core Graphics' global space (y down).
    ///
    /// Both spaces share the primary display's left edge; only the y axis flips around the primary
    /// display's height, so the conversion is its own inverse.
    public func flipped(_ rect: CGRect) -> CGRect {
        guard let primary else { return rect }
        return CGRect(
            x: rect.minX,
            y: primary.frame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts a point between AppKit's and Core Graphics' global spaces.
    public func flipped(_ point: CGPoint) -> CGPoint {
        guard let primary else { return point }
        return CGPoint(x: point.x, y: primary.frame.height - point.y)
    }

    /// The display under a point in AppKit's global space. A point on a shared edge belongs to the
    /// display whose frame starts there.
    public func display(at point: CGPoint) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) }
    }

    public func display(id: CGDirectDisplayID) -> DisplayInfo? {
        displays.first { $0.id == id }
    }

    /// Displays numbered the way CleanShot's URL API numbers them: 1 is the primary display.
    public func display(number: Int) -> DisplayInfo? {
        displays.indices.contains(number - 1) ? displays[number - 1] : nil
    }

    /// Converts a rect in a display's local space (points, bottom-left origin, as the URL API takes
    /// it) to AppKit's global space.
    public func globalRect(fromLocal rect: CGRect, on display: DisplayInfo) -> CGRect {
        rect.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
    }
}
