import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes an animated GIF a frame at a time, so a long recording never has to fit in memory.
///
/// ImageIO's own GIF writer keeps every frame until it finalizes the file (a gigabyte for ten seconds at
/// 1000×640), so each frame is encoded alone by ImageIO instead, which picks its palette and compresses it,
/// and that picture's palette and data are copied into this file as one frame among many. A frame can be
/// only the part of the picture that changed, placed where it goes, with the pixels left as they were
/// marked transparent.
final class GIFFileWriter {
    /// A frame as ImageIO encoded it on its own: its colors, the index meaning "unchanged", and its data.
    struct Frame {
        /// The palette's RGB triples, 2^(bits + 1) of them.
        var palette: [UInt8]
        var paletteBits: UInt8
        var transparentIndex: UInt8?
        /// The image data as GIF stores it: the LZW code size, the data sub-blocks, and their terminator.
        var data: [UInt8]
        /// Where it goes in the picture, in pixels from the top-left corner.
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    enum WriterError: Error {
        case couldNotCreate
    }

    let url: URL
    private let handle: FileHandle
    private var buffer = Data()
    private(set) var frameCount = 0
    private(set) var byteCount = 0

    /// Starts a GIF at `url` (replacing anything there) of `width` × `height` pixels that plays forever.
    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else { throw WriterError.couldNotCreate }
        handle = try FileHandle(forWritingTo: url)
        var header = Array("GIF89a".utf8)
        // The logical screen, with no palette of its own: each frame brings its own.
        header += Self.littleEndian(width) + Self.littleEndian(height) + [0, 0, 0]
        // NETSCAPE2.0: loop forever.
        header += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]
        buffer.append(contentsOf: header)
    }

    /// Adds `frame`, shown for `delay` hundredths of a second, over the frames before it.
    func write(_ frame: Frame, delay: Int) throws {
        var remaining = max(delay, 0)
        repeat {
            var part = min(remaining, 0xFFFF)
            // Browsers clamp one-centisecond frames. Borrow one tick from the preceding part so even
            // the remainder of a long hold respects the maker's two-centisecond minimum.
            if remaining > 0xFFFF, remaining - part == 1 { part -= 1 }
            try writePart(frame, delay: part)
            remaining -= part
        } while remaining > 0
    }

    /// Repeating a frame is idempotent under disposal 1, including a transparent delta frame. The
    /// existing pixels stay put while the full requested delay is carried by as many frames as needed.
    private func writePart(_ frame: Frame, delay: Int) throws {
        // Disposal 1 leaves the frame in place, so the next one's transparent pixels show it.
        let flags: UInt8 = 1 << 2 | (frame.transparentIndex == nil ? 0 : 1)
        var block: [UInt8] = [0x21, 0xF9, 0x04, flags] + Self.littleEndian(delay) + [frame.transparentIndex ?? 0, 0x00]
        block += [0x2C] + Self.littleEndian(frame.x) + Self.littleEndian(frame.y) + Self.littleEndian(frame.width) + Self.littleEndian(frame.height)
        block.append(0x80 | frame.paletteBits)
        block += frame.palette
        block += frame.data
        buffer.append(contentsOf: block)
        frameCount += 1
        if buffer.count >= 1 << 20 { try flush() }
    }

    /// Ends the GIF and closes its file.
    func finish() throws {
        buffer.append(0x3B)
        try flush()
        try handle.close()
    }

    /// Closes the file and removes it.
    func abandon() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    private func flush() throws {
        try handle.write(contentsOf: buffer)
        byteCount += buffer.count
        buffer.removeAll(keepingCapacity: true)
    }

    /// `image` encoded on its own by ImageIO, placed at `x`, `y`. Pixels with no alpha come back as the
    /// transparent index.
    static func encode(_ image: CGImage, x: Int, y: Int) -> Frame? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return parse([UInt8](data as Data), x: x, y: y, width: image.width, height: image.height)
    }

    /// The first frame of a GIF file: its palette (the file's, unless the frame has its own), the
    /// transparent index from its graphic control extension, and its image data.
    static func parse(_ bytes: [UInt8], x: Int, y: Int, width: Int, height: Int) -> Frame? {
        guard bytes.count > 13, bytes.starts(with: Array("GIF".utf8)) else { return nil }
        var palette: [UInt8] = []
        var paletteBits: UInt8 = 0
        var index = 13
        if bytes[10] & 0x80 != 0 {
            paletteBits = bytes[10] & 0x07
            let length = 3 << (Int(paletteBits) + 1)
            guard bytes.count > index + length else { return nil }
            palette = Array(bytes[index..<index + length])
            index += length
        }
        var transparentIndex: UInt8?
        while index < bytes.count {
            switch bytes[index] {
            case 0x21:
                // An extension: a label, then sub-blocks until an empty one.
                guard index + 2 < bytes.count else { return nil }
                var cursor = index + 2
                if bytes[index + 1] == 0xF9, cursor + 4 < bytes.count, bytes[cursor] == 4, bytes[cursor + 1] & 0x01 != 0 {
                    transparentIndex = bytes[cursor + 4]
                }
                while cursor < bytes.count, bytes[cursor] != 0 { cursor += Int(bytes[cursor]) + 1 }
                index = cursor + 1
            case 0x2C:
                guard index + 10 < bytes.count else { return nil }
                let flags = bytes[index + 9]
                var cursor = index + 10
                if flags & 0x80 != 0 {
                    paletteBits = flags & 0x07
                    let length = 3 << (Int(paletteBits) + 1)
                    guard bytes.count > cursor + length else { return nil }
                    palette = Array(bytes[cursor..<cursor + length])
                    cursor += length
                }
                guard !palette.isEmpty, cursor < bytes.count else { return nil }
                let start = cursor
                // The LZW code size, then sub-blocks until an empty one.
                cursor += 1
                while cursor < bytes.count, bytes[cursor] != 0 { cursor += Int(bytes[cursor]) + 1 }
                guard cursor < bytes.count else { return nil }
                return Frame(
                    palette: palette, paletteBits: paletteBits, transparentIndex: transparentIndex, data: Array(bytes[start...cursor]),
                    x: x, y: y, width: width, height: height
                )
            default:
                return nil
            }
        }
        return nil
    }

    private static func littleEndian(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]
    }
}
