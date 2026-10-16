import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSCore

struct PrintLayoutTests {
    /// US Letter less AppKit's margins (72 pt each side, 90 pt top and bottom), upright and turned.
    private let letter = (portrait: CGSize(width: 468, height: 612), landscape: CGSize(width: 648, height: 432))
    /// A4 the same way.
    private let a4 = (portrait: CGSize(width: 451, height: 662), landscape: CGSize(width: 698, height: 415))

    private func layout(_ width: CGFloat, _ height: CGFloat, on paper: (portrait: CGSize, landscape: CGSize)) -> PrintLayout {
        PrintLayout.layout(for: CGSize(width: width, height: height), portrait: paper.portrait, landscape: paper.landscape)
    }

    private let landscapePage = PrintLayout(landscape: true, pagesAcross: false, pagesDown: false)
    private let portraitPage = PrintLayout(landscape: false, pagesAcross: false, pagesDown: false)

    /// Screens and windows of every common shape print on one page, turned to print them larger.
    @Test func aScreenshotFitsOnePage() {
        for paper in [letter, a4] {
            #expect(layout(1600, 1000, on: paper) == landscapePage)
            #expect(layout(1920, 1080, on: paper) == landscapePage)
            #expect(layout(2560, 1440, on: paper) == landscapePage)
            #expect(layout(3000, 3000, on: paper) == portraitPage)
            #expect(layout(800, 1100, on: paper) == portraitPage)
            #expect(layout(400, 800, on: paper) == portraitPage)
            #expect(layout(500, 900, on: paper) == portraitPage)
        }
    }

    /// Smaller than the page either way, a picture is turned as it is shaped.
    @Test func aSmallPictureIsTurnedAsItIsShaped() {
        #expect(layout(300, 200, on: letter) == landscapePage)
        #expect(layout(200, 300, on: letter) == portraitPage)
    }

    @Test func aLongCaptureRunsDownThePages() {
        let down = PrintLayout(landscape: false, pagesAcross: false, pagesDown: true)
        #expect(layout(1000, 9000, on: letter) == down)
        #expect(layout(600, 4000, on: a4) == down)
    }

    @Test func aWideCaptureRunsAcrossLandscapePages() {
        #expect(layout(9000, 600, on: letter) == PrintLayout(landscape: true, pagesAcross: true, pagesDown: false))
    }
}

/// A picture of `size` pixels with lines of "text" 14 rows tall and 6 blank rows between, from the top, beside a
/// gray sidebar `sidebar` pixels wide that runs the picture's whole height. Each line is a wedge that narrows down
/// the line, so, like text, it changes from row to row.
func linedPicture(_ size: CGSize, sidebar: CGFloat = 0) throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ))
    context.setShouldAntialias(false)
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(origin: .zero, size: size))
    context.setFillColor(gray: 0.6, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: sidebar, height: size.height))
    context.setFillColor(gray: 0, alpha: 1)
    // Drawn y up: a line's rows 6–19 from the top are y 13 down to 0 above its foot.
    let left = sidebar + 10, right = left + (size.width - left) / 2
    for foot in stride(from: 0, to: size.height, by: 20) {
        context.move(to: CGPoint(x: left, y: foot))
        context.addLine(to: CGPoint(x: right, y: foot))
        context.addLine(to: CGPoint(x: left, y: foot + 14))
        context.closePath()
        context.fillPath()
    }
    return try #require(context.makeImage())
}

struct QuietRowsTests {
    @Test func aPageEndsInTheGapNearestWhereItWould() {
        var steady = [Bool](repeating: false, count: 100)
        for row in 66...70 { steady[row] = true }
        for row in 88...90 { steady[row] = true }
        #expect(QuietRows.pageEnd(in: steady, proposed: 95, lowest: 60) == 90)
        #expect(QuietRows.pageEnd(in: steady, proposed: 89, lowest: 60) == 70)
        // Two steady rows are not a gap.
        steady[88] = false
        #expect(QuietRows.pageEnd(in: steady, proposed: 95, lowest: 75) == nil)
        // Nothing steady within reach: the page ends where it would.
        #expect(QuietRows.pageEnd(in: steady, proposed: 60, lowest: 50) == nil)
    }

    /// The blank rows between lines repeat the row above, beside a sidebar too; the lines' rows do not.
    @Test func theRowsBetweenLinesAreSteadyBesideASidebar() throws {
        let steady = QuietRows.steadyRows(of: try linedPicture(CGSize(width: 300, height: 100), sidebar: 40), rows: 100)
        #expect(steady.count == 100)
        for row in 0..<100 {
            #expect(steady[row] == (1...5).contains(row % 20), "row \(row)")
        }
    }
}

/// Printing to a PDF file, no panel: a screenshot is one page, a long capture several.
@MainActor
struct ImagePrinterTests {
    private func pages(printing size: CGSize, on paper: CGSize = CGSize(width: 612, height: 792)) throws -> Int {
        try printed(size, on: paper) { $0.numberOfPages }
    }

    /// Prints a light gray picture of `size` pixels at 1× to a PDF on `paper` (US Letter) and reads the PDF.
    private func printed<T>(_ size: CGSize, on paper: CGSize = CGSize(width: 612, height: 792), _ read: (CGPDFDocument) throws -> T) throws -> T {
        let context = try #require(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appending(path: "ImagePrinterTests-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let info = NSPrintInfo()
        info.paperSize = paper
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = ImagePrinter.operation(for: image, pixelsPerPoint: 1, title: "Test", info: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        #expect(operation.run())
        return try read(try #require(CGPDFDocument(url as CFURL)))
    }

    @Test func aScreenshotPrintsOnOnePage() throws {
        #expect(try pages(printing: CGSize(width: 1600, height: 1000)) == 1)
        #expect(try pages(printing: CGSize(width: 1920, height: 1080)) == 1)
        #expect(try pages(printing: CGSize(width: 2560, height: 1440)) == 1)
        #expect(try pages(printing: CGSize(width: 400, height: 800)) == 1)
        #expect(try pages(printing: CGSize(width: 1920, height: 1080), on: CGSize(width: 595, height: 842)) == 1)
    }

    /// A picture smaller than the page prints at the size it was on screen, not blown up to the page.
    @Test func aSmallScreenshotPrintsAtItsOwnSize() throws {
        let drawn = try printed(CGSize(width: 300, height: 200)) { document -> CGRect in
            let page = try #require(document.page(at: 1))
            let box = page.getBoxRect(.mediaBox)
            let context = try #require(CGContext(
                data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ))
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(origin: .zero, size: box.size))
            context.drawPDFPage(page)
            let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            var gray = CGRect.null
            for row in 0..<context.height {
                for column in 0..<context.width where pixels[row * context.bytesPerRow + column] < 245 {
                    gray = gray.union(CGRect(x: column, y: row, width: 1, height: 1))
                }
            }
            return gray
        }
        #expect(abs(drawn.width - 300) <= 2 && abs(drawn.height - 200) <= 2, "\(drawn)")
    }

    @Test func aLongCapturePrintsOnSeveralPages() throws {
        // Fitted to a page's width (about 540 pt), 600 × 4000 pt runs about 3600 pt: five pages or so.
        #expect(try pages(printing: CGSize(width: 600, height: 4000)) >= 4)
    }

    /// Printed for real, a long capture of lines of "text" breaks its pages only between lines, where the view
    /// says, though the operation shrinks it to the page's width.
    @Test func aLongCaptureBreaksBetweenLinesWhenPrinted() throws {
        let size = CGSize(width: 600, height: 4000)
        let image = try linedPicture(size, sidebar: 80)
        let url = FileManager.default.temporaryDirectory.appending(path: "ImagePrinterTests-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let info = NSPrintInfo()
        info.paperSize = CGSize(width: 612, height: 792)
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = ImagePrinter.operation(for: image, pixelsPerPoint: 1, title: "Test", info: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        #expect(operation.run())
        let picture = try #require(operation.view as? PrintedPicture)
        let breaks = picture.pageEnds.filter { $0 < size.height - 1 }
        #expect(breaks.count >= 3, "\(picture.pageEnds)")
        for end in breaks { #expect((3...5).contains(Int(end) % 20), "page ends at \(end), inside a line") }
    }

    /// A page that would end inside a line of "text" ends in the blank rows above it instead.
    @Test func aPageEndsBetweenLines() throws {
        let size = CGSize(width: 200, height: 2000)
        let picture = PrintedPicture(image: try linedPicture(size), size: size)
        var bottom: CGFloat = 0
        picture.adjustPageHeightNew(&bottom, top: 0, bottom: 1007, limit: 900)
        #expect(bottom == 1005)
        // Where a page would end in the blank rows, it ends there.
        picture.adjustPageHeightNew(&bottom, top: 0, bottom: 1003, limit: 900)
        #expect(bottom == 1003)
    }
}
