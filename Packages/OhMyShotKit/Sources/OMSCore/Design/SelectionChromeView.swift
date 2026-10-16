import AppKit
import QuartzCore

/// What in-place annotation and the recording setup draw around their selection, never taking a click:
/// the screen dimmed around it, its frame as the capture overlay draws one (with the crop frame's thick
/// corners when it can be resized), thirds while it is adjusted, and its size in a reading capsule.
///
/// Vector layers, as the overlay's own selection is: the view covers the whole display, and a drawn
/// layer that size would hold tens of megabytes and redraw at every step of a drag.
@MainActor
public final class SelectionChromeView: NSView {
    private let room = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let edge = CAShapeLayer()
    private let thirds = CAShapeLayer()
    private let armsOutline = CAShapeLayer()
    private let arms = CAShapeLayer()
    private let readingLayer = CALayer()
    private let readingText = CATextLayer()
    private var displayOptions: NSObjectProtocol?

    public var selection: CGRect = .zero {
        didSet { if selection != oldValue { relayout() } }
    }
    public var reading = "" {
        didSet { if reading != oldValue { relayout() } }
    }
    public var showsThirds = false {
        didSet { if showsThirds != oldValue { relayout() } }
    }
    /// The corners' thick arms, which say the frame can be resized.
    public var showsHandles = true {
        didSet { if showsHandles != oldValue { relayout() } }
    }
    /// The toolbar and the capsule, which the reading must not cover.
    public var avoiding: CGRect = .null {
        didSet { if avoiding != oldValue { relayout() } }
    }
    /// The toolbar alone: a reading with no room at the selection sits on its row.
    public var toolbarFrame: CGRect = .null {
        didSet { if toolbarFrame != oldValue { relayout() } }
    }

    /// How far the frame's corners reach past its edge, which stays on screen where the selection meets
    /// the display's edge.
    public static let reach: CGFloat = 4.5

    /// The frame as drawn: the selection, stepped in by `reach` on every side that meets `bounds`.
    public static func drawnFrame(for selection: CGRect, in bounds: CGRect) -> CGRect {
        var frame = selection
        if selection.minX - bounds.minX < reach { frame.origin.x += reach; frame.size.width -= reach }
        if bounds.maxX - selection.maxX < reach { frame.size.width -= reach }
        if selection.minY - bounds.minY < reach { frame.origin.y += reach; frame.size.height -= reach }
        if bounds.maxY - selection.maxY < reach { frame.size.height -= reach }
        return frame
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        room.fillRule = .evenOdd
        for line in [outline, edge, thirds] {
            line.fillColor = nil
        }
        outline.lineWidth = 3.5
        edge.lineWidth = Theme.Overlay.borderWidth
        edge.strokeColor = .white
        thirds.lineWidth = 0.5
        thirds.strokeColor = CGColor(gray: 1, alpha: 0.6)
        for line in [armsOutline, arms] {
            line.fillColor = nil
            line.lineCap = .round
            line.lineJoin = .round
        }
        armsOutline.lineWidth = 5.5
        arms.lineWidth = 3
        arms.strokeColor = .white
        readingLayer.addSublayer(readingText)
        readingLayer.shadowOpacity = 0.18
        readingLayer.shadowRadius = 8
        readingLayer.shadowOffset = CGSize(width: 0, height: -2)
        let font = Theme.Typeface.reading()
        readingText.font = font
        readingText.fontSize = font.pointSize
        readingText.alignmentMode = .center
        for sublayer in [room, outline, edge, thirds, armsOutline, arms, readingLayer] {
            layer?.addSublayer(sublayer)
        }
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
    }

    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
        displayOptions = nil
        let scale = window?.backingScaleFactor ?? 2
        for layer in [room, outline, edge, thirds, armsOutline, arms, readingLayer, readingText] { layer.contentsScale = scale }
        guard window != nil else { return }
        displayOptions = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAppearance() }
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    public override func layout() {
        super.layout()
        relayout()
    }

    /// The overlay's dimming and outline (45% and 0.7 under Increase Contrast), and the reading capsule's
    /// materials with the contrast hairline.
    private func applyAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        room.fillColor = CGColor(gray: 0, alpha: contrast ? Theme.Overlay.dimmingIncreasedContrast : Theme.Overlay.dimming)
        let line = CGColor(gray: 0, alpha: contrast ? Theme.Overlay.outlineOpacityIncreasedContrast : Theme.Overlay.outlineOpacity)
        outline.strokeColor = line
        armsOutline.strokeColor = line
        readingLayer.backgroundColor = dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 0.94) : CGColor(gray: 1, alpha: 0.96)
        readingLayer.borderWidth = contrast ? 1 : 0.5
        readingLayer.borderColor = dark ? CGColor(gray: 1, alpha: contrast ? 0.5 : 0.12) : CGColor(gray: 0, alpha: contrast ? 0.35 : 0.08)
        readingText.foregroundColor = dark ? CGColor(gray: 1, alpha: 0.92) : CGColor(gray: 0, alpha: 0.85)
        CATransaction.commit()
    }

    private func relayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for layer in [room, outline, edge, thirds, armsOutline, arms] { layer.frame = bounds }
        let rect = selection
        guard !rect.isEmpty else {
            for layer in [room, outline, edge, thirds, armsOutline, arms, readingLayer] { layer.isHidden = true }
            return
        }
        for layer in [room, outline, edge] { layer.isHidden = false }
        for layer in [armsOutline, arms] { layer.isHidden = !showsHandles }
        let dimmed = CGMutablePath()
        dimmed.addRect(bounds)
        dimmed.addRect(rect)
        room.path = dimmed

        // Where the selection meets the display's edge, the frame steps in, so its edge and corners stay
        // on screen to be seen and grabbed.
        let frame = Self.drawnFrame(for: rect, in: bounds)
        let edgePath = CGPath(rect: frame.insetBy(dx: -0.75, dy: -0.75), transform: nil)
        outline.path = edgePath
        edge.path = edgePath
        thirds.isHidden = !showsThirds
        if showsThirds {
            let lines = CGMutablePath()
            for index in 1...2 {
                let x = frame.minX + frame.width * CGFloat(index) / 3
                let y = frame.minY + frame.height * CGFloat(index) / 3
                lines.addLines(between: [CGPoint(x: x, y: frame.minY), CGPoint(x: x, y: frame.maxY)])
                lines.addLines(between: [CGPoint(x: frame.minX, y: y), CGPoint(x: frame.maxX, y: y)])
            }
            thirds.path = lines
        }
        let arm = max(min(18, frame.width / 3, frame.height / 3), 0)
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: frame.minX - 1.5, y: frame.minY - 1.5), 1, 1),
            (CGPoint(x: frame.maxX + 1.5, y: frame.minY - 1.5), -1, 1),
            (CGPoint(x: frame.maxX + 1.5, y: frame.maxY + 1.5), -1, -1),
            (CGPoint(x: frame.minX - 1.5, y: frame.maxY + 1.5), 1, -1),
        ]
        let armsPath = CGMutablePath()
        for (corner, dx, dy) in corners {
            armsPath.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
            armsPath.addLine(to: corner)
            armsPath.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        }
        armsOutline.path = armsPath
        arms.path = armsPath

        placeReading(around: rect)
    }

    /// Above the selection's top-left corner; inside it when that is covered or off screen; on the
    /// toolbar's row, left of it, when the selection is too small to hold it; else below the selection.
    private func placeReading(around rect: CGRect) {
        let font = Theme.Typeface.reading()
        let textHeight = ceil(font.ascender - font.descender)
        let size = CGSize(width: ceil((reading as NSString).size(withAttributes: [.font: font]).width) + 22, height: textHeight + 9)
        func fits(_ origin: CGPoint) -> Bool {
            let frame = CGRect(origin: origin, size: size)
            return bounds.insetBy(dx: 6, dy: 6).contains(frame) && (avoiding.isNull || !frame.intersects(avoiding.insetBy(dx: -6, dy: -6)))
        }
        var candidates = [CGPoint(x: rect.minX, y: rect.minY - size.height - 10)]
        if rect.width >= size.width + 16, rect.height >= size.height + 16 {
            candidates.append(CGPoint(x: rect.minX + 8, y: rect.minY + 8))
        }
        if !toolbarFrame.isNull {
            candidates.append(CGPoint(x: toolbarFrame.minX - 8 - size.width, y: toolbarFrame.midY - size.height / 2))
        }
        candidates.append(CGPoint(x: rect.minX, y: rect.maxY + 10))
        var origin = candidates.first(where: fits) ?? candidates[0]
        origin.x = min(max(origin.x, 6), bounds.maxX - size.width - 6)
        origin.y = min(max(origin.y, 6), bounds.maxY - size.height - 6)
        readingLayer.frame = CGRect(origin: origin, size: size).integral
        readingLayer.cornerRadius = size.height / 2
        readingLayer.shadowPath = CGPath(roundedRect: readingLayer.bounds, cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil)
        readingText.string = reading
        readingText.frame = CGRect(x: 0, y: (size.height - textHeight) / 2 - 0.5, width: size.width, height: textHeight)
        // No reading, no capsule: All-In-One shows the size in its bar's fields instead, but while the area is adjusted.
        readingLayer.isHidden = reading.isEmpty
    }
}
