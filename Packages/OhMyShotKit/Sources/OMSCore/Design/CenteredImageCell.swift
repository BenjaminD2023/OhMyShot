import AppKit

/// A button cell that puts the optical middle of an image shown alone (what the symbol draws, not its padded frame) on
/// the middle of the button, for round chips whose highlight shows where the middle is. The stock cell rounds the
/// image's origin down to whole points, and a symbol's frame is not centered on its ink: `square.and.arrow.down`'s tray
/// sits almost a point below the middle of its frame. With a title, the stock layout and drawing stand.
@MainActor
public final class CenteredImageCell: NSButtonCell {
    /// How far the ink's optical middle lies from the image frame's, in points, y down.
    private var inkOffset = CGPoint.zero

    override public var image: NSImage? {
        get { super.image }
        set {
            super.image = newValue
            inkOffset = newValue.map(Self.inkOffset) ?? .zero
        }
    }

    /// A symbol is drawn into its frame in the button's tint: the stock drawing places a symbol in the frame by its
    /// own measures, which left `square.and.arrow.down` over a point low in a frame centered on its ink.
    override public func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
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

    override public func imageRect(forBounds rect: NSRect) -> NSRect {
        guard imagePosition == .imageOnly, let size = image?.size, size.width > 0, size.height > 0 else {
            return super.imageRect(forBounds: rect)
        }
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

    /// Draws `image` at 4× and finds its optical middle: halfway between the middle of its ink's bounds (the pixels at
    /// least a third opaque) and its ink's center of weight. Centered on its bounds alone, a lopsided symbol looks off:
    /// `square.and.arrow.down`'s tray left it looking low, by its weight 1.5 pt below the middle of its bounds, and
    /// `pin`'s head left it looking high.
    private static func inkOffset(of image: NSImage) -> CGPoint {
        let size = image.size
        let scale = 4
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
