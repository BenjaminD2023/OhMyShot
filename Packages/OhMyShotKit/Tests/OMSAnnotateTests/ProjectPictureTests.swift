import CoreGraphics
import Foundation
import ImageIO
import OMSCore
import Testing
@testable import OMSAnnotate

struct ProjectPictureTests {
    private let folder = URL.temporaryDirectory.appending(path: "OhMyShotKit Project Pictures \(UUID().uuidString)", directoryHint: .isDirectory)

    private func project(gray: CGFloat) -> AnnotationProject {
        let context = CGContext(
            data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        return AnnotationProject(capture: context.makeImage()!, document: AnnotationDocument(pixelSize: CGSize(width: 8, height: 4), scale: 1))
    }

    /// The red of the picture's first pixel, 0 to 255.
    private func red(of picture: URL) throws -> UInt8 {
        let source = try #require(CGImageSourceCreateWithURL(picture as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // The context's own buffer, which lives as long as it does.
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return try #require(context.data).load(as: UInt8.self)
    }

    @Test func twoProjectsOfOneNameKeepTheirOwnPictures() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appending(path: "Projects", directoryHint: .isDirectory)
        let clientA = folder.appending(path: "Client A/Review.ohmyshot"), clientB = folder.appending(path: "Client B/Review.ohmyshot")
        let first = try await ProjectPicture.make(for: project(gray: 0), from: clientA, in: cache)
        let second = try await ProjectPicture.make(for: project(gray: 1), from: clientB, in: cache)
        #expect(first != second)
        #expect(first.lastPathComponent == "Review.png")
        #expect(second.lastPathComponent == "Review.png")
        // The first editor, saved or dragged after the second opened, still hands over its own picture.
        #expect(try red(of: first) == 0)
        #expect(try red(of: second) == 255)
        // Keeping the first's marks writes its picture alone.
        let marked = try ImageExporter.encoded(project(gray: 0.5).capture, as: .png)
        try FileManager.default.createDirectory(at: clientA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try project(gray: 0).keep(at: clientA, preview: marked, previewURL: first, pictures: PictureStore(directory: folder.appending(path: "pictures")))
        #expect(try red(of: second) == 255)
    }

    @Test func aClosedEditorsPictureGoesWithItsFolder() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appending(path: "Projects", directoryHint: .isDirectory)
        let picture = try await ProjectPicture.make(for: project(gray: 0), from: folder.appending(path: "Review.ohmyshot"), in: cache)
        await ProjectPicture.remove(picture, after: .zero).value
        #expect(!FileManager.default.fileExists(atPath: picture.deletingLastPathComponent().path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: cache.path(percentEncoded: false)))
    }

    @Test func whatAnEarlierRunLeftGoesAndAnOpenEditorsPictureStays() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appending(path: "Projects", directoryHint: .isDirectory)
        let left = try await ProjectPicture.make(for: project(gray: 0), from: folder.appending(path: "Old.ohmyshot"), in: cache)
        // As an older version kept it: under the project's name alone.
        let older = cache.appending(path: "Review.png")
        try Data([1]).write(to: older)
        let past = Date.now.addingTimeInterval(-3600)
        for item in [older, left.deletingLastPathComponent()] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: item.path(percentEncoded: false))
        }
        let start = Date.now
        let open = try await ProjectPicture.make(for: project(gray: 1), from: folder.appending(path: "Review.ohmyshot"), in: cache)
        ProjectPicture.removeLeftovers(before: start, in: cache)
        #expect(!FileManager.default.fileExists(atPath: older.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: left.deletingLastPathComponent().path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: open.path(percentEncoded: false)))
    }
}
