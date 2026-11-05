import AppKit
import OMSCore
import OMSDesign
import QuartzCore

/// An area outlined where it lies, as Self-Timer's countdown and a recording show it: one click-through
/// panel per display it reaches, over menus, on every Space, left out of every capture and recording. A
/// recording can also have the rest of the display dimmed around its area, or a red frame in place of the
/// outline.
public final class AreaOutline {
    private var panels: [CountdownPanel] = []
    private var lease: ActiveResources.Lease?

    public init() {}

    public var isShowing: Bool { !panels.isEmpty }

    /// Outlines `area` (global points) as `style` says, replacing what was outlined before.
    public func show(_ area: CGRect, layout: DisplayLayout, style: RecordingHighlight = .outline) {
        hide()
        panels = Self.panels(around: area, layout: layout, style: style)
        panels.forEach { $0.orderFrontRegardless() }
        lease = ActiveResources.shared.acquire(.window)
    }

    public func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        lease = nil
    }

    /// Room around an area for its outline or frame, in points.
    static let edgeRoom: CGFloat = 4
    /// The width of the red frame, which lies wholly outside the area.
    static let redFrameWidth: CGFloat = 3

    /// One panel of an area's highlight.
    struct Placement: Equatable {
        /// Where the panel lies, in global points.
        var frame: CGRect
        /// Where the area is within the panel.
        var area: CGRect
    }

    /// Where the panels for `area` go on `displays` (global frames): one on each display the area reaches,
    /// as with a Space per display a window across two shows on only one. Around the area, or over the whole
    /// display when `style` dims the rest of it.
    static func placements(around area: CGRect, displays: [CGRect], style: RecordingHighlight) -> [Placement] {
        displays.filter { !$0.intersection(area).isEmpty }.map { display in
            let frame = style == .dim ? display : area.insetBy(dx: -edgeRoom, dy: -edgeRoom).intersection(display)
            return Placement(frame: frame, area: area.offsetBy(dx: -frame.minX, dy: -frame.minY))
        }
    }

    /// The panels for `area`, not yet on screen.
    static func panels(around area: CGRect, layout: DisplayLayout, style: RecordingHighlight = .outline) -> [CountdownPanel] {
        placements(around: area, displays: layout.displays.map(\.frame), style: style).map { placement in
            let bounds = CGRect(origin: .zero, size: placement.frame.size)
            switch style {
            case .outline:
                let panel = CountdownPanel(frame: placement.frame)
                let view = SelectionOutlineView(frame: bounds)
                view.outline = placement.area
                panel.contentView = view
                return panel
            case .dim:
                // Under the recording's own windows (its control bar, the keys, the camera), which the dim must
                // not dim.
                let panel = CountdownPanel(frame: placement.frame, level: Self.dimLevel)
                let view = AreaDimView(frame: bounds)
                view.area = placement.area
                panel.contentView = view
                return panel
            case .redFrame:
                let panel = CountdownPanel(frame: placement.frame)
                let view = AreaFrameView(frame: bounds)
                view.area = placement.area
                panel.contentView = view
                return panel
            }
        }
    }

    /// Just under the level where a recording's control bar, keystrokes, and click rings lie.
    static let dimLevel = RecordingWindowLevel.dim
}

/// The area's edge, drawn as the capture overlay draws a selection: white over a soft dark outline.
/// Nothing is dimmed: the screen is in use.
final class SelectionOutlineView: NSView {
    var outline: CGRect = .zero {
        didSet { updatePaths() }
    }

    private let shade = CAShapeLayer()
    private let edge = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        for line in [shade, edge] {
            line.fillColor = nil
            line.lineJoin = .round
            layer?.addSublayer(line)
        }
        shade.lineWidth = Theme.Overlay.borderWidth + 2
        edge.lineWidth = Theme.Overlay.borderWidth
        edge.strokeColor = .white
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        shade.strokeColor = CGColor(gray: 0, alpha: contrast ? Theme.Overlay.outlineOpacityIncreasedContrast : Theme.Overlay.outlineOpacity)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        for line in [shade, edge] { line.frame = bounds }
        updatePaths()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for line in [shade, edge] { line.contentsScale = scale }
    }

    private func updatePaths() {
        let path = CGPath(rect: outline, transform: nil)
        shade.path = path
        edge.path = path
    }
}

/// The display dimmed as the capture overlay dims it, except where the area is.
final class AreaDimView: NSView {
    var area: CGRect = .zero {
        didSet { updatePath() }
    }

    private let dim = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        dim.fillRule = .evenOdd
        dim.fillColor = CGColor(gray: 0, alpha: contrast ? Theme.Overlay.dimmingIncreasedContrast : Theme.Overlay.dimming)
        layer?.addSublayer(dim)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        dim.frame = bounds
        updatePath()
    }

    private func updatePath() {
        // The whole view with the area left out of it.
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(area)
        dim.path = path
    }
}

/// The area framed in the system's red, wholly outside the area so the frame is never part of what it frames.
final class AreaFrameView: NSView {
    var area: CGRect = .zero {
        didSet { updatePath() }
    }

    private let frameLine = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        frameLine.fillColor = nil
        frameLine.lineWidth = AreaOutline.redFrameWidth
        frameLine.strokeColor = NSColor.systemRed.cgColor
        layer?.addSublayer(frameLine)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        frameLine.frame = bounds
        updatePath()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        frameLine.contentsScale = window?.backingScaleFactor ?? 2
    }

    private func updatePath() {
        // The line is centered on its path, so the path lies half its width outside the area.
        frameLine.path = CGPath(rect: area.insetBy(dx: -AreaOutline.redFrameWidth / 2, dy: -AreaOutline.redFrameWidth / 2), transform: nil)
    }
}
