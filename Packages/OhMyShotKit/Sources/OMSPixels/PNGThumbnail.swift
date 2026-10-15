import Compression
import CoreGraphics
import Foundation

/// A thumbnail of the top left of a PNG, made as the file is read: the rows wanted are inflated one at a time and
/// averaged down into the thumbnail, so memory stays a few rows wide however large the picture is, and the rest
/// of a tall picture is never read.
///
/// ImageIO cannot do this for the history. Its thumbnail call is bounded, but frees its working blocks into the
/// allocator's cache, where they stay dirty (a History window of 120 captures left 98 MB behind); drawing the
/// decoded picture takes all of it at once, 225 MB for a long scrolling capture. Only the PNGs this app writes are
/// read here (8 bits a channel, with or without alpha, one pass, a profile or sRGB, no orientation); anything
/// else gives nil, for the caller to decode another way.
public enum PNGThumbnail {
    /// The part of the PNG in `data` that `part` gives for a picture of its size, at most `maxPixels` on its longer
    /// side, or nil when `data` is not a PNG this reads.
    public static func make(from data: Data, maxPixels: Int, part: (_ width: Int, _ height: Int) -> CGRect) -> CGImage? {
        guard let header = Header(data), header.bitDepth == 8, !header.interlaced, header.width > 0, header.height > 0,
              let bytesPerPixel = header.bytesPerPixel, let space = header.colorSpace else { return nil }
        let shown = part(header.width, header.height)
        let partWidth = min(header.width, Int(shown.width)), partHeight = min(header.height, Int(shown.height))
        guard partWidth > 0, partHeight > 0, shown.origin == .zero else { return nil }
        let scale = min(1, Double(maxPixels) / Double(max(partWidth, partHeight, 1)))
        let width = max(1, Int((Double(partWidth) * scale).rounded())), height = max(1, Int((Double(partHeight) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let bitmap = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        let rowBytes = context.bytesPerRow
        let emit = { (index: Int, pixels: UnsafePointer<UInt8>) in
            if index < height { (bitmap + index * rowBytes).update(from: pixels, count: width * 4) }
        }
        let rows = RowReader(header, rowBytes: 1 + header.width * bytesPerPixel)
        let averager = Averager(from: (partWidth, partHeight), to: (width, height))
        let length = partWidth * bytesPerPixel
        let previous = UnsafeMutablePointer<UInt8>.allocate(capacity: length), current = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        defer { previous.deallocate(); current.deallocate() }
        previous.initialize(repeating: 0, count: length)
        current.initialize(repeating: 0, count: length)
        var above = previous, here = current
        for _ in 0 ..< partHeight {
            guard let raw = rows.next() else { return nil }
            unfilter(raw, into: here, above: above, length: length, bytesPerPixel: bytesPerPixel)
            averager.add(here, bytesPerPixel: bytesPerPixel, emit: emit)
            swap(&above, &here)
        }
        averager.finish(emit: emit)
        return context.makeImage()
    }

    /// The PNG filters, undone for the first `length` bytes of a row: the card's part of it.
    private static func unfilter(
        _ raw: UnsafePointer<UInt8>, into current: UnsafeMutablePointer<UInt8>, above previous: UnsafePointer<UInt8>, length: Int, bytesPerPixel bpp: Int
    ) {
        let line = raw + 1
        switch raw[0] {
        case 1:
            for i in 0 ..< length { current[i] = line[i] &+ (i >= bpp ? current[i - bpp] : 0) }
        case 2:
            for i in 0 ..< length { current[i] = line[i] &+ previous[i] }
        case 3:
            for i in 0 ..< length {
                let left = i >= bpp ? Int(current[i - bpp]) : 0
                current[i] = line[i] &+ UInt8((left + Int(previous[i])) / 2)
            }
        case 4:
            for i in 0 ..< length {
                let a = i >= bpp ? Int(current[i - bpp]) : 0, b = Int(previous[i]), c = i >= bpp ? Int(previous[i - bpp]) : 0
                let p = a + b - c
                let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                current[i] = line[i] &+ UInt8(pa <= pb && pa <= pc ? a : (pb <= pc ? b : c))
            }
        default:
            current.update(from: line, count: length)
        }
    }

    /// What a PNG says of its picture before its pixels: size, format, and color.
    struct Header {
        var width = 0, height = 0, bitDepth = 0, colorType = 0
        var interlaced = true
        var colorSpace: CGColorSpace?
        /// Where the first IDAT chunk's data begins in `data`.
        var pixelsStart = 0
        let data: Data

        init?(_ data: Data) {
            self.data = data
            let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            guard data.count > 33, data.prefix(8).elementsEqual(signature) else { return nil }
            var profile: CGColorSpace?
            var isSRGB = false
            var offset = data.startIndex + 8
            var found = false
            while !found, offset + 12 <= data.endIndex {
                let length = Int(data.uint32(at: offset)), body = offset + 8
                guard body + length + 4 <= data.endIndex else { return nil }
                switch String(decoding: data[offset + 4 ..< offset + 8], as: UTF8.self) {
                case "IHDR" where length == 13:
                    width = Int(data.uint32(at: body)); height = Int(data.uint32(at: body + 4))
                    bitDepth = Int(data[body + 8]); colorType = Int(data[body + 9]); interlaced = data[body + 12] != 0
                case "iCCP":
                    profile = Self.profile(in: data[body ..< body + length])
                case "sRGB":
                    isSRGB = true
                case "IDAT":
                    pixelsStart = offset
                    found = true
                default:
                    break
                }
                offset = body + length + 4
            }
            guard found, width > 0 else { return nil }
            colorSpace = (profile ?? (isSRGB ? CGColorSpace(name: CGColorSpace.sRGB) : nil)).flatMap { $0.supportsOutput ? $0 : nil }
        }

        /// 4 for RGBA, 3 for RGB; nil for other color types.
        var bytesPerPixel: Int? {
            switch colorType {
            case 6: 4
            case 2: 3
            default: nil
            }
        }

        /// The profile an iCCP chunk holds: a name, a zero, the method (0), then the deflated profile.
        private static func profile(in chunk: Data) -> CGColorSpace? {
            guard let end = chunk.firstIndex(of: 0), end + 3 < chunk.endIndex, chunk[end + 1] == 0 else { return nil }
            // Past the zlib header, which the decoder does not take.
            let deflated = Data(chunk[(end + 4)...])
            guard let bytes = try? (deflated as NSData).decompressed(using: .zlib) else { return nil }
            return CGColorSpace(iccData: bytes)
        }
    }

    /// Inflates a PNG's pixel data a row at a time, reading the file's chunks as it needs them.
    final class RowReader {
        private var stream = compression_stream(dst_ptr: UnsafeMutablePointer(bitPattern: 1)!, dst_size: 0, src_ptr: UnsafePointer(bitPattern: 1)!, src_size: 0, state: nil)
        private let data: Data
        /// The next byte to inflate, and where the chunk it is in ends.
        private var position: Int
        private var chunkEnd: Int
        private var finished = false
        private let row: UnsafeMutablePointer<UInt8>
        private let rowBytes: Int

        init(_ header: Header, rowBytes: Int) {
            data = header.data
            self.rowBytes = rowBytes
            row = .allocate(capacity: rowBytes)
            let length = Int(header.data.uint32(at: header.pixelsStart))
            // Past the chunk's header and the zlib header.
            position = header.pixelsStart + 8 + 2
            chunkEnd = header.pixelsStart + 8 + length
            compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        }

        /// The next row, filter byte first, or nil at the end of the data or on an error. Good until the next call.
        func next() -> UnsafePointer<UInt8>? {
            var filled = 0
            while filled < rowBytes, !finished {
                // With the last chunk used up, the decoder is told to finish: it holds back what it has until then.
                let more = position < chunkEnd || advance()
                let before = filled
                let status: compression_status = data.withUnsafeBytes { whole in
                    stream.src_ptr = more ? whole.baseAddress!.assumingMemoryBound(to: UInt8.self) + (position - data.startIndex) : UnsafePointer(bitPattern: 1)!
                    stream.src_size = more ? chunkEnd - position : 0
                    stream.dst_ptr = row + filled
                    stream.dst_size = rowBytes - filled
                    let status = compression_stream_process(&stream, more ? 0 : Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    if more { position = chunkEnd - stream.src_size }
                    filled = rowBytes - stream.dst_size
                    return status
                }
                if status == COMPRESSION_STATUS_ERROR { return nil }
                if status == COMPRESSION_STATUS_END || (!more && filled == before) { finished = true }
            }
            return filled == rowBytes ? UnsafePointer(row) : nil
        }

        /// Moves to the next IDAT chunk's data; false when the next chunk is not IDAT or the file ends.
        private func advance() -> Bool {
            let header = chunkEnd + 4
            guard header + 8 <= data.endIndex, data[header + 4 ..< header + 8].elementsEqual("IDAT".utf8) else { return false }
            let length = Int(data.uint32(at: header))
            guard header + 8 + length <= data.endIndex else { return false }
            position = header + 8
            chunkEnd = header + 8 + length
            return true
        }

        deinit {
            compression_stream_destroy(&stream)
            row.deallocate()
        }
    }

    /// Averages rows of pixels down to a smaller size as they come, in premultiplied BGRA, one output row at a time.
    final class Averager {
        private let fromWidth: Int, fromHeight: Int, toWidth: Int, toHeight: Int
        /// For each source column, the output column it starts in, and how much of it goes there and into the next one
        /// (in output columns, so that each output column's parts sum to 1).
        private let column: UnsafeMutablePointer<Int>
        private let first: UnsafeMutablePointer<Float>
        private let second: UnsafeMutablePointer<Float>
        /// One source row averaged across, and the output row being summed.
        private let line: UnsafeMutablePointer<Float>
        private let sums: UnsafeMutablePointer<Float>
        private var sumsWeight = 0.0
        private var sourceRow = 0
        private var outputRow = 0
        private let output: UnsafeMutablePointer<UInt8>

        init(from: (Int, Int), to: (Int, Int)) {
            (fromWidth, fromHeight) = from
            (toWidth, toHeight) = to
            column = .allocate(capacity: from.0)
            first = .allocate(capacity: from.0)
            second = .allocate(capacity: from.0)
            line = .allocate(capacity: to.0 * 4)
            sums = .allocate(capacity: to.0 * 4)
            output = .allocate(capacity: to.0 * 4)
            line.initialize(repeating: 0, count: to.0 * 4)
            sums.initialize(repeating: 0, count: to.0 * 4)
            let across = Double(to.0) / Double(from.0)
            for x in 0 ..< from.0 {
                let start = Double(x) * across, end = Double(x + 1) * across
                let bin = min(Int(start), to.0 - 1)
                let inBin = max(0, min(end, Double(bin + 1)) - start)
                column[x] = bin
                first[x] = Float(inBin)
                second[x] = bin + 1 < to.0 ? Float(end - start - inBin) : 0
            }
        }

        /// Takes the next row of the picture (RGB or RGBA bytes); calls `emit` with each output row once it is done.
            func add(_ pixels: UnsafePointer<UInt8>, bytesPerPixel bpp: Int, emit: (Int, UnsafePointer<UInt8>) -> Void) {
            line.update(repeating: 0, count: toWidth * 4)
            for x in 0 ..< fromWidth {
                let p = pixels + x * bpp
                let alpha = bpp == 4 ? Float(p[3]) : 255
                let scale = alpha / 255
                let b = Float(p[2]) * scale, g = Float(p[1]) * scale, r = Float(p[0]) * scale
                let bin = line + column[x] * 4, a = first[x], c = second[x]
                bin[0] += b * a; bin[1] += g * a; bin[2] += r * a; bin[3] += alpha * a
                if c > 0 {
                    bin[4] += b * c; bin[5] += g * c; bin[6] += r * c; bin[7] += alpha * c
                }
            }
            // This source row covers [top, bottom) in output rows.
            let down = Double(toHeight) / Double(fromHeight)
            let top = Double(sourceRow) * down, bottom = top + down
            sourceRow += 1
            let boundary = Double(outputRow + 1)
            if bottom <= boundary + 1e-9 {
                accumulate(Float(bottom - top))
                sumsWeight += bottom - top
            } else {
                let here = max(0, boundary - top), there = bottom - boundary
                accumulate(Float(here))
                sumsWeight += here
                emitRow(emit)
                outputRow += 1
                sums.update(repeating: 0, count: toWidth * 4)
                sumsWeight = there
                accumulate(Float(there))
            }
        }

        /// Gives the last output row.
        func finish(emit: (Int, UnsafePointer<UInt8>) -> Void) {
            if sumsWeight > 0 { emitRow(emit) }
        }

        deinit {
            column.deallocate(); first.deallocate(); second.deallocate(); line.deallocate(); sums.deallocate(); output.deallocate()
        }

            private func accumulate(_ weight: Float) {
            for i in 0 ..< toWidth * 4 { sums[i] += line[i] * weight }
        }

            private func emitRow(_ emit: (Int, UnsafePointer<UInt8>) -> Void) {
            let scale = Float(1 / sumsWeight)
            for i in 0 ..< toWidth * 4 { output[i] = UInt8(max(0, min(255, (sums[i] * scale).rounded()))) }
            emit(outputRow, output)
        }
    }
}

private extension Data {
    /// The big-endian 32-bit number at `offset`.
    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
}
