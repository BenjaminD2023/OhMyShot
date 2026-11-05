import AppKit

/// A button cell that puts the optical middle of an image shown alone (what the symbol draws, not its padded frame) on
/// the middle of the button, for round chips whose highlight shows where the middle is. The stock cell rounds the
/// image's origin down to whole points, and a symbol's frame is not centered on its ink: `square.and.arrow.down`'s tray
/// sits almost a point below the middle of its frame. With a title beside the image, the stock layout keeps where each
/// goes across, but up and down each is put on the button's middle by its ink: the stock layout set the Record chip's
/// dot half a point low and its title, by its font's line, a point and a half low.
@MainActor
public final class CenteredImageCell: NSButtonCell {
    /// How far the ink's optical middle lies from the image frame's, in points, y down, by the backing scale it was
    /// measured at: a symbol snaps its outline to the pixels it is drawn on, so its ink sits differently at each scale.
    private var inkOffsets: [CGFloat: CGPoint] = [:]
    /// The title's ink middle as `inkOffsets` keeps the image's, by the title it was measured for.
    private var titleInkOffsets: [CGFloat: (title: NSAttributedString, flipped: Bool, offset: CGFloat)] = [:]

    override public var image: NSImage? {
        get { super.image }
        set {
            super.image = newValue
            inkOffsets = [:]
        }
    }

    /// The ink's offset as it is drawn on the control's screen.
    private func inkOffset(of image: NSImage) -> CGPoint {
        let scale = controlView?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if let offset = inkOffsets[scale] { return offset }
        let offset = Self.inkOffset(of: image, scale: scale)
        inkOffsets[scale] = offset
        return offset
    }

    /// A symbol is drawn into its frame in the button's tint: the stock drawing places a symbol in the frame by its
    /// own measures, which left `square.and.arrow.down` over a point low in a frame centered on its ink.
    override public func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        if Self.besideTitle.contains(imagePosition), !image.isTemplate, image.size.height > 0 {
            // Drawn at its own size, across where the stock layout put it: the stock frame squashes a symbol's.
            let size = image.size
            let inkOffset = inkOffset(of: image)
            let bounds = controlView.bounds
            let placed = controlView.backingAlignedRect(NSRect(
                x: frame.midX - size.width / 2,
                y: bounds.midY - size.height / 2 + (controlView.isFlipped ? -inkOffset.y : inkOffset.y),
                width: size.width,
                height: size.height
            ), options: .alignAllEdgesNearest)
            image.draw(in: placed, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.35, respectFlipped: true, hints: nil)
            return
        }
        guard imagePosition == .imageOnly, image.isTemplate else {
            return super.drawImage(image, withFrame: frame, in: controlView)
        }
        let tint = (controlView as? NSButton)?.contentTintColor ?? .labelColor
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: frame, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.35, respectFlipped: true, hints: nil)
    }

    /// Where an image sits beside the title, on the same line.
    private static let besideTitle: Set<NSControl.ImagePosition> = [.imageLeading, .imageTrailing, .imageLeft, .imageRight]

    /// A title on the line is drawn with its ink on the button's middle, across where the stock layout put it.
    override public func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        guard Self.besideTitle.contains(imagePosition) || imagePosition == .noImage, title.length > 0 else {
            return super.drawTitle(title, withFrame: frame, in: controlView)
        }
        let height = ceil(title.size().height)
        let inkMiddle = titleInkMiddle(of: title, height: height)
        let bounds = controlView.bounds
        let top = controlView.isFlipped ? bounds.midY - inkMiddle : bounds.midY + inkMiddle - height
        let rect = controlView.backingAlignedRect(
            NSRect(x: frame.minX, y: top, width: frame.width, height: height), options: .alignAllEdgesNearest
        )
        let drawn: NSAttributedString
        if isEnabled {
            drawn = title
        } else {
            let dimmed = NSMutableAttributedString(attributedString: title)
            dimmed.addAttribute(.foregroundColor, value: NSColor.disabledControlTextColor, range: NSRange(location: 0, length: dimmed.length))
            drawn = dimmed
        }
        drawn.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return rect
    }

    /// How far down from the top of its line the title's ink has its middle, in points, as drawn on the control's screen.
    private func titleInkMiddle(of title: NSAttributedString, height: CGFloat) -> CGFloat {
        let scale = controlView?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let flipped = controlView?.isFlipped ?? false
        if let kept = titleInkOffsets[scale], kept.title == title, kept.flipped == flipped { return kept.offset }
        let middle = Self.inkMiddle(of: title, height: height, scale: scale, flipped: flipped)
        titleInkOffsets[scale] = (title, flipped, middle)
        return middle
    }

    /// Draws `title` and finds the middle of its ink's bounds (the pixels at least a third opaque), down from its top. Laid
    /// out as the control lays it out, flipped or not: the same rect puts a line's ink a point apart in the two.
    private static func inkMiddle(of title: NSAttributedString, height: CGFloat, scale backingScale: CGFloat, flipped: Bool) -> CGFloat {
        let scale = max(1, Int(backingScale.rounded()))
        let size = NSSize(width: ceil(title.size().width) + 2, height: height)
        let width = Int(size.width) * scale, pixelsHigh = Int(size.height) * scale
        guard width > 0, pixelsHigh > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let data = rep.bitmapData else { return height / 2 }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return height / 2
        }
        if flipped {
            // Its top on the bitmap's first row, as the control's top is.
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
        }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: flipped)
        // Opaque ink whatever its color, so a light title is measured as a dark one is.
        let ink = NSMutableAttributedString(attributedString: title)
        ink.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: ink.length))
        ink.draw(with: NSRect(origin: .zero, size: size), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        var minY = pixelsHigh, maxY = -1
        for y in 0..<pixelsHigh {
            for x in 0..<width where data[y * rep.bytesPerRow + x * 4 + 3] > 85 {
                minY = min(minY, y); maxY = max(maxY, y)
                break
            }
        }
        guard maxY >= 0 else { return height / 2 }
        return CGFloat(minY + maxY + 1) / 2 / CGFloat(scale)
    }

    override public func imageRect(forBounds rect: NSRect) -> NSRect {
        guard imagePosition == .imageOnly, let image, image.size.width > 0, image.size.height > 0 else {
            return super.imageRect(forBounds: rect)
        }
        let size = image.size
        let inkOffset = inkOffset(of: image)
        let flipped = controlView?.isFlipped ?? false
        // The control's whole bounds, as the highlight fills them: `rect` can be the cell's inset drawing rect.
        let bounds = controlView?.bounds ?? rect
        let frame = NSRect(
            x: bounds.midX - size.width / 2 - inkOffset.x,
            y: bounds.midY - size.height / 2 + (flipped ? -inkOffset.y : inkOffset.y),
            width: size.width,
            height: size.height
        )
        // On the backing's pixels, so the symbol is not drawn blurred between them.
        return controlView?.backingAlignedRect(frame, options: .alignAllEdgesNearest) ?? frame
    }

    /// Draws `image` at the backing scale it is shown at and finds its optical middle: halfway between the middle of its
    /// ink's bounds (the pixels at least a third opaque) and its ink's center of weight. Centered on its bounds alone, a
    /// lopsided symbol looks off: `square.and.arrow.down`'s tray left it looking low, by its weight 1.5 pt below the
    /// middle of its bounds, and `pin`'s head left it looking high. At any other scale the measure misses where the ink
    /// lands: at 4× `1.circle`'s ink is centered within a quarter point, at the 2× it is drawn at it lies half a point
    /// left, and the rail showed its circle off the chip's middle.
    private static func inkOffset(of image: NSImage, scale backingScale: CGFloat) -> CGPoint {
        let size = image.size
        let scale = max(1, Int(backingScale.rounded()))
        let width = Int(ceil(size.width)) * scale, height = Int(ceil(size.height)) * scale
        guard width > 0, height > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let data = rep.bitmapData else { return .zero }
        rep.size = NSSize(width: ceil(size.width), height: ceil(size.height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        var minX = width, maxX = -1, minY = height, maxY = -1
        var weight: CGFloat = 0, weightX: CGFloat = 0, weightY: CGFloat = 0
        for y in 0..<height {
            for x in 0..<width {
                let alpha = data[y * rep.bytesPerRow + x * 4 + 3]
                guard alpha > 0 else { continue }
                let a = CGFloat(alpha)
                weight += a; weightX += a * (CGFloat(x) + 0.5); weightY += a * (CGFloat(y) + 0.5)
                if alpha > 85 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= 0, weight > 0 else { return .zero }
        let pixel = CGFloat(scale)
        let boundsMiddle = CGPoint(x: CGFloat(minX + maxX + 1) / 2, y: CGFloat(minY + maxY + 1) / 2)
        let center = CGPoint(x: weightX / weight, y: weightY / weight)
        return CGPoint(
            x: (boundsMiddle.x + center.x) / 2 / pixel - size.width / 2,
            y: (boundsMiddle.y + center.y) / 2 / pixel - size.height / 2
        )
    }
}
