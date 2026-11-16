import CoreGraphics
import Foundation
import Testing
@testable import OMSCore

/// Combining History's pictures: the collage's layout and drawing, and the PDF of them, read back.
struct CollageLayoutTests {
    private func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.5) -> Bool { abs(a - b) <= tolerance }

    @Test func aRowMakesThePicturesAsTallAsEachOtherAndFillsTheWidth() {
        let sizes = [CGSize(width: 400, height: 300), CGSize(width: 300, height: 600)]
        let layout = CollageLayout.layout(sizes, options: .init(arrangement: .row, width: 1000, spacing: 10, margin: 20))
        #expect(layout.cells.count == 2)
        #expect(near(layout.cells[0].height, layout.cells[1].height))
        // Each cell keeps its picture's shape.
        #expect(near(layout.cells[0].width / layout.cells[0].height, 4.0 / 3.0, 0.001))
        #expect(near(layout.cells[1].width / layout.cells[1].height, 0.5, 0.001))
        #expect(near(layout.cells[0].minX, 20) && near(layout.cells[1].maxX, 980))
        #expect(near(layout.cells[1].minX - layout.cells[0].maxX, 10))
        #expect(near(layout.size.height, layout.cells[0].height + 40, 1))
    }

    @Test func aColumnStacksThemAsWideAsEachOther() {
        let sizes = [CGSize(width: 800, height: 400), CGSize(width: 400, height: 400)]
        let layout = CollageLayout.layout(sizes, options: .init(arrangement: .column, width: 600, spacing: 8, margin: 0))
        #expect(layout.cells.map(\.width) == [600, 600])
        #expect(near(layout.cells[0].height, 300) && near(layout.cells[1].height, 600))
        #expect(near(layout.cells[1].minY, 308))
        #expect(near(layout.size.height, 908, 1))
    }

    @Test func aGridCentersAShortLastRow() {
        let sizes = Array(repeating: CGSize(width: 400, height: 300), count: 5)
        let layout = CollageLayout.layout(sizes, options: .init(arrangement: .grid, width: 1000, spacing: 10, margin: 10))
        let rows = Dictionary(grouping: layout.cells, by: { Int($0.minY.rounded()) })
        #expect(rows.count >= 2)
        // Every cell is the same size; the last row's run is centered.
        #expect(Set(layout.cells.map { Int($0.width.rounded()) }).count == 1)
        let last = rows[rows.keys.max()!]!
        let left = last.map(\.minX).min()! - 10, right = 1000 - 10 - last.map(\.maxX).max()!
        #expect(near(left, right))
        // Nothing reaches past the margin.
        #expect(layout.cells.allSatisfy { $0.minX >= 9.5 && $0.maxX <= 990.5 })
    }

    @Test func featuredPutsTheFirstOnTheLeftAsTallAsTheOthersTogether() {
        let sizes = [CGSize(width: 600, height: 800), CGSize(width: 400, height: 300), CGSize(width: 400, height: 300)]
        let layout = CollageLayout.layout(sizes, options: .init(arrangement: .featured, width: 1000, spacing: 12, margin: 16))
        let first = layout.cells[0], others = Array(layout.cells.dropFirst())
        #expect(near(first.width / first.height, 0.75, 0.001))
        #expect(near(others.last!.maxY, first.maxY))
        #expect(near(others[0].minX, first.maxX + 12))
        #expect(near(others[0].maxX, 1000 - 16))
        #expect(near(others[1].minY - others[0].maxY, 12))
    }

    @Test func theArrangementStartsFromHowManyPicturesThereAre() {
        let wide = CGSize(width: 1600, height: 900), tall = CGSize(width: 400, height: 900)
        #expect(CollageLayout.suggested(for: [wide, wide]) == .column)
        #expect(CollageLayout.suggested(for: [tall, tall]) == .row)
        #expect(CollageLayout.suggested(for: [wide, wide, wide]) == .featured)
        #expect(CollageLayout.suggested(for: Array(repeating: wide, count: 4)) == .grid)
        #expect(CollageLayout.columns(for: Array(repeating: CGSize(width: 400, height: 300), count: 4)) == 2)
    }

    @Test func fittingKeepsTheWholePictureAndFillingCoversTheCell() {
        let cell = CGRect(x: 0, y: 0, width: 200, height: 100)
        let fit = CollageLayout.pictureRect(of: CGSize(width: 100, height: 100), in: cell, fitting: .fit)
        #expect(fit == CGRect(x: 50, y: 0, width: 100, height: 100))
        let fill = CollageLayout.pictureRect(of: CGSize(width: 100, height: 100), in: cell, fitting: .fill)
        #expect(fill == CGRect(x: 0, y: -50, width: 200, height: 200))
    }

    @Test func theRendererDrawsEachPictureInItsCellOnTheBackground() throws {
        func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) throws -> CGImage {
            let context = try #require(CGContext(
                data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            return try #require(context.makeImage())
        }
        let pictures = [
            CollageRenderer.Picture(image: try solid(1, 0, 0), size: CGSize(width: 40, height: 20)),
            CollageRenderer.Picture(image: try solid(0, 0, 1), size: CGSize(width: 40, height: 20)),
        ]
        let layout = CollageLayout.layout(pictures.map(\.size), options: .init(arrangement: .column, width: 200, spacing: 20, margin: 20))
        let image = try #require(CollageRenderer.render(
            pictures, layout: layout, fitting: .fit, cornerRadius: 0, background: CGColor(gray: 1, alpha: 1), scale: 2
        ))
        #expect(image.width == 400 && CGFloat(image.height) == layout.size.height * 2)
        // Read back: the margin is white, the first cell red, the second blue (in points, y down).
        let data = try #require(image.dataProvider?.data as Data?)
        func pixel(_ x: CGFloat, _ y: CGFloat) -> (UInt8, UInt8, UInt8) {
            let offset = Int(y * 2) * image.bytesPerRow + Int(x * 2) * 4
            return (data[offset], data[offset + 1], data[offset + 2])
        }
        #expect(pixel(5, 5) == (255, 255, 255))
        let first = layout.cells[0], second = layout.cells[1]
        #expect(pixel(first.midX, first.midY) == (255, 0, 0))
        #expect(pixel(second.midX, second.midY) == (0, 0, 255))
    }
}

struct PDFExportTests {
    private func picture(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func pages(of data: Data) throws -> [CGRect] {
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        return (1...document.numberOfPages).compactMap { document.page(at: $0)?.getBoxRect(.mediaBox) }
    }

    @Test func eachPictureIsAPageOfItsOwnSizeInPoints() throws {
        let data = try PDFExport.data([
            .init(image: try picture(width: 800, height: 600), pixelsPerPoint: 2),
            .init(image: try picture(width: 300, height: 500), pixelsPerPoint: nil),
        ], pageSize: .picture, title: "Two")
        #expect(try pages(of: data) == [CGRect(x: 0, y: 0, width: 400, height: 300), CGRect(x: 0, y: 0, width: 300, height: 500)])
    }

    @Test func onPaperAPageTurnsToThePictureAndFitsItInsideTheMargin() throws {
        let wide = PDFExport.layout(pictureSize: CGSize(width: 1440, height: 900), pageSize: .a4)
        #expect(wide.page.width > wide.page.height)
        #expect(wide.picture.minX >= PDFExport.margin - 0.01 && wide.picture.maxX <= wide.page.width - PDFExport.margin + 0.01)
        #expect(abs(wide.picture.width / wide.picture.height - 1.6) < 0.001)
        // A small picture is not enlarged, and is centered.
        let small = PDFExport.layout(pictureSize: CGSize(width: 200, height: 100), pageSize: .letter)
        #expect(small.page.size == CGSize(width: 792, height: 612))
        #expect(small.picture == CGRect(x: 296, y: 256, width: 200, height: 100))

        let data = try PDFExport.data([
            .init(image: try picture(width: 2880, height: 1800), pixelsPerPoint: 2),
            .init(image: try picture(width: 400, height: 800), pixelsPerPoint: 1),
        ], pageSize: .letter)
        #expect(try pages(of: data) == [CGRect(x: 0, y: 0, width: 792, height: 612), CGRect(x: 0, y: 0, width: 612, height: 792)])
    }

    @Test func filesAreWrittenAsEveryCopyIs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.png")
        try await ImageExporter.write(try picture(width: 800, height: 400), to: file, format: .png)
        // Retina to 1× makes a page of a 2× picture its size in points, at one pixel a point.
        var output = ScreenshotOutput.standard
        output.retinaAtOneX = true
        let data = try await PDFExport.data(ofFiles: [(file, 2), (file, 2)], output: output, pageSize: .picture)
        #expect(try pages(of: data) == Array(repeating: CGRect(x: 0, y: 0, width: 400, height: 200), count: 2))
        await #expect(throws: PDFExport.ExportError.self) {
            _ = try await PDFExport.data(ofFiles: [], output: output, pageSize: .picture)
        }
    }
}
