#if DEBUG
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import OMSCore

/// A page with everything the OCR panel handles: wrapping paragraphs in Chinese and English, a link,
/// contacts, a date, a table, and a QR code. Drawn in the app, so scripted checks never read the screen.
enum DebugPanelDemo {
    static let size = CGSize(width: 760, height: 560)

    /// `prose`: the paragraphs alone, no table or code, for measuring the common case.
    /// A whole display drawn for scripted checks of the capture overlay, so they never record what is
    /// really on screen: a plain light desktop, with the demo page at its middle when `page` is set.
    static func screen(for display: DisplayInfo, page: Bool) -> CGImage? {
        let scale = display.pixelsPerPoint
        let width = Int(display.pixelSize.width), height = Int(display.pixelSize.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0.86, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if page, let image = image(scale: scale) {
            let rect = pageRect(on: display)
            // Core Graphics is y up; the page rect is from the top-left corner.
            context.draw(image, in: CGRect(x: rect.minX * scale, y: (display.frame.height - rect.maxY) * scale, width: rect.width * scale, height: rect.height * scale))
        }
        return context.makeImage()
    }

    /// Where `screen(for:page:)` draws the page, in the display's points from its top-left corner.
    static func pageRect(on display: DisplayInfo) -> CGRect {
        CGRect(x: ((display.frame.width - size.width) / 2).rounded(), y: ((display.frame.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    static func image(scale: CGFloat = 2, blank: Bool = false, prose: Bool = false) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Top-left origin, in points.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor(white: 0.985, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        guard !blank else { return context.makeImage() }

        draw("发布说明 Release Notes", font: .systemFont(ofSize: 22, weight: .semibold), in: CGRect(x: 40, y: 32, width: 440, height: 32))
        draw(
            "截图完成后，卡片会出现在屏幕左下角，可以直接拖到其他应用里。按住 Option 再松开鼠标，就能在面板里查看和编辑识别出的文字。",
            font: .systemFont(ofSize: 15), in: CGRect(x: 40, y: 78, width: 420, height: 80)
        )
        draw(
            "Quick Access keeps every capture one click away. The text in a capture can be copied, edited, and searched.",
            font: .systemFont(ofSize: 15), in: CGRect(x: 40, y: 150, width: 420, height: 60)
        )
        draw(
            "Docs: https://example.com/docs\nMail: hello@example.com\nPhone: +1 (555) 010-0199\nRelease: October 15, 2026 at 2:30 PM",
            font: .systemFont(ofSize: 14), in: CGRect(x: 40, y: 222, width: 420, height: 100)
        )
        guard !prose else { return context.makeImage() }
        drawTable(
            [["套餐 Plan", "价格 Price", "容量 Storage"], ["Free", "$0", "5 GB"], ["Pro", "$8", "100 GB"], ["Team", "$20", "1 TB"]],
            origin: CGPoint(x: 40, y: 344), columns: [170, 130, 150], rowHeight: 36
        )
        if let code = qrCode("https://example.com/ohmyshot", side: 170 * scale) {
            NSImage(cgImage: code, size: CGSize(width: 170, height: 170)).draw(
                in: CGRect(x: 540, y: 80, width: 170, height: 170), from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue]
            )
        }
        draw("扫码下载 Scan to download", font: .systemFont(ofSize: 13), color: .secondaryLabelColor, in: CGRect(x: 540, y: 262, width: 200, height: 20))
        return context.makeImage()
    }

    /// The demo as a PNG marked 144 dpi, as a Retina screenshot from macOS is.
    static func png(scale: CGFloat = 2) -> Data? {
        guard let image = image(scale: scale) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale,
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func draw(_ text: String, font: NSFont, color: NSColor = .black, in rect: CGRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
            .draw(with: rect, options: [.usesLineFragmentOrigin])
    }

    private static func drawTable(_ rows: [[String]], origin: CGPoint, columns: [CGFloat], rowHeight: CGFloat) {
        let width = columns.reduce(0, +)
        NSColor(white: 0.93, alpha: 1).setFill()
        CGRect(x: origin.x, y: origin.y, width: width, height: rowHeight).fill()
        NSColor(white: 0.72, alpha: 1).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 1
        for row in 0...rows.count {
            let y = origin.y + CGFloat(row) * rowHeight
            grid.move(to: CGPoint(x: origin.x, y: y))
            grid.line(to: CGPoint(x: origin.x + width, y: y))
        }
        var x = origin.x
        for column in [0] + columns {
            x += column
            grid.move(to: CGPoint(x: x, y: origin.y))
            grid.line(to: CGPoint(x: x, y: origin.y + CGFloat(rows.count) * rowHeight))
        }
        grid.stroke()
        for (row, cells) in rows.enumerated() {
            var left = origin.x
            for (column, cell) in cells.enumerated() {
                let font: NSFont = row == 0 ? .systemFont(ofSize: 14, weight: .semibold) : .systemFont(ofSize: 14)
                draw(cell, font: font, in: CGRect(x: left + 10, y: origin.y + CGFloat(row) * rowHeight + 9, width: columns[column] - 20, height: rowHeight - 12))
                left += columns[column]
            }
        }
    }

    private static func qrCode(_ message: String, side: CGFloat) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(message.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: side / output.extent.width, y: side / output.extent.height))
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(scaled, from: scaled.extent)
    }
}
#endif
