import Accelerate
import CoreGraphics
import Foundation
import OMSCore

/// The pictures `ScrollStitcher` makes of the lines it holds, in a buffer of their own or borrowed from where they lie.
nonisolated extension ScrollStitcher {
    /// A picture of `lines` lines of `length` pixels in `buffer`, which it keeps alive: as they are, or, for
    /// columns that were turned a quarter clockwise into lines, turned back.
    static func image(_ buffer: PageBuffer, lines: Int, length: Int, turned: Bool, colorSpace: CGColorSpace) -> CGImage? {
        guard turned else { return image(buffer, width: length, height: lines, colorSpace: colorSpace) }
        guard let back = PageBuffer(byteCount: lines * length * 4) else { return nil }
        var from = vImage_Buffer(data: buffer.baseAddress, height: vImagePixelCount(lines), width: vImagePixelCount(length), rowBytes: length * 4)
        var to = vImage_Buffer(data: back.baseAddress, height: vImagePixelCount(length), width: vImagePixelCount(lines), rowBytes: lines * 4)
        var clear: [UInt8] = [0, 0, 0, 0]
        vImageRotate90_ARGB8888(&from, &to, UInt8(kRotate90DegreesCounterClockwise), &clear, vImage_Flags(kvImageNoFlags))
        return image(back, width: lines, height: length, colorSpace: colorSpace)
    }

    /// A picture of the pixels in `buffer`, which it keeps alive.
    static func image(_ buffer: PageBuffer, width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage? {
        let retained = Unmanaged.passRetained(buffer)
        guard let provider = CGDataProvider(
            dataInfo: retained.toOpaque(), data: buffer.baseAddress, size: width * height * 4,
            releaseData: { info, _, _ in
                if let info { Unmanaged<PageBuffer>.fromOpaque(info).release() }
            }
        ) else {
            retained.release()
            return nil
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// A picture of `lines` lines at `base`, which must outlive drawing it.
    static func borrowedImage(_ base: UnsafeRawPointer, lines: Int, length: Int, colorSpace: CGColorSpace) -> CGImage? {
        guard let provider = CGDataProvider(dataInfo: nil, data: base, size: lines * length * 4, releaseData: { _, _, _ in }) else { return nil }
        return CGImage(
            width: length, height: lines, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: length * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
