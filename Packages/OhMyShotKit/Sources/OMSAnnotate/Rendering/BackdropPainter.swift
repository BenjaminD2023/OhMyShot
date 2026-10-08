import Accelerate
import CoreGraphics
import Foundation

/// Draws backgrounds: the fill behind everything, and the soft shadow under the capture. The canvas
/// and exports both draw through here.
nonisolated enum BackdropPainter {
    /// Fills `rect` (y-down user space) with `fill`. `blur` is the blurred capture a `.blur` fill shows
    /// (`blurredCapture`), made once by the caller; `resolution` is how many pixels of the destination
    /// each unit of `rect` covers, so a picture is read no larger than it shows.
    static func paint(_ fill: Backdrop.Fill, in rect: CGRect, context: CGContext, blur: CGImage?, resolution: CGFloat = 1) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        switch fill {
        case .clear:
            return
        case .color(let color):
            context.setFillColor(color.withAlpha(1).cgColor)
            context.fill(rect)
        case .gradient(let gradient):
            gradient.recipe.draw(in: rect, context: context)
        case .blur:
            guard let blur else {
                BackdropGradient.paper.recipe.draw(in: rect, context: context)
                return
            }
            context.interpolationQuality = .high
            AnnotationRenderer.drawImage(blur, in: aspectFill(CGSize(width: blur.width, height: blur.height), in: rect), context: context)
        case .picture(let name):
            let longest = Int((max(rect.width, rect.height) * resolution).rounded(.up))
            guard let picture = PictureStore.shared.image(named: name, fitting: longest, limit: PictureStore.backgroundLimit) else {
                // The picture has gone from the folder: the default gradient stands in.
                BackdropGradient.sky.recipe.draw(in: rect, context: context)
                return
            }
            context.interpolationQuality = .high
            AnnotationRenderer.drawImage(picture, in: aspectFill(CGSize(width: picture.width, height: picture.height), in: rect), context: context)
        }
    }

    /// The soft shadow under the card, without the card: the card is drawn over it, and a card with clear
    /// room in it must not show the shadow through. `strength` runs from 0 to 1; sizes are in the
    /// context's user space (the document's pixels, y down).
    ///
    /// The shadow is the card's shape blurred at a fraction of its size and drawn back up: a blur that
    /// wide hides the difference, and a 6K picture's shadow costs milliseconds instead of a large blur.
    static func drawCardShadow(_ layout: BackdropLayout, strength: CGFloat, scale: CGFloat, context: CGContext) {
        guard !layout.isBare, strength > 0, let shadow = shadowMask(for: layout, strength: strength, scale: scale) else { return }
        let path = CGPath(roundedRect: layout.card, cornerWidth: layout.cornerRadius, cornerHeight: layout.cornerRadius, transform: nil)
        context.saveGState()
        // Everywhere but the card itself.
        context.addRect(shadow.rect.union(layout.card).insetBy(dx: -1, dy: -1))
        context.addPath(path)
        context.clip(using: .evenOdd)
        // The mask is drawn y up, as images are; the context is y down.
        context.translateBy(x: 0, y: shadow.rect.minY + shadow.rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: shadow.rect, mask: shadow.mask)
        context.setFillColor(CGColor(gray: 0, alpha: shadow.opacity))
        context.fill(shadow.rect)
        context.restoreGState()
    }

    /// The shadow's mask and where it goes. A short drop and a wide blur at every strength, deepening
    /// together: never a hard edge.
    static func shadowMask(for layout: BackdropLayout, strength: CGFloat, scale: CGFloat) -> (mask: CGImage, rect: CGRect, opacity: CGFloat)? {
        let blur = (8 + 32 * strength) * scale
        let drop = (2 + 10 * strength) * scale
        let opacity = 0.14 + 0.30 * strength
        // Three box passes as wide as the blur spread like a Gaussian of half its width; reduced so the
        // boxes are about 6 pixels.
        let reduction = max(blur / 6, 1)
        let margin = blur * 1.5
        let rect = layout.card.offsetBy(dx: 0, dy: drop).insetBy(dx: -margin, dy: -margin)
        let width = max(Int((rect.width / reduction).rounded(.up)), 1)
        let height = max(Int((rect.height / reduction).rounded(.up)), 1)
        let rowBytes = (width + 15) & ~15
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        var scratch = [UInt8](repeating: 0, count: rowBytes * height)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            let card = CGRect(
                x: margin / reduction, y: margin / reduction,
                width: layout.card.width / reduction, height: layout.card.height / reduction
            )
            let radius = min(layout.cornerRadius / reduction, min(card.width, card.height) / 2)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
            return true
        }
        guard drawn else { return nil }
        let box = UInt32(max(Int((blur / reduction).rounded()), 1) | 1)
        for _ in 0..<3 {
            let error = bytes.withUnsafeMutableBytes { input in
                scratch.withUnsafeMutableBytes { output in
                    var source = vImage_Buffer(data: input.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
                    var destination = vImage_Buffer(data: output.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
                    return vImageBoxConvolve_Planar8(&source, &destination, nil, 0, 0, box, box, 0, vImage_Flags(kvImageEdgeExtend))
                }
            }
            guard error == kvImageNoError else { return nil }
            swap(&bytes, &scratch)
        }
        guard
            let provider = CGDataProvider(data: Data(bytes) as CFData),
            let mask = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        else { return nil }
        return (mask, rect, opacity)
    }

    /// The capture's canvas, small and blurred until only its colors are left, for a `.blur` fill. A
    /// tiny picture scaled up smoothly is as soft as a large blur at a fraction of the work.
    static func blurredCapture(_ base: CGImage, canvas: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let region = canvas.standardized.integral.intersection(bounds)
        guard !region.isNull, region.width >= 1, region.height >= 1, let cropped = base.cropping(to: region) else { return nil }
        let longest: CGFloat = 48
        let factor = min(longest / max(region.width, region.height), 1)
        let width = max(Int((region.width * factor).rounded()), 1)
        let height = max(Int((region.height * factor).rounded()), 1)
        let space = base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var small = Bitmap(width: width, height: height, colorSpace: space)
        let drawn = small.bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: small.rowBytes,
                space: space, bitmapInfo: Bitmap.bitmapInfo
            ) else { return false }
            context.interpolationQuality = .high
            // Opaque underneath, so a window's clear surroundings do not darken the blur.
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var scratch = Bitmap(width: width, height: height, colorSpace: space)
        let box: UInt32 = 5
        for _ in 0..<3 {
            let error = small.withBuffer { input in
                scratch.withBuffer { output in
                    vImageBoxConvolve_ARGB8888(&input, &output, nil, 0, 0, box, box, nil, vImage_Flags(kvImageEdgeExtend))
                }
            }
            guard error == kvImageNoError else { return nil }
            swap(&small, &scratch)
        }
        return small.makeImage()
    }

    /// `size` scaled to cover `rect`, centered on it.
    static func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let factor = max(rect.width / size.width, rect.height / size.height)
        let width = size.width * factor
        let height = size.height * factor
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}

/// How a built-in gradient is drawn: a soft linear blend corner to corner, and glows of light laid over
/// it, as in a desktop picture.
nonisolated struct GradientRecipe {
    struct Glow {
        /// In the rect's unit square, y down.
        var center: CGPoint
        /// As a fraction of the rect's longer side.
        var radius: CGFloat
        var color: RGBA
    }

    var from: RGBA
    var to: RGBA
    /// The blend runs from `start` to `end`, in the rect's unit square, y down.
    var start = CGPoint(x: 0, y: 0)
    var end = CGPoint(x: 1, y: 1)
    var glows: [Glow] = []

    func draw(in rect: CGRect, context: CGContext) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func point(_ unit: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + unit.x * rect.width, y: rect.minY + unit.y * rect.height)
        }
        if let gradient = CGGradient(colorsSpace: space, colors: [from.cgColor, to.cgColor] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: point(start), end: point(end), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let longest = max(rect.width, rect.height)
        for glow in glows {
            guard let gradient = CGGradient(
                colorsSpace: space, colors: [glow.color.cgColor, glow.color.withAlpha(glow.color.alpha * 0.45).cgColor, glow.color.withAlpha(0).cgColor] as CFArray,
                locations: [0, 0.45, 1]
            ) else { continue }
            let center = point(glow.center)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: glow.radius * longest, options: [])
        }
    }
}

nonisolated extension BackdropGradient {
    var recipe: GradientRecipe {
        func hex(_ value: UInt32, _ alpha: Double = 1) -> RGBA {
            RGBA(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255, alpha: alpha)
        }
        switch self {
        case .sky:
            return GradientRecipe(from: hex(0x9CC8FA), to: hex(0xD9C6FA), glows: [
                .init(center: CGPoint(x: 0.12, y: 0.08), radius: 0.62, color: hex(0xFFFFFF, 0.42)),
                .init(center: CGPoint(x: 0.92, y: 0.95), radius: 0.7, color: hex(0xB4A2F7, 0.5)),
            ])
        case .lilac:
            return GradientRecipe(from: hex(0xA996DC), to: hex(0xF6C5E6), glows: [
                .init(center: CGPoint(x: 0.85, y: 0.12), radius: 0.6, color: hex(0xFFE0F0, 0.5)),
                .init(center: CGPoint(x: 0.1, y: 0.9), radius: 0.65, color: hex(0x8E7CD6, 0.45)),
            ])
        case .rose:
            return GradientRecipe(from: hex(0xFFA6A9), to: hex(0xFDD6EC), glows: [
                .init(center: CGPoint(x: 0.1, y: 0.15), radius: 0.6, color: hex(0xFFD1B0, 0.5)),
                .init(center: CGPoint(x: 0.9, y: 0.85), radius: 0.6, color: hex(0xF79CC4, 0.45)),
            ])
        case .peach:
            return GradientRecipe(from: hex(0xFFE3C2), to: hex(0xFFA488), glows: [
                .init(center: CGPoint(x: 0.88, y: 0.1), radius: 0.6, color: hex(0xFFF3DC, 0.55)),
                .init(center: CGPoint(x: 0.15, y: 0.92), radius: 0.62, color: hex(0xFF8A80, 0.4)),
            ])
        case .citrus:
            return GradientRecipe(from: hex(0xF9DB72), to: hex(0xFCA982), glows: [
                .init(center: CGPoint(x: 0.1, y: 0.1), radius: 0.62, color: hex(0xFFF6C4, 0.55)),
                .init(center: CGPoint(x: 0.92, y: 0.9), radius: 0.62, color: hex(0xFF9473, 0.42)),
            ])
        case .mint:
            return GradientRecipe(from: hex(0xCFF5DE), to: hex(0x5ACFC2), glows: [
                .init(center: CGPoint(x: 0.12, y: 0.1), radius: 0.62, color: hex(0xF4FFE6, 0.5)),
                .init(center: CGPoint(x: 0.9, y: 0.92), radius: 0.6, color: hex(0x39B8B5, 0.4)),
            ])
        case .ocean:
            return GradientRecipe(from: hex(0x5E9CF5), to: hex(0x37CDBE), glows: [
                .init(center: CGPoint(x: 0.88, y: 0.1), radius: 0.62, color: hex(0x9FD8FF, 0.45)),
                .init(center: CGPoint(x: 0.12, y: 0.9), radius: 0.62, color: hex(0x3C63D9, 0.42)),
            ])
        case .dusk:
            return GradientRecipe(from: hex(0x464FBF), to: hex(0xC07BE8), glows: [
                .init(center: CGPoint(x: 0.9, y: 0.88), radius: 0.62, color: hex(0xF29AC8, 0.42)),
                .init(center: CGPoint(x: 0.1, y: 0.1), radius: 0.6, color: hex(0x2E3591, 0.45)),
            ])
        case .graphite:
            return GradientRecipe(from: hex(0x4A4E57), to: hex(0x1E2024), glows: [
                .init(center: CGPoint(x: 0.15, y: 0.1), radius: 0.7, color: hex(0x7A808C, 0.35)),
            ])
        case .paper:
            return GradientRecipe(from: hex(0xFBFBFC), to: hex(0xE6E7EC), glows: [
                .init(center: CGPoint(x: 0.85, y: 0.1), radius: 0.6, color: hex(0xFFFFFF, 0.6)),
            ])
        }
    }

    /// Whether the gradient is dark, so what is drawn over it should be light.
    public var isDark: Bool {
        switch self {
        case .dusk, .graphite: true
        default: false
        }
    }
}
