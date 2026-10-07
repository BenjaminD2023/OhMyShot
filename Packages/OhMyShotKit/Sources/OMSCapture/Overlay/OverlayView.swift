import AppKit
import CoreGraphics
import OMSCore
import QuartzCore

protocol OverlayViewDelegate: AnyObject {
    func overlayView(_ view: OverlayView, didSelect rect: CGRect, modifiers: NSEvent.ModifierFlags)
    func overlayView(_ view: OverlayView, didSelectWindow target: WindowTarget, modifiers: NSEvent.ModifierFlags)
    func overlayView(_ view: OverlayView, didSwitchTo mode: OverlayView.Mode)
    func overlayViewDidCancel(_ view: OverlayView)
}

/// The capture overlay on one display: a lightly dimmed screen, the selection with its size, a small
/// crosshair, a magnifier for exact placement, and the All-In-One bar.
///
/// Everything is a layer whose geometry changes on input, with implicit animations off, so the overlay
/// never trails the pointer.
final class OverlayView: NSView {
    enum Mode: Sendable {
        /// Drag out a region.
        case area
        /// Click a window; the selection snaps to whichever window is under the pointer.
        case window
    }

    weak var delegate: OverlayViewDelegate?
    let display: DisplayInfo

    private(set) var mode: Mode = .area
    private var windows: [WindowTarget] = []
    private var hoveredWindow: WindowTarget?
    private var selection: SelectionModel
    private var capturedFrame: CapturedFrame?
    private var spaceHeld = false
    private var lastDragPoint: CGPoint?
    private var pointer: CGPoint?
    /// Set by `simulate`, so the real (hidden) pointer cannot move a scripted render.
    private var isSimulated = false
    private var increasedContrast = false

    private let backdrop = CALayer()
    private let room = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let border = CAShapeLayer()
    private let sizePill = Pill()
    private let crosshairOutline = CAShapeLayer()
    private let crosshair = CAShapeLayer()
    private let loupeShadow = CAShapeLayer()
    private let loupe = CALayer()
    private let loupeImage = CALayer()
    private let loupeGrid = CAShapeLayer()
    private let loupeCenter = CAShapeLayer()
    private let loupeRim = CAShapeLayer()
    private let loupePill = Pill(showsSwatch: true)
    private let toolbar = AllInOneBar()
    /// Copying text gets a lighter overlay than a screenshot: no dimming, no magnifier or readings, the
    /// system crosshair, and a selection drawn like selected text.
    private var purpose: OverlayController.Purpose = .screenshot

    init(display: DisplayInfo) {
        self.display = display
        selection = SelectionModel(bounds: display.frame, pixelsPerPoint: display.pixelsPerPoint)
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
        let root = CALayer()
        root.contentsScale = display.backingScale
        layer = root
        wantsLayer = true
        buildLayers()
        toolbar.onSelect = { [weak self] choice in self?.toolbarChose(choice) }
        toolbar.isHidden = true
        addSubview(toolbar)
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel(String(localized: "Capture overlay"))
        setAccessibilityHelp(String(localized: "Drag to capture an area. Press Space to capture a window instead. Press Escape to cancel."))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - State

    /// Starts a fresh session with the pointer at `globalPointer`. The All-In-One bar shows only on the
    /// display where the session started.
    func reset(pointer globalPointer: CGPoint, mode: Mode, windows: [WindowTarget], showsToolbar: Bool, purpose: OverlayController.Purpose = .screenshot) {
        self.mode = mode
        self.windows = windows
        hoveredWindow = nil
        selection.reset()
        spaceHeld = false
        lastDragPoint = nil
        isSimulated = false
        capturedFrame = nil
        increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        self.purpose = purpose
        // The bar first: the size reading below steers clear of it.
        toolbar.isHidden = !showsToolbar
        toolbar.alphaValue = 1
        toolbar.select(mode == .area ? .area : .window)
        layoutToolbar()
        window?.invalidateCursorRects(for: self)
        setAccessibilityHelp(purpose == .text
            ? String(localized: "Drag over text to copy it. Press Space to choose a window instead. Press Escape to cancel.")
            : String(localized: "Drag to capture an area. Press Space to capture a window instead. Press Escape to cancel."))
        withoutAnimation {
            applyAppearance()
            backdrop.contents = nil
            loupeImage.contents = nil
            updateSelectionLayers()
            updatePointer(display.frame.contains(globalPointer) ? local(globalPointer) : nil)
        }
    }

    /// Hands the view this display's captured frame, which the magnifier enlarges. In freeze mode the
    /// frame also becomes the backdrop, so the screen holds still while selecting.
    func show(_ frame: CapturedFrame, frozen: Bool) {
        capturedFrame = frame
        withoutAnimation {
            backdrop.contents = frozen ? frame.image : nil
            loupeImage.contents = frame.image
            updatePointer(pointer)
        }
    }

    /// Switches between dragging a region and clicking a window, keeping the pointer where it is.
    func switchMode(to mode: Mode, windows: [WindowTarget]) {
        self.mode = mode
        self.windows = windows
        hoveredWindow = nil
        selection.reset()
        toolbar.select(mode == .area ? .area : .window)
        withoutAnimation {
            updateSelectionLayers()
            updatePointer(pointer)
        }
    }

    /// Drops the frame so its memory is released while the overlay is hidden.
    func clear() {
        capturedFrame = nil
        withoutAnimation {
            backdrop.contents = nil
            loupeImage.contents = nil
        }
    }

    /// Shows a selection and pointer without mouse input, for scripted checks.
    func simulate(selection rect: CGRect, pointer globalPointer: CGPoint) {
        isSimulated = true
        selection.begin(at: CGPoint(x: rect.minX, y: rect.maxY))
        selection.drag(to: CGPoint(x: rect.maxX, y: rect.minY))
        withoutAnimation {
            updateSelectionLayers()
            updatePointer(local(globalPointer))
        }
    }

    override func layout() {
        super.layout()
        layoutToolbar()
    }

    /// Copying text keeps the system crosshair; a screenshot draws its own crosshair and magnifier.
    override func resetCursorRects() {
        super.resetCursorRects()
        if purpose == .text { addCursorRect(bounds, cursor: .crosshair) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withoutAnimation { applyAppearance() }
    }

    // MARK: - Input

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        if purpose == .text { NSCursor.crosshair.set() }
        guard !isSimulated else { return }
        withoutAnimation { updatePointer(convert(event.locationInWindow, from: nil)) }
    }

    override func mouseEntered(with event: NSEvent) {
        // Cursor rects only work in the key panel; on other displays the crosshair is set here.
        if purpose == .text { NSCursor.crosshair.set() }
        guard !isSimulated else { return }
        withoutAnimation { updatePointer(convert(event.locationInWindow, from: nil)) }
    }

    /// The text selection's edge: 1 pt, or 2 pt with Increase Contrast so it holds over blue content.
    static func textSelectionEdge(increasedContrast: Bool) -> CGFloat {
        increasedContrast ? 2 : 1
    }

    override func mouseExited(with event: NSEvent) {
        guard !isSimulated else { return }
        withoutAnimation { updatePointer(nil) }
    }

    override func mouseDown(with event: NSEvent) {
        guard mode == .area else { return }
        let point = global(convert(event.locationInWindow, from: nil))
        selection.begin(at: point)
        lastDragPoint = point
        withoutAnimation { updateSelectionLayers() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        let point = global(localPoint)
        if spaceHeld, let last = lastDragPoint {
            selection.move(by: CGVector(dx: point.x - last.x, dy: point.y - last.y))
        } else {
            selection.drag(to: point, modifiers: modifiers(event.modifierFlags))
        }
        lastDragPoint = point
        // The bar steps out of the way while a region is being dragged.
        if !toolbar.isHidden, selection.rect != nil { toolbar.alphaValue = 0 }
        withoutAnimation {
            updateSelectionLayers()
            updatePointer(localPoint)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if mode == .window {
            if let hoveredWindow { delegate?.overlayView(self, didSelectWindow: hoveredWindow, modifiers: event.modifierFlags) }
            return
        }
        lastDragPoint = nil
        toolbar.alphaValue = 1
        guard let rect = selection.rect, !selection.isTooSmall else {
            selection.reset()
            withoutAnimation { updateSelectionLayers() }
            return
        }
        delegate?.overlayView(self, didSelect: rect, modifiers: event.modifierFlags)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let last = lastDragPoint, !spaceHeld else { return }
        selection.drag(to: last, modifiers: modifiers(event.modifierFlags))
        withoutAnimation { updateSelectionLayers() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            delegate?.overlayViewDidCancel(self)
        case 49:
            // While dragging, Space moves the selection; before a drag it switches between capturing a
            // region and capturing a window, as in macOS's own screenshot tool.
            if lastDragPoint != nil {
                spaceHeld = true
            } else if !event.isARepeat {
                delegate?.overlayView(self, didSwitchTo: mode == .area ? .window : .area)
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false }
    }

    private func toolbarChose(_ choice: AllInOneBar.Choice) {
        switch choice {
        case .area where mode != .area:
            delegate?.overlayView(self, didSwitchTo: .area)
        case .window where mode != .window:
            delegate?.overlayView(self, didSwitchTo: .window)
        case .fullscreen:
            delegate?.overlayView(self, didSelect: display.frame, modifiers: [])
        case .cancel:
            delegate?.overlayViewDidCancel(self)
        default:
            break
        }
    }

    /// Shift keeps the selection square; Option grows it from the center, except when copying text,
    /// where Option means "open the OCR panel" when the mouse is released.
    private func modifiers(_ flags: NSEvent.ModifierFlags) -> SelectionModel.Modifiers {
        var modifiers: SelectionModel.Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.square) }
        if flags.contains(.option), purpose == .screenshot { modifiers.insert(.fromCenter) }
        return modifiers
    }

    // MARK: - Drawing

    private func buildLayers() {
        guard let root = layer else { return }
        backdrop.frame = bounds
        backdrop.contentsGravity = .resize
        backdrop.magnificationFilter = .nearest

        room.frame = bounds
        room.fillRule = .evenOdd

        for line in [outline, crosshairOutline] {
            line.lineWidth = Theme.Overlay.borderWidth + 2
            line.fillColor = nil
            line.lineJoin = .round
            line.lineCap = .round
        }
        for line in [border, crosshair] {
            line.strokeColor = .white
            line.lineWidth = Theme.Overlay.borderWidth
            line.fillColor = nil
            line.lineJoin = .round
            line.lineCap = .round
        }

        let diameter = Theme.Loupe.diameter
        let lensBounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        loupe.bounds = lensBounds
        loupe.cornerRadius = diameter / 2
        loupe.masksToBounds = true
        loupe.backgroundColor = .white
        loupeImage.frame = lensBounds
        loupeImage.magnificationFilter = .nearest
        loupeImage.contentsGravity = .resize
        loupeGrid.frame = lensBounds
        loupeGrid.strokeColor = CGColor(gray: 0, alpha: 0.08)
        loupeGrid.lineWidth = 1 / display.backingScale
        loupeGrid.path = Self.gridPath(size: diameter, cells: Theme.Loupe.pixelsAcross)
        let cell = diameter / CGFloat(Theme.Loupe.pixelsAcross)
        loupeCenter.frame = lensBounds
        loupeCenter.path = CGPath(
            roundedRect: CGRect(x: (diameter - cell) / 2, y: (diameter - cell) / 2, width: cell, height: cell),
            cornerWidth: 1.5, cornerHeight: 1.5, transform: nil
        )
        loupeCenter.fillColor = nil
        loupeCenter.lineWidth = 1.5
        loupe.addSublayer(loupeImage)
        loupe.addSublayer(loupeGrid)
        loupe.addSublayer(loupeCenter)

        // A soft shadow under the lens and a white rim around it, both outside the masked lens.
        loupeShadow.bounds = lensBounds
        loupeShadow.path = CGPath(ellipseIn: lensBounds, transform: nil)
        loupeShadow.fillColor = .white
        loupeShadow.shadowPath = loupeShadow.path
        loupeShadow.shadowOpacity = 0.28
        loupeShadow.shadowRadius = 12
        loupeShadow.shadowOffset = CGSize(width: 0, height: -4)
        loupeRim.bounds = lensBounds
        loupeRim.path = CGPath(ellipseIn: lensBounds.insetBy(dx: -Theme.Loupe.rimWidth / 2, dy: -Theme.Loupe.rimWidth / 2), transform: nil)
        loupeRim.strokeColor = .white
        loupeRim.fillColor = nil
        loupeRim.lineWidth = Theme.Loupe.rimWidth

        sizePill.setScale(display.backingScale)
        loupePill.setScale(display.backingScale)
        for sublayer in [backdrop, room, outline, border, crosshairOutline, crosshair, loupeShadow, loupe, loupeRim, sizePill.layer, loupePill.layer] {
            root.addSublayer(sublayer)
        }
        withoutAnimation {
            applyAppearance()
            updateSelectionLayers()
        }
    }

    /// Colors that depend on appearance or accessibility settings. Read when a session starts and when
    /// the appearance changes, never per event.
    private func applyAppearance() {
        let dimming = increasedContrast ? Theme.Overlay.dimmingIncreasedContrast : Theme.Overlay.dimming
        room.fillColor = CGColor(gray: 0, alpha: dimming)
        let outlineOpacity = increasedContrast ? Theme.Overlay.outlineOpacityIncreasedContrast : Theme.Overlay.outlineOpacity
        outline.strokeColor = CGColor(gray: 0, alpha: outlineOpacity)
        crosshairOutline.strokeColor = CGColor(gray: 0, alpha: outlineOpacity)
        loupeCenter.strokeColor = Theme.cgColor(.controlAccentColor, for: effectiveAppearance)
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        sizePill.applyAppearance(dark: isDark)
        loupePill.applyAppearance(dark: isDark)
        // Text: the selection reads as selected text (the system's selection color, lightly filled,
        // edged in the accent), over an undimmed screen. Screenshot: a white edge over a soft outline.
        let text = purpose == .text
        room.isHidden = text
        outline.isHidden = text
        border.lineWidth = text ? Self.textSelectionEdge(increasedContrast: increasedContrast) : Theme.Overlay.borderWidth
        border.strokeColor = text ? Theme.cgColor(.controlAccentColor, for: effectiveAppearance) : .white
        // Resolved for this appearance before the alpha is applied: applying it first fixes the
        // dynamic color to its light value.
        border.fillColor = text
            ? Theme.cgColor(.selectedTextBackgroundColor, for: effectiveAppearance).copy(alpha: isDark ? 0.45 : 0.35)
            : nil
    }

    private func updateSelectionLayers() {
        let roomPath = CGMutablePath()
        roomPath.addRect(bounds)
        let target = mode == .window ? hoveredWindow?.frame.intersection(display.frame) : selection.rect
        guard let globalRect = target, !globalRect.isNull, !globalRect.isEmpty else {
            room.path = roomPath
            outline.path = nil
            border.path = nil
            sizePill.layer.isHidden = true
            setAccessibilityValue(nil)
            return
        }
        let rect = local(globalRect)
        roomPath.addRect(rect)
        room.path = roomPath
        let edge = CGPath(rect: rect, transform: nil)
        let inset = Self.textSelectionEdge(increasedContrast: increasedContrast) / 2
        border.path = purpose == .text ? CGPath(rect: rect.integral.insetBy(dx: inset, dy: inset), transform: nil) : edge
        outline.path = edge

        let text: String
        if mode == .window, let hoveredWindow {
            let scale = display.pixelsPerPoint
            let width = Int((hoveredWindow.frame.width * scale).rounded())
            let height = Int((hoveredWindow.frame.height * scale).rounded())
            text = hoveredWindow.ownerName.isEmpty ? "\(width) × \(height)" : "\(hoveredWindow.ownerName)  ·  \(width) × \(height)"
        } else {
            let size = selection.pixelSize
            text = "\(size.width) × \(size.height)"
        }
        sizePill.text = text
        sizePill.layer.isHidden = purpose == .text
        // Text mode has no readings; a hovered window is named, without its size.
        setAccessibilityValue(purpose == .text ? (mode == .window ? hoveredWindow?.ownerName : nil) : text)
        // Centered under the selection; tucked inside when there is no room below, and lifted above the
        // All-In-One bar rather than covered by it (a window that fills the screen puts it right there).
        let pillSize = sizePill.layer.bounds.size
        var origin = CGPoint(x: rect.midX - pillSize.width / 2, y: rect.minY - pillSize.height - 10)
        if origin.y < 6 { origin.y = rect.minY + 10 }
        origin.x = max(6, min(origin.x, bounds.maxX - pillSize.width - 6))
        if !toolbar.isHidden, toolbar.alphaValue > 0,
           CGRect(origin: origin, size: pillSize).intersects(toolbar.frame.insetBy(dx: -8, dy: -8)) {
            origin.y = toolbar.frame.maxY + 10
        }
        sizePill.layer.frame.origin = origin
    }

    private func updatePointer(_ point: CGPoint?) {
        pointer = point
        let pointerLayers: [CALayer] = [crosshair, crosshairOutline, loupeShadow, loupe, loupeRim, loupePill.layer]
        if mode == .window {
            let hovered = point.flatMap { WindowCatalog.target(at: global($0), in: windows) }
            if hovered != hoveredWindow {
                hoveredWindow = hovered
                updateSelectionLayers()
            }
            pointerLayers.forEach { $0.isHidden = true }
            return
        }
        guard let point, purpose == .screenshot else {
            pointerLayers.forEach { $0.isHidden = true }
            return
        }
        let crosshairPath = Self.crosshairPath(at: point)
        crosshair.path = crosshairPath
        crosshairOutline.path = crosshairPath
        crosshair.isHidden = false
        crosshairOutline.isHidden = false

        // The magnifier sits below and right of the pointer, flipping away from the display's edges.
        let diameter = Theme.Loupe.diameter
        let offset = Theme.Loupe.offset
        var center = CGPoint(x: point.x + offset + diameter / 2, y: point.y - offset - diameter / 2)
        if center.x + diameter / 2 > bounds.maxX - 6 { center.x = point.x - offset - diameter / 2 }
        if center.y - diameter / 2 - 32 < bounds.minY + 6 { center.y = point.y + offset + diameter / 2 }
        for layer in [loupe, loupeRim, loupeShadow] { layer.position = center }

        let pixel = pixelCoordinate(at: point)
        if let frame = capturedFrame {
            loupeImage.contentsRect = Self.contentsRect(around: pixel, in: frame.image)
            let color = Self.color(at: pixel, in: frame.image)
            loupePill.swatch = color?.cgColor
            loupePill.text = color.map { "\(pixel.x), \(pixel.y)   \($0.hex)" } ?? "\(pixel.x), \(pixel.y)"
            for layer in [loupe, loupeRim, loupeShadow] { layer.isHidden = false }
        } else {
            loupePill.swatch = nil
            loupePill.text = "\(pixel.x), \(pixel.y)"
            for layer in [loupe, loupeRim, loupeShadow] { layer.isHidden = true }
        }
        loupePill.layer.isHidden = false
        let pillSize = loupePill.layer.bounds.size
        loupePill.layer.frame.origin = loupe.isHidden
            ? CGPoint(x: point.x + offset, y: point.y - offset - pillSize.height)
            : CGPoint(x: center.x - pillSize.width / 2, y: center.y - diameter / 2 - pillSize.height - 8)
    }

    private func layoutToolbar() {
        let size = toolbar.fittingSize
        toolbar.frame = CGRect(x: (bounds.width - size.width) / 2, y: 40, width: size.width, height: size.height)
    }

    /// The captured pixel under a point, counted from the display's top-left corner.
    private func pixelCoordinate(at point: CGPoint) -> (x: Int, y: Int) {
        let scale = display.pixelsPerPoint
        let x = Int((point.x * scale).rounded(.down))
        let y = Int(((bounds.height - point.y) * scale).rounded(.down))
        let maxX = Int(display.pixelSize.width) - 1, maxY = Int(display.pixelSize.height) - 1
        return (min(max(x, 0), maxX), min(max(y, 0), maxY))
    }

    /// The part of the frame the magnifier shows: `pixelsAcross` pixels centered on `pixel`. Layer
    /// contents are addressed bottom-up, so the row is flipped.
    private static func contentsRect(around pixel: (x: Int, y: Int), in image: CGImage) -> CGRect {
        let across = CGFloat(Theme.Loupe.pixelsAcross)
        let half = (across - 1) / 2
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let left = CGFloat(pixel.x) - half
        let bottom = height - CGFloat(pixel.y) - 1 - half
        return CGRect(x: left / width, y: bottom / height, width: across / width, height: across / height)
    }

    /// The pixel's color in sRGB. The frame is in the display's color space, so it is converted.
    private static func color(at pixel: (x: Int, y: Int), in image: CGImage) -> PixelColor? {
        guard
            let single = image.cropping(to: CGRect(x: pixel.x, y: pixel.y, width: 1, height: 1)),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(single, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return PixelColor(red: data[0], green: data[1], blue: data[2])
    }

    /// A small crosshair with a gap at the center so the target pixel stays visible.
    private static func crosshairPath(at point: CGPoint) -> CGPath {
        let path = CGMutablePath()
        let gap: CGFloat = 4, arm: CGFloat = 13
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            path.addLines(between: [
                CGPoint(x: point.x + dx * gap, y: point.y + dy * gap),
                CGPoint(x: point.x + dx * arm, y: point.y + dy * arm),
            ])
        }
        return path
    }

    private static func gridPath(size: CGFloat, cells: Int) -> CGPath {
        let path = CGMutablePath()
        let step = size / CGFloat(cells)
        for index in 1..<cells {
            let offset = CGFloat(index) * step
            path.addLines(between: [CGPoint(x: offset, y: 0), CGPoint(x: offset, y: size)])
            path.addLines(between: [CGPoint(x: 0, y: offset), CGPoint(x: size, y: offset)])
        }
        return path
    }

    // MARK: - Coordinates

    private func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - display.frame.minX, y: point.y - display.frame.minY)
    }

    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }

    private func global(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + display.frame.minX, y: point.y + display.frame.minY)
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

struct PixelColor {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var cgColor: CGColor { CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1) }
}

/// A rounded reading capsule with a soft shadow, sized to its text, optionally led by a color swatch.
final class Pill {
    let layer = CALayer()
    private let textLayer = CATextLayer()
    private let swatchLayer = CALayer()
    private let showsSwatch: Bool
    private let font = Theme.Typeface.reading()

    init(showsSwatch: Bool = false) {
        self.showsSwatch = showsSwatch
        textLayer.font = font
        textLayer.fontSize = font.pointSize
        textLayer.alignmentMode = .left
        layer.addSublayer(textLayer)
        swatchLayer.cornerRadius = 5
        swatchLayer.borderWidth = 1
        swatchLayer.isHidden = true
        layer.addSublayer(swatchLayer)
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: -2)
        layer.borderWidth = 0.5
        layer.isHidden = true
    }

    func setScale(_ scale: CGFloat) {
        layer.contentsScale = scale
        textLayer.contentsScale = scale
    }

    func applyAppearance(dark: Bool) {
        layer.backgroundColor = dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 0.94) : CGColor(gray: 1, alpha: 0.96)
        layer.borderColor = dark ? CGColor(gray: 1, alpha: 0.12) : CGColor(gray: 0, alpha: 0.08)
        textLayer.foregroundColor = dark ? CGColor(gray: 1, alpha: 0.92) : CGColor(gray: 0, alpha: 0.85)
        // Strong enough that a white or near-white sample still reads as a swatch on the white capsule.
        swatchLayer.borderColor = dark ? CGColor(gray: 1, alpha: 0.38) : CGColor(gray: 0, alpha: 0.3)
    }

    var swatch: CGColor? {
        didSet {
            swatchLayer.backgroundColor = swatch
            swatchLayer.isHidden = swatch == nil
            relayout()
        }
    }

    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            textLayer.string = text
            relayout()
        }
    }

    private func relayout() {
        let textHeight = ceil(font.ascender - font.descender)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let height = textHeight + 9
        let swatchWidth: CGFloat = showsSwatch && swatch != nil ? 16 : 0
        layer.bounds = CGRect(x: 0, y: 0, width: textWidth + 22 + swatchWidth, height: height)
        layer.cornerRadius = height / 2
        layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil)
        swatchLayer.frame = CGRect(x: 10, y: (height - 10) / 2, width: 10, height: 10)
        textLayer.frame = CGRect(x: 11 + swatchWidth, y: (height - textHeight) / 2 - 0.5, width: textWidth + 2, height: textHeight)
    }
}
