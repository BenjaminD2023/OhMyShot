import CoreGraphics
import Foundation
import ImageIO
import OMSPixels
import Testing
@testable import OMSOCR

/// A tall PNG read from its file a band at a time (`PictureText.Bands`, `PNGBands`): its rows as ImageIO decodes them,
/// and its pieces' pixels as `PPOCRPixels` draws them from the decoded picture, byte for byte, in every kind of PNG read
/// so; every other kind decoded whole, as before.
struct PictureBandsTests {
    /// A PNG of `width` × `height`: its color type and bit depth, and what else it holds.
    struct Kind: CustomStringConvertible {
        var name: String
        var colorType: UInt8
        var depth: UInt8
        var interlaced = false
        var palette: Int? = nil
        var transparency: [UInt8]? = nil
        var chunks: [(String, [UInt8])] = []
        var description: String { name }
    }

    static let read: [Kind] = [
        Kind(name: "RGBA 8", colorType: 6, depth: 8),
        Kind(name: "RGBA 8, Display P3", colorType: 6, depth: 8, chunks: [("iCCP", TestPNG.profileChunk(CGColorSpace.displayP3))]),
        Kind(name: "RGBA 8, sRGB and gamma", colorType: 6, depth: 8, chunks: [("sRGB", [0]), ("gAMA", [0, 0, 0xB1, 0x8F])]),
        Kind(name: "RGB 8", colorType: 2, depth: 8),
        Kind(name: "gray 8", colorType: 0, depth: 8),
        Kind(name: "gray and alpha 8", colorType: 4, depth: 8),
        Kind(name: "gray 1", colorType: 0, depth: 1),
        Kind(name: "gray 2", colorType: 0, depth: 2),
        Kind(name: "gray 4", colorType: 0, depth: 4),
        Kind(name: "RGBA 16", colorType: 6, depth: 16),
        Kind(name: "RGB 16", colorType: 2, depth: 16),
        Kind(name: "gray 16", colorType: 0, depth: 16),
        Kind(name: "gray and alpha 16", colorType: 4, depth: 16),
        Kind(name: "palette 8", colorType: 3, depth: 8, palette: 200),
        Kind(name: "palette 4", colorType: 3, depth: 4, palette: 16),
        Kind(name: "palette 2", colorType: 3, depth: 2, palette: 4),
        Kind(name: "palette 1", colorType: 3, depth: 1, palette: 2),
    ]

    static let decodedWhole: [Kind] = [
        Kind(name: "RGBA 8, interlaced", colorType: 6, depth: 8, interlaced: true),
        Kind(name: "gray 8, interlaced", colorType: 0, depth: 8, interlaced: true),
        Kind(name: "palette 8, interlaced", colorType: 3, depth: 8, interlaced: true, palette: 200),
        Kind(name: "RGBA 16, interlaced", colorType: 6, depth: 16, interlaced: true),
        Kind(name: "palette 8, transparent", colorType: 3, depth: 8, palette: 200, transparency: (0 ..< 120).map { UInt8($0 * 53 % 256) }),
        Kind(name: "RGB 8, a transparent color", colorType: 2, depth: 8, transparency: [0, 0, 0, 0, 0, 0]),
        Kind(name: "gray 8, a transparent gray", colorType: 0, depth: 8, transparency: [0, 0]),
    ]

    /// Tall enough for three pieces (0–2048, 1792–3840, 3584–3901).
    static let width = 53, height = 3901

    @Test(arguments: read)
    func everyKindReadIsLaidOutAndDrawnAsItsDecodedPictureIs(_ kind: Kind) throws {
        let url = try TestPNG.file(kind, width: Self.width, height: Self.height)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoded = try PictureText.image(at: url)
        let pieces = PictureText.pieces(width: Self.width, height: Self.height)
        #expect(pieces.count == 3)

        // The rows, as ImageIO lays out the decoded picture.
        let rows = try #require(PNGBands(data: try Data(contentsOf: url), overlap: PictureText.overlap))
        let whole = try #require(decoded.dataProvider?.data as Data?)
        #expect(decoded.bitsPerComponent == rows.layout.bitsPerComponent && decoded.bitsPerPixel == rows.layout.bitsPerPixel)
        #expect(decoded.bitmapInfo == rows.layout.bitmapInfo)
        for piece in pieces {
            let band = try #require(rows.rows(Int(piece.minY) ..< Int(piece.maxY))?.data as Data?)
            for row in Int(piece.minY) ..< Int(piece.maxY) {
                let mine = band[(row - Int(piece.minY)) * rows.bytesPerRow ..< (row - Int(piece.minY) + 1) * rows.bytesPerRow]
                let theirs = whole[row * decoded.bytesPerRow ..< row * decoded.bytesPerRow + rows.bytesPerRow]
                guard mine.elementsEqual(theirs) else {
                    Issue.record("row \(row) of \(kind) differs from ImageIO's")
                    return
                }
            }
        }

        // The pieces' pixels, drawn in strips (a few rows each, to have several in a piece) and from each piece's picture.
        let strips = try #require(PictureText.Bands(fileAt: url))
        let pictures = try #require(PictureText.Bands(fileAt: url))
        #expect(strips.pieces == pieces)
        for piece in pieces {
            let expected = try #require(PPOCRPixels(decoded, region: piece))
            let drawn = PPOCRPixels(width: Int(piece.width), height: Int(piece.height), space: strips.colorSpace) { context in
                #expect(strips.draw(piece, into: context, stripBytes: Self.width * 4 * 300))
            }
            #expect(drawn?.bytes == expected.bytes, "\(kind), \(piece), in strips")
            let picture = try #require(pictures.image(of: piece))
            #expect(PPOCRPixels(picture)?.bytes == expected.bytes, "\(kind), \(piece), as a picture")
        }
    }

    @Test(arguments: decodedWhole)
    func everyOtherKindIsDecodedWhole(_ kind: Kind) throws {
        let url = try TestPNG.file(kind, width: Self.width, height: Self.height)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PictureText.Bands(fileAt: url) == nil)
        #expect(PNGBands(data: try Data(contentsOf: url), overlap: PictureText.overlap) == nil)
        _ = try PictureText.image(at: url)
    }

    @Test func aPictureInOnePieceIsDecodedWhole() throws {
        let url = try TestPNG.file(Self.read[0], width: Self.width, height: 2560)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PictureText.pieces(width: Self.width, height: 2560).count == 1)
        #expect(PictureText.Bands(fileAt: url) == nil)
    }

    @Test func aFileThatEndsEarlyStopsWhereItsPixelsDo() throws {
        let url = try TestPNG.file(Self.read[0], width: Self.width, height: Self.height)
        defer { try? FileManager.default.removeItem(at: url) }
        // Cut in the middle of its pixels: the first piece is there, the last isn't.
        let data = try Data(contentsOf: url)
        try data.prefix(data.count * 2 / 3).write(to: url)
        let bands = try #require(PictureText.Bands(fileAt: url))
        #expect(bands.image(of: bands.pieces[0]) != nil)
        #expect(bands.image(of: bands.pieces[1]) == nil)
    }

    @Test func runsMayStartAmongTheRowsReadLastAndNoFurtherBack() throws {
        let url = try TestPNG.file(Self.read[4], width: Self.width, height: 1000)
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = try #require(PNGBands(data: try Data(contentsOf: url), overlap: 100))
        let decoded = try PictureText.image(at: url)
        let whole = try #require(decoded.dataProvider?.data as Data?)
        func matches(_ range: Range<Int>) -> Bool {
            guard let run = rows.rows(range)?.data as Data? else { return false }
            return range.allSatisfy { row in
                let offset = (row - range.lowerBound) * rows.bytesPerRow
                return run[offset ..< offset + rows.bytesPerRow].elementsEqual(whole[row * decoded.bytesPerRow ..< row * decoded.bytesPerRow + rows.bytesPerRow])
            }
        }
        #expect(matches(0 ..< 400))
        // Back 100 rows: from the rows read; then past a gap of rows never asked for.
        #expect(matches(300 ..< 500))
        #expect(matches(700 ..< 800))
        #expect(rows.rows(599 ..< 900) == nil)
    }
}

/// PNGs of every kind, written here: rows filtered in turn with each of the five filters, sub-byte samples packed,
/// 16-bit samples big-endian, Adam7 passes when interlaced.
enum TestPNG {
    static func file(_ kind: PictureBandsTests.Kind, width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "bands-\(UUID().uuidString).png")
        try make(kind, width: width, height: height).write(to: url)
        return url
    }

    static func make(_ kind: PictureBandsTests.Kind, width: Int, height: Int) -> Data {
        let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][Int(kind.colorType)]!
        let depth = Int(kind.depth), maximum = (1 << depth) - 1
        var seed: UInt32 = 7
        func random(_ below: Int) -> Int {
            seed = seed &* 1_103_515_245 &+ 12345
            return Int(seed >> 16) % below
        }
        // Gradients with noise; alpha clear, opaque, half, and anything between.
        var samples = [[Int]](repeating: [], count: height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                for c in 0 ..< channels {
                    if let palette = kind.palette {
                        samples[y].append((x * 7 + y * 3 + random(3)) % palette)
                    } else if (kind.colorType == 4 || kind.colorType == 6), c == channels - 1 {
                        samples[y].append([0, maximum, maximum, random(maximum + 1), maximum / 2][(x / 3 + y) % 5])
                    } else {
                        samples[y].append(((x * (c + 1) * 37 + y * 11) * maximum / (width * 40) + random(maximum / 16 + 1)) % (maximum + 1))
                    }
                }
            }
        }
        let unit = max(1, channels * depth / 8)
        func packed(_ row: [Int]) -> [UInt8] {
            switch depth {
            case 16: return row.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }
            case 8: return row.map { UInt8($0) }
            default:
                let perByte = 8 / depth
                return stride(from: 0, to: row.count, by: perByte).map { start in
                    (0 ..< perByte).reduce(UInt8(0)) { byte, j in
                        start + j < row.count ? byte | UInt8(row[start + j] << (8 - depth * (j + 1))) : byte
                    }
                }
            }
        }
        func filtered(_ rows: [[UInt8]]) -> [UInt8] {
            var out: [UInt8] = [], above = [UInt8](repeating: 0, count: rows.first?.count ?? 0)
            for (index, row) in rows.enumerated() {
                let filter = index % 5
                out.append(UInt8(filter))
                for i in row.indices {
                    let a = i >= unit ? Int(row[i - unit]) : 0, b = Int(above[i]), c = i >= unit ? Int(above[i - unit]) : 0
                    let p = a + b - c
                    let paeth = abs(p - a) <= abs(p - b) && abs(p - a) <= abs(p - c) ? a : (abs(p - b) <= abs(p - c) ? b : c)
                    let prediction = [0, a, b, (a + b) / 2, paeth][filter]
                    out.append(UInt8(truncatingIfNeeded: Int(row[i]) - prediction))
                }
                above = row
            }
            return out
        }
        var raw: [UInt8] = []
        if kind.interlaced {
            for (x0, y0, dx, dy) in [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)] {
                let xs = Array(stride(from: x0, to: width, by: dx)), ys = Array(stride(from: y0, to: height, by: dy))
                guard !xs.isEmpty, !ys.isEmpty else { continue }
                raw += filtered(ys.map { y in packed(xs.flatMap { x in samples[y][x * channels ..< (x + 1) * channels] }) })
            }
        } else {
            raw = filtered(samples.map(packed))
        }

        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        func chunk(_ type: String, _ body: [UInt8]) {
            png += bigEndian(UInt32(body.count))
            let typed = Array(type.utf8) + body
            png += typed + bigEndian(crc32(typed))
        }
        chunk("IHDR", bigEndian(UInt32(width)) + bigEndian(UInt32(height)) + [kind.depth, kind.colorType, 0, 0, kind.interlaced ? 1 : 0])
        for (type, body) in kind.chunks { chunk(type, body) }
        if let palette = kind.palette { chunk("PLTE", (0 ..< palette).flatMap { [UInt8($0 * 37 % 256), UInt8($0 * 91 % 256), UInt8($0 * 13 % 256)] }) }
        if let transparency = kind.transparency { chunk("tRNS", transparency) }
        let pixels = zlib(raw)
        // In chunks of 8 KB, as an encoder writes them.
        for start in stride(from: 0, to: pixels.count, by: 8192) { chunk("IDAT", Array(pixels[start ..< min(start + 8192, pixels.count)])) }
        chunk("IEND", [])
        return Data(png)
    }

    /// An iCCP chunk's body holding the profile of the color space named `name`.
    static func profileChunk(_ name: CFString) -> [UInt8] {
        let profile = CGColorSpace(name: name)!.copyICCData()! as Data
        return Array("Profile".utf8) + [0, 0] + zlib(Array(profile))
    }

    private static func zlib(_ bytes: [UInt8]) -> [UInt8] {
        let deflated = try! (Data(bytes) as NSData).compressed(using: .zlib) as Data
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return [0x78, 0x9C] + Array(deflated) + bigEndian(b << 16 | a)
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)]
    }

    private static let table: [UInt32] = (0 ..< 256).map { n in
        (0 ..< 8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        ~bytes.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 255)] ^ ($0 >> 8) }
    }
}
