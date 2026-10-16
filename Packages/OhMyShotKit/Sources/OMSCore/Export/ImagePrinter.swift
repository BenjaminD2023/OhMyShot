import AppKit
import CoreGraphics

/// How a picture goes onto paper: on one page, turned whichever way prints it larger, unless running it onto more
/// pages prints it much larger: a picture much taller than a page (a scrolling capture) fitted to the page's width and
/// run down, one much wider fitted to a landscape page's height and run across.
public struct PrintLayout: Equatable, Sendable {
    public var landscape: Bool
    /// Across the page: fitted (false) or run onto further pages.
    public var pagesAcross: Bool
    /// Down the page: fitted (false) or run onto further pages.
    public var pagesDown: Bool

    /// A picture runs onto further pages only when they print it at least this much larger than one page does.
    static let gain: CGFloat = 1.5

    /// For a picture of `size` (points) on paper whose printable part is `portrait` upright and `landscape` turned
    /// (the margins stay where they are as the paper turns, so these are not one size turned).
    public static func layout(for size: CGSize, portrait: CGSize, landscape: CGSize) -> PrintLayout {
        let width = max(size.width, 1), height = max(size.height, 1)
        let upright = min(1, portrait.width / width, portrait.height / height)
        let turned = min(1, landscape.width / width, landscape.height / height)
        // On one page: whichever way is larger; at full size either way, as the picture is shaped.
        let onePage = max(upright, turned)
        let turnsOnePage = turned > upright || (turned == upright && size.width > size.height)
        let down = min(1, portrait.width / width), across = min(1, landscape.height / height)
        if down >= onePage * gain, down >= across { return PrintLayout(landscape: false, pagesAcross: false, pagesDown: true) }
        if across >= onePage * gain { return PrintLayout(landscape: true, pagesAcross: true, pagesDown: false) }
        return PrintLayout(landscape: turnsOnePage, pagesAcross: false, pagesDown: false)
    }
}

/// Where a page of a long picture ends: a little above where the page runs out, in a gap where the picture stays the
/// same for a few rows running (between lines of text, under a picture), so no line is cut in half. A row that is
/// not one color across (a sidebar, a scrollbar, a border down the side) still makes a gap when it repeats the row
/// above it; a line of text changes from row to row.
public enum QuietRows {
    /// Rows running, in points, that repeat the one above them for a gap to end a page in.
    static let gap = 3
    /// How far a pixel may change from the row above, of 255, and still repeat it.
    static let tolerance = 16

    /// Whether each row (a point of the picture's height, from the top) repeats the row above it: no column
    /// changes by more than `tolerance`. The first row does not.
    public static func steadyRows(of image: CGImage, rows: Int) -> [Bool] {
        let width = min(image.width, 512)
        let height = max(min(rows, image.height), 1)
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [Bool](repeating: false, count: height) }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // The context's first row is the picture's top.
        return (0..<height).map { row in
            guard row > 0 else { return false }
            let above = (row - 1) * width, here = row * width
            return (0..<width).allSatisfy { abs(Int(pixels[here + $0]) - Int(pixels[above + $0])) <= tolerance }
        }
    }

    /// The row to end a page at, between `lowest` and `proposed` (rows from the top, `lowest` < `proposed`): the
    /// last row of a gap nearest `proposed`, or nil to keep it when no gap ends there.
    public static func pageEnd(in steady: [Bool], proposed: Int, lowest: Int) -> Int? {
        let top = max(lowest, gap - 1), bottom = min(proposed, steady.count - 1)
        guard top <= bottom else { return nil }
        return stride(from: bottom, through: top, by: -1).first { row in (row - gap + 1...row).allSatisfy { steady[$0] } }
    }
}

/// Prints captures through the system's print panel.
@MainActor
public enum ImagePrinter {
    /// The print operation for `image` (at `pixelsPerPoint`), laid out as `PrintLayout` says on `info`'s paper.
    public static func operation(for image: CGImage, pixelsPerPoint: CGFloat, title: String, info: NSPrintInfo) -> NSPrintOperation {
        let scale = max(pixelsPerPoint, 1)
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let short = min(info.paperSize.width, info.paperSize.height), long = max(info.paperSize.width, info.paperSize.height)
        let across = info.leftMargin + info.rightMargin, down = info.topMargin + info.bottomMargin
        let layout = PrintLayout.layout(
            for: size, portrait: CGSize(width: short - across, height: long - down), landscape: CGSize(width: long - across, height: short - down)
        )
        info.orientation = layout.landscape ? .landscape : .portrait
        info.horizontalPagination = layout.pagesAcross ? .automatic : .fit
        info.verticalPagination = layout.pagesDown ? .automatic : .fit
        info.isHorizontallyCentered = !layout.pagesAcross
        info.isVerticallyCentered = !layout.pagesDown
        let operation = NSPrintOperation(view: PrintedPicture(image: image, size: size), printInfo: info)
        operation.jobTitle = title
        return operation
    }

    /// Shows the print panel for `image`: as a sheet on `window`, else on its own with the app brought forward.
    public static func print(_ image: CGImage, pixelsPerPoint: CGFloat, title: String, from window: NSWindow? = nil) {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        let operation = operation(for: image, pixelsPerPoint: pixelsPerPoint, title: title, info: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsPreview, .showsCopies, .showsPageRange, .showsPaperSize, .showsOrientation, .showsScaling])
        if let window, window.isVisible {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            // On its own the panel runs modally: from the run loop, as an event's action would, since inside a task
            // it would hold every other task on the main actor until it closed.
            nonisolated(unsafe) let operation = operation
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    NSApp.activate()
                    operation.run()
                }
            }
        }
    }

    /// Prints the picture in the file at `url`; false when it cannot be read.
    @discardableResult
    public static func print(fileAt url: URL, fallbackScale: CGFloat = 2, from window: NSWindow? = nil) -> Bool {
        guard let loaded = ImageLoader.load(contentsOf: url, fallbackScale: fallbackScale) else { return false }
        print(loaded.image, pixelsPerPoint: loaded.scale, title: url.deletingPathExtension().lastPathComponent, from: window)
        return true
    }
}

/// The picture as the print operation lays it out: its size in points, drawn whole, its pages ending in gaps.
final class PrintedPicture: NSView {
    private let image: CGImage
    /// Whether each row repeats the one above it, one entry a point of the picture's height, made when a page
    /// first ends.
    private lazy var steady: [Bool] = QuietRows.steadyRows(of: image, rows: Int(bounds.height.rounded(.up)))
    /// Where each page ended, in the view's points from the top, as the operation asked: for tests.
    private(set) var pageEnds: [CGFloat] = []

    init(image: CGImage, size: CGSize) {
        self.image = image
        super.init(frame: CGRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.interpolationQuality = .high
        // Images draw y up; the view is flipped.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()
    }

    /// A page ends in the gap nearest where it would, within what AppKit allows.
    override func adjustPageHeightNew(_ newBottom: UnsafeMutablePointer<CGFloat>, top: CGFloat, bottom proposedBottom: CGFloat, limit bottomLimit: CGFloat) {
        super.adjustPageHeightNew(newBottom, top: top, bottom: proposedBottom, limit: bottomLimit)
        defer { pageEnds.append(newBottom.pointee) }
        guard proposedBottom < bounds.height - 1,
              let row = QuietRows.pageEnd(in: steady, proposed: Int(proposedBottom.rounded(.down)), lowest: Int(bottomLimit.rounded(.up)))
        else { return }
        newBottom.pointee = CGFloat(row)
    }
}
