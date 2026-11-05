import Foundation
import ImageIO
import Testing
@testable import OMSCore

/// The picture Settings' Test Upload sends.
struct UploaderTestPictureTests {
    @Test func theTestPictureIsASmallPNG() throws {
        let data = try Uploader.testPicture()
        // The PNG signature.
        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(data.count < 16 * 1024)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 160 && image.height == 100)
    }
}
