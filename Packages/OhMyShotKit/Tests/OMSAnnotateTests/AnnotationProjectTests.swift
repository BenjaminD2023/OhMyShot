import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

struct AnnotationProjectTests {
    private let folder = URL.temporaryDirectory.appending(path: "OhMyShotKit Projects \(UUID().uuidString)", directoryHint: .isDirectory)

    private func swatch(_ width: Int, _ height: Int, gray: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func projectsCarryTheCaptureTheMarksAndTheirPictures() throws {
        let here = PictureStore(directory: folder.appending(path: "here"))
        let background = try here.add(swatch(30, 20, gray: 0.2))
        let combined = try here.add(swatch(10, 10, gray: 0.8))
        var document = AnnotationDocument(pixelSize: CGSize(width: 64, height: 48), scale: 2)
        document.backdrop = Backdrop(fill: .picture(background), padding: 0.1)
        document.items = [
            Annotation(shape: .image(PlacedImage(rect: CGRect(x: 4, y: 4, width: 10, height: 10), name: combined)), style: Style(shadow: false)),
            Annotation(shape: .text(TextBlock(origin: CGPoint(x: 1, y: 2), string: "标注")), style: Style(color: .blue)),
        ]
        let file = folder.appending(path: "Capture.ohmyshot")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try AnnotationProject(capture: swatch(64, 48, gray: 1), document: document).write(to: file, pictures: here)

        // Opened on another Mac: its picture store has none of them.
        let there = PictureStore(directory: folder.appending(path: "there"))
        let project = try AnnotationProject.read(from: file, pictures: there)
        #expect(project.document == document)
        #expect(project.capture.width == 64 && project.capture.height == 48)
        #expect(there.contains(background) && there.contains(combined))
        #expect(try Data(contentsOf: there.url(named: combined)) == Data(contentsOf: here.url(named: combined)))
        // Written again as it was read, the capture is not encoded anew.
        #expect(project.capturePNG != nil)
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func projectsFromANewerVersionAreRefused() throws {
        let data = try AnnotationProject(capture: swatch(4, 4, gray: 1), document: AnnotationDocument(pixelSize: CGSize(width: 4, height: 4), scale: 1)).data()
        var contents = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        contents["version"] = 99
        let newer = try PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0)
        #expect(throws: AnnotationProject.ReadError.self) { try AnnotationProject.read(newer) }
    }
}
