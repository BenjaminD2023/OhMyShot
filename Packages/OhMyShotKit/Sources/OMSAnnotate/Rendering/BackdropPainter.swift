import Accelerate
import CoreGraphics
import Foundation
import OMSDesign

/// Draws backgrounds: the fill behind everything, and the soft shadow under the capture. The canvas
/// and exports both draw through here.
nonisolated enum BackdropPainter {
    struct Surface: Equatable {
        let fill: Backdrop.Fill
        let layout: BackdropLayout
        let shadow: CardShadow?
    }

    /// Only the material beneath the picture; never the capture, placed pictures, or earlier marks.
    struct Underlay: Equatable {
        struct Preview: Equatable {
            let resolution: CGFloat
            let zoom: CGFloat
            let light: CGColor
            let dark: CGColor
        }

        let surface: Surface?
        let blur: CGImage?
        let matte: CGColor?
        let canvas: CGRect
        var preview: Preview?

        func paint(in context: CGContext) {
            if let surface {
                if surface.fill == .clear, let preview {
                    BackdropPainter.drawChecker(over: surface.layout.output, preview: preview, in: context)
                }
                BackdropPainter.paint(surface.fill, in: surface.layout.output, context: context, blur: blur, resolution: preview?.resolution ?? 1)
                BackdropPainter.drawCardShadow(surface.layout, shadow: surface.shadow, context: context)
            }
            if let matte {
                context.setFillColor(matte)
                let radius = surface?.layout.cornerRadius ?? 0
                context.addPath(CGPath(roundedRect: surface?.layout.card ?? canvas, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            }
        }

        func clipToPicture(in context: CGContext) {
            guard let layout = surface?.layout else { return }
            if !layout.isBare {
                context.addPath(CGPath(roundedRect: layout.card, cornerWidth: layout.cornerRadius, cornerHeight: layout.cornerRadius, transform: nil))
                context.clip()
            }
            context.clip(to: layout.picture)
        }
    }

    private static func drawChecker(over output: CGRect, preview: Underlay.Preview, in context: CGContext) {
        let side = Theme.Checkerboard.square / max(preview.zoom, 0.0001)
        let shown = context.boundingBoxOfClipPath.intersection(output)
        guard !shown.isNull else { return }
        context.saveGState()
        context.setFillColor(preview.light)
        context.fill(shown)
        let firstColumn = Int(((shown.minX - output.minX) / side).rounded(.down))
        let firstRow = Int(((shown.minY - output.minY) / side).rounded(.down))
        let columns = Int((shown.width / side).rounded(.up)) + 1
        let rows = Int((shown.height / side).rounded(.up)) + 1
        let squares = CGMutablePath()
        for row in firstRow..<(firstRow + rows) {
            for column in firstColumn..<(firstColumn + columns) where (row + column).isMultiple(of: 2) {
                squares.addRect(CGRect(x: output.minX + CGFloat(column) * side, y: output.minY + CGFloat(row) * side, width: side, height: side))
            }
        }
        context.clip(to: shown)
        context.setFillColor(preview.dark)
        context.addPath(squares)
        context.fillPath()
        context.restoreGState()
    }

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
    /// room in it must not show the shadow through. Sizes are in the context's user space (the document's
    /// pixels, y down).
    ///
    /// The shadow is the card's shape blurred at a fraction of its size and drawn back up: a blur that
    /// wide hides the difference, and a 6K picture's shadow costs milliseconds instead of a large blur.
    static func drawCardShadow(_ layout: BackdropLayout, shadow cardShadow: CardShadow?, context: CGContext) {
        guard !layout.isBare, let cardShadow else { return }
        let inner = layout.card.insetBy(dx: layout.cornerRadius, dy: layout.cornerRadius)
        guard !inner.contains(context.boundingBoxOfClipPath), let shadow = shadowMask(for: layout, shadow: cardShadow) else { return }
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
        context.setFillColor(CGColor(gray: 0, alpha: cardShadow.opacity))
        context.fill(shadow.rect)
        context.restoreGState()
    }

    /// The shadow's mask and where it goes.
    static func shadowMask(for layout: BackdropLayout, shadow: CardShadow) -> (mask: CGImage, rect: CGRect)? {
        let blur = shadow.blur
        // Three box passes as wide as the blur spread like a Gaussian of half its width; reduced so the
        // boxes are about 6 pixels.
        let reduction = max(blur / 6, 1)
        let bounds = shadow.bounds(of: layout.card)
        let width = max(Int((bounds.width / reduction).rounded(.up)), 1)
        let height = max(Int((bounds.height / reduction).rounded(.up)), 1)
        // Whole pixels of the mask, so it is drawn back up at the scale it was made at and the shadow stays where
        // the card is: the room added past the shadow's reach is clear.
        let rect = CGRect(x: bounds.minX, y: bounds.minY, width: CGFloat(width) * reduction, height: CGFloat(height) * reduction)
        let rowBytes = (width + 15) & ~15
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        var scratch = [UInt8](repeating: 0, count: rowBytes * height)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            // Where the card's shadow falls, y up as the mask is drawn back.
            let cast = layout.card.offsetBy(dx: 0, dy: shadow.drop)
            let card = CGRect(
                x: (cast.minX - rect.minX) / reduction, y: (rect.maxY - cast.maxY) / reduction,
                width: cast.width / reduction, height: cast.height / reduction
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
        return (mask, rect)
    }

    /// The capture's canvas with its redactions on it, as they are drawn, and none of the other marks, small and blurred
    /// until only its colors are left, for a `.blur` fill: it carries nothing a redaction hides. A tiny picture scaled up
    /// smoothly is as soft as a large blur at a fraction of the work. `redactions` are the document's, in drawing order,
    /// with what each draws (`AnnotationDocument.redactionCovers`); `scale` is the document's.
    static func blurredCapture(
        _ base: CGImage, canvas: CGRect, redactions: [(item: Annotation, coverage: Redactor.Coverage?)], scale: CGFloat
    ) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        let region = canvas.standardized.integral.intersection(bounds)
        guard !region.isNull, region.width >= 1, region.height >= 1, var picture = base.cropping(to: region) else { return nil }
        let space = base.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let over = redactions.filter { $0.item.bounds(scale: scale).intersects(region) }
        if !over.isEmpty {
            // The redactions go on at the picture's own size, before it is made small: made small first, each small pixel
            // along a redaction's edge would keep some of what lies under it. No such picture, no blur, never one made
            // without them.
            guard let context = AnnotationRenderer.bitmapContext(for: region.size, space: space) else { return nil }
            context.translateBy(x: 0, y: region.height)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: -region.minX, y: -region.minY)
            AnnotationRenderer.drawImage(picture, in: region, context: context)
            for (item, coverage) in over {
                AnnotationRenderer.draw(item, in: context, scale: scale, coverage: coverage, ground: .light)
            }
            guard let redacted = context.makeImage() else { return nil }
            picture = redacted
        }
        let longest: CGFloat = 48
        let factor = min(longest / max(region.width, region.height), 1)
        let width = max(Int((region.width * factor).rounded()), 1)
        let height = max(Int((region.height * factor).rounded()), 1)
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
            context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
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
            // The app icon's ground too, so the two colors are kept in one place.
            return GradientRecipe(from: hex(Theme.Brand.groundStart), to: hex(Theme.Brand.groundEnd), glows: [
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

    /// The gradient as a picture `width` × `height` pixels in sRGB, for renderers outside the editor: Studio
    /// films its recordings over the same backgrounds.
    public func image(width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // Recipes are drawn y down, as the canvas draws them.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        recipe.draw(in: CGRect(x: 0, y: 0, width: width, height: height), context: context)
        return context.makeImage()
    }

    /// The gradient's name, as the editor's chips and Studio's inspector say it.
    public var title: String {
        switch self {
        case .sky: String(localized: "Sky", bundle: .module)
        case .lilac: String(localized: "Lilac", bundle: .module)
        case .rose: String(localized: "Rose", bundle: .module)
        case .peach: String(localized: "Peach", bundle: .module)
        case .citrus: String(localized: "Citrus", bundle: .module)
        case .mint: String(localized: "Mint", bundle: .module)
        case .ocean: String(localized: "Ocean", bundle: .module)
        case .dusk: String(localized: "Dusk", bundle: .module)
        case .graphite: String(localized: "Graphite", bundle: .module)
        case .paper: String(localized: "Paper", bundle: .module)
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
