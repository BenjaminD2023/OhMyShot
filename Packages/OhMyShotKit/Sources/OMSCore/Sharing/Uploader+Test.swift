import CoreGraphics
import Foundation

extension Uploader {
    /// What Settings' Test Upload sends to a destination: the test picture, written to a temporary file, uploaded as
    /// "OhMyShot test.png", and the file removed however it went. What the destination keeps stays there.
    /// - Throws: what `upload` throws, or the error writing the file.
    public func testUpload(to destination: UploadDestination) async throws -> UploadResult {
        let file = FileManager.default.temporaryDirectory.appending(path: "OhMyShot-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.testPicture().write(to: file)
        return try await upload(fileAt: file, to: destination, originalName: "OhMyShot test.png")
    }

    /// The small picture a test upload sends: a soft gradient with a rounded card on it, about a kilobyte.
    public static func testPicture() throws -> Data {
        let size = CGSize(width: 160, height: 100)
        guard
            let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(srgbRed: 0.55, green: 0.76, blue: 1, alpha: 1), CGColor(srgbRed: 0.83, green: 0.78, blue: 1, alpha: 1)] as CFArray,
                locations: [0, 1]
            )
        else { throw CocoaError(.fileWriteUnknown) }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        context.setFillColor(CGColor(gray: 1, alpha: 0.9))
        context.addPath(CGPath(roundedRect: CGRect(x: 36, y: 26, width: 88, height: 48), cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.fillPath()
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return try ImageExporter.encoded(image, as: .png)
    }
}
