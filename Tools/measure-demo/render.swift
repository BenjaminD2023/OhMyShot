// Deterministic synthetic fixture rendered with the real Measure overlay and pixel engine.
// This produces an explanatory animation, not a screen recording. Build the intended
// source revision first; the linked package objects supply the measurement behavior.
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import OMSCore
import QuartzCore
import UniformTypeIdentifiers
@testable import OMSCapture

@main
struct SnappingDemo {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        guard CommandLine.arguments.count == 2 else { throw failure("Usage: render-measure-demo OUTPUT_DIRECTORY") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let size = CGSize(width: 760, height: 480)
        let display = DisplayInfo(id: 1, name: "Public synthetic fixture", frame: CGRect(origin: .zero, size: size), pixelSize: size, backingScale: 1, maximumPotentialEDR: 1)
        let image = try fixture(size: size)
        let frame = CapturedFrame(image: image, hdrImage: nil, displayID: display.id, frame: display.frame)
        let overlay = MeasureOverlay(display: display)
        overlay.unit = .points
        overlay.tolerance = .medium
        overlay.applyAppearance(dark: false, contrast: false, accent: CGColor(srgbRed: 0.15, green: 0.40, blue: 0.95, alpha: 1))
        overlay.show(frame)
        overlay.movePointer(to: CGPoint(x: 130, y: 382))
        for _ in 0..<200 {
            if overlay.measurement != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard overlay.measurement == "120 × 36 pt" else { throw failure("Crosshair fixture measurement mismatch: \(overlay.measurement ?? "nil")") }
        var rendered: [(CGImage, Double)] = []
        var records: [[String: Any]] = []
        func snapshot(_ phase: String, caption: String, delay: Double, pointer: CGPoint?) throws {
            let out = try render(image: image, overlay: overlay, size: size, caption: caption, pointer: pointer)
            let index = rendered.count
            try png(out, to: root.appendingPathComponent(String(format: "frame-%02d.png", index)))
            let box = (overlay.layer.sublayers?.first as? CAShapeLayer)?.path?.boundingBoxOfPath
            let record: [String: Any] = ["frame": index, "phase": phase, "delaySeconds": delay, "measurement": overlay.measurement as Any? ?? NSNull(), "tolerance": overlay.tolerance.title, "snappingEnabled": overlay.snapsToContent, "selectionPoints": box.map { [$0.minX, $0.minY, $0.width, $0.height] } as Any? ?? NSNull()]
            records.append(record)
            rendered.append((out, delay))
        }
        try snapshot("crosshair", caption: "Hover: real pixel-edge measurements", delay: 1.1, pointer: CGPoint(x: 130, y: 382))
        let start = CGPoint(x: 200, y: 370), end = CGPoint(x: 560, y: 150)
        overlay.beginBox(at: start)
        for step in 1...7 {
            let fraction = CGFloat(step) / 7
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            overlay.dragBox(to: point)
            try snapshot("drag-\(step)", caption: "Drag loosely around a low-contrast card", delay: step == 7 ? 0.8 : 0.09, pointer: point)
        }
        overlay.endBox()
        let expected = CGRect(x: 230, y: 180, width: 300, height: 160)
        guard selectionRect(overlay) == expected, overlay.measurement == "300 × 160 pt" else { throw failure("Medium snap mismatch: \(String(describing: selectionRect(overlay)))") }
        try snapshot("medium-snap", caption: "Release: Medium finds the supported 300 × 160 pt edges", delay: 1.8, pointer: end)
        overlay.tolerance = .high
        let original = CGRect(x: 200, y: 150, width: 360, height: 220)
        guard selectionRect(overlay) == original else { throw failure("High tolerance must retain the drawn box") }
        try snapshot("high-abstains", caption: "High tolerance: faint edges are ignored; keep the drawn area", delay: 1.8, pointer: end)
        overlay.tolerance = .medium
        guard selectionRect(overlay) == expected else { throw failure("Medium must resnap from the original selection") }
        try snapshot("medium-resnap", caption: "Back to Medium: resnap from the original drag", delay: 1.8, pointer: end)
        overlay.snapsToContent = false
        overlay.beginBox(at: start)
        overlay.dragBox(to: end)
        overlay.endBox()
        guard selectionRect(overlay) == original else { throw failure("Disabling snapping must preserve the manual rectangle") }
        try snapshot("snapping-disabled", caption: "Snapping off: preserve the manual 360 × 220 pt area", delay: 1.8, pointer: end)
        overlay.snapsToContent = true
        overlay.beginBox(at: start)
        overlay.dragBox(to: end)
        overlay.endBox()
        guard selectionRect(overlay) == expected else { throw failure("Reenabled snapping must recover the same card") }
        try snapshot("snapping-enabled", caption: "Snapping on: recover the supported card bounds", delay: 1.8, pointer: end)
        let gif = root.appendingPathComponent("measurement-snapping.gif")
        guard let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, rendered.count, nil) else { throw failure("GIF destination unavailable") }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (image, delay) in rendered {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw failure("GIF encoding failed") }
        guard let source = CGImageSourceCreateWithURL(gif as CFURL, nil), CGImageSourceGetCount(source) == rendered.count else { throw failure("GIF frame-count validation failed") }
        var decodedDelays: [Double] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let decoded = CGImageSourceCreateImageAtIndex(source, index, nil), decoded.width == 760, decoded.height == 480,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let gifProps = props[kCGImagePropertyGIFDictionary] as? [CFString: Any], let delay = gifProps[kCGImagePropertyGIFDelayTime] as? Double else { throw failure("GIF decode validation failed") }
            decodedDelays.append(delay)
        }
        let report: [String: Any] = [
            "method": "Deterministic synthetic fixture rendered offscreen using the current built MeasureOverlay, PixelGrid, MeasurementEdges and CALayer.render(in:). Drag/tolerance/snapping state comes from the real overlay methods. No window, real screen recording, clipboard/history writes, or user data. Cursor/captions are explanatory annotations.",
            "allChecksPassed": true, "canvasPixels": [760, 480], "frameCount": rendered.count,
            "decodedFrameDelays": decodedDelays, "durationSeconds": decodedDelays.reduce(0, +),
            "expectedObjectPoints": [230, 180, 300, 160],
            "frames": records, "gifFile": gif.lastPathComponent,
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: root.appendingPathComponent("measurement-snapping-validation.json"))
        print(String(decoding: json, as: UTF8.self))
        overlay.clear()
    }

    static func failure(_ text: String) -> NSError { NSError(domain: "SnappingDemo", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    @MainActor
    static func selectionRect(_ overlay: MeasureOverlay) -> CGRect? { (overlay.layer.sublayers?.first as? CAShapeLayer)?.path?.boundingBoxOfPath }

    static func fixture(size: CGSize) throws -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let upY = h - 1 - y
            var v = 240 + x / 120
            if x >= 230 && x < 530 && upY >= 180 && upY < 340 { v -= 9 }
            let at = (y * w + x) * 4
            if x >= 70 && x < 190 && upY >= 364 && upY < 400 {
                bytes[at] = 91; bytes[at + 1] = 124; bytes[at + 2] = 240
            } else {
                bytes[at] = UInt8(v); bytes[at + 1] = UInt8(v); bytes[at + 2] = UInt8(v)
            }
        } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw failure("Fixture creation failed") }
        return image
    }

    @MainActor
    static func render(image: CGImage, overlay: MeasureOverlay, size: CGSize, caption: String, pointer: CGPoint?) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure("Render context unavailable") }
        context.draw(image, in: CGRect(origin: .zero, size: size))
        let annotations = CALayer()
        annotations.frame = CGRect(origin: .zero, size: size)
        func label(_ value: String, x: CGFloat, y: CGFloat, font: CGFloat, bold: Bool = false) {
            let layer = CATextLayer()
            layer.frame = CGRect(x: x, y: y, width: size.width - 48, height: font + 10)
            layer.font = NSFont.systemFont(ofSize: font, weight: bold ? .semibold : .regular)
            layer.fontSize = font
            layer.string = value
            layer.foregroundColor = CGColor(gray: 0.16, alpha: 1)
            layer.contentsScale = 1
            annotations.addSublayer(layer)
        }
        label("OhMyShot · Measure snapping", x: 24, y: 435, font: 22, bold: true)
        label("Synthetic fixture • rendered with the real measurement overlay", x: 24, y: 412, font: 13)
        label(caption, x: 24, y: 83, font: 15, bold: true)
        label("Card/background contrast: 9 levels • gentle background gradient • 1× pixels", x: 24, y: 61, font: 12)
        annotations.render(in: context)
        overlay.layer.render(in: context)
        if let pointer {
            context.saveGState()
            context.setFillColor(CGColor(gray: 0.12, alpha: 1))
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.setLineWidth(1.5)
            context.fillEllipse(in: CGRect(x: pointer.x - 3, y: pointer.y - 3, width: 6, height: 6))
            context.strokeEllipse(in: CGRect(x: pointer.x - 3, y: pointer.y - 3, width: 6, height: 6))
            context.restoreGState()
        }
        guard let result = context.makeImage() else { throw failure("Rendered image unavailable") }
        return result
    }

    static func png(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw failure("PNG destination unavailable") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw failure("PNG encoding failed") }
    }
}
