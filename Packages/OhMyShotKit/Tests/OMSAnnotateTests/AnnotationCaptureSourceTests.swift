import CoreGraphics
import Foundation
import OMSCore
import Testing
@testable import OMSAnnotate

struct AnnotationCaptureSourceTests {
    private struct Fixture {
        let history = HistoryStore(directory: URL.temporaryDirectory.appending(path: UUID().uuidString))
        let item: HistoryItem
        var document: AnnotationDocument

        init(base: CGImage = makeBase()) throws {
            let size = CGSize(width: base.width, height: base.height)
            let mark = Annotation(shape: .redaction(Redaction(rect: CGRect(x: 10, y: 10, width: 20, height: 20))), style: Style(color: .black))
            document = AnnotationDocument(pixelSize: size, scale: 1, items: [mark])
            item = try history.add(data: ImageExporter.encoded(base, as: .png), fileExtension: "png", kind: .screenshot,
                                   pixelWidth: base.width, pixelHeight: base.height, appName: nil)
            let flattened = try #require(AnnotationRenderer.flatten(document, base: base))
            try history.replaceImage(of: item, with: ImageExporter.encoded(flattened, as: .png), pixelWidth: base.width, pixelHeight: base.height,
                                     annotations: JSONEncoder().encode(document))
        }
    }

    enum Damage: CaseIterable {
        case missingMarks, newerFormat, wrongSize, empty, badScale, badCanvas, duplicateID, invalidRedaction, invalidTransform, missingOriginal, corruptOriginal
    }

    @Test(arguments: Damage.allCases) func brokenPairOnlyOffersTheFlattenedPixels(damage: Damage) async throws {
        var fixture = try Fixture()
        let history = fixture.history, item = fixture.item
        defer { try? FileManager.default.removeItem(at: history.directory) }
        let annotations = history.annotationsURL(for: item)
        switch damage {
        case .missingMarks: try FileManager.default.removeItem(at: annotations)
        case .newerFormat: try Data(#"{"items":[{"futureShape":{}}]}"#.utf8).write(to: annotations)
        case .missingOriginal: try FileManager.default.removeItem(at: history.originalURL(for: item))
        case .corruptOriginal: try Data("bad image".utf8).write(to: history.originalURL(for: item))
        default:
            switch damage {
            case .wrongSize: fixture.document.pixelSize.width += 1
            case .empty: fixture.document.items = []
            case .badScale: fixture.document.scale = 0
            case .badCanvas: fixture.document.canvas = .zero
            case .duplicateID: fixture.document.items += fixture.document.items
            case .invalidRedaction: fixture.document.items[0].shape = .redaction(Redaction(rect: .zero))
            case .invalidTransform: fixture.document.transform = CaptureTransform(size: CGSize(width: 100_000, height: 100_000))
            default: break
            }
            try JSONEncoder().encode(fixture.document).write(to: annotations)
        }
        let loaded = try #require(await AnnotationCaptureSource.load(item, from: history))
        #expect(loaded.requiresFlattenedCopy && loaded.document == nil)
        #expect(Pixels(loaded.image)[20, 20].r == 0)
    }

    @Test func recoveringAndRestoringACopyNeverTouchesTheDamagedCapture() async throws {
        let fixture = try Fixture(), history = fixture.history, item = fixture.item
        defer { try? FileManager.default.removeItem(at: history.directory) }
        let badMarks = Data("broken".utf8)
        try badMarks.write(to: history.annotationsURL(for: item))
        let original = try Data(contentsOf: history.originalURL(for: item))
        let shown = try Data(contentsOf: history.fileURL(for: item))
        let loaded = try #require(await AnnotationCaptureSource.load(item, from: history))
        let copy = try await loaded.itemForEditing(item, in: history)
        #expect(copy.id != item.id)
        try history.replaceImage(of: copy, with: shown, pixelWidth: copy.pixelWidth, pixelHeight: copy.pixelHeight,
                                 annotations: JSONEncoder().encode(fixture.document))
        let restored = try history.restoreOriginal(of: copy)
        let reopened = try #require(await AnnotationCaptureSource.load(restored, from: history))
        #expect(!reopened.requiresFlattenedCopy && reopened.document == nil)
        #expect(Pixels(reopened.image)[20, 20].r == 0)
        #expect(try Data(contentsOf: history.fileURL(for: item)) == shown)
        #expect(try Data(contentsOf: history.originalURL(for: item)) == original)
        #expect(try Data(contentsOf: history.annotationsURL(for: item)) == badMarks)
    }

    @Test(arguments: [
        CGRect(x: 0, y: 0, width: 1e30, height: 40),
        CGRect(x: 0, y: 0, width: 64, height: 262_145),
        CGRect(x: 0.5, y: 0, width: 262_144, height: 2),
        CGRect(x: 0, y: 0, width: 16_385, height: 16_384)
    ])
    func oversizedCanvasOnlyOpensTheFlattenedRendition(canvas: CGRect) async throws {
        var fixture = try Fixture()
        let history = fixture.history, item = fixture.item
        defer { try? FileManager.default.removeItem(at: history.directory) }
        fixture.document.canvas = canvas
        let sidecar = try JSONEncoder().encode(fixture.document)
        try sidecar.write(to: history.annotationsURL(for: item))

        let loaded = try #require(await AnnotationCaptureSource.load(item, from: history))
        #expect(loaded.requiresFlattenedCopy && loaded.document == nil)
        #expect(Pixels(loaded.image)[20, 20].r == 0)
        #expect(try Data(contentsOf: history.annotationsURL(for: item)) == sidecar)
        #expect(history.items().map(\.id) == [item.id])
    }

    @Test(arguments: [
        CGRect(x: 10, y: 10, width: 64, height: 40),
        CGRect(x: -10, y: -20, width: AnnotationDocument.maxPictureSide, height: 40),
        CGRect(x: -10, y: -20, width: 10_000, height: 10_000)
    ])
    func inBudgetCropsAndExpandedCanvasesStayEditable(canvas: CGRect) async throws {
        var fixture = try Fixture()
        let history = fixture.history, item = fixture.item
        defer { try? FileManager.default.removeItem(at: history.directory) }
        fixture.document.canvas = canvas
        try JSONEncoder().encode(fixture.document).write(to: history.annotationsURL(for: item))

        let loaded = try #require(await AnnotationCaptureSource.load(item, from: history))
        #expect(!loaded.requiresFlattenedCopy && loaded.document == fixture.document)
    }

    @Test func aLongNativeCaptureRemainsEditableWithoutResizing() async throws {
        let fixture = try Fixture(base: makeBase(width: 2, height: AnnotationDocument.maxPictureSide + 1))
        defer { try? FileManager.default.removeItem(at: fixture.history.directory) }
        let loaded = try #require(await AnnotationCaptureSource.load(fixture.item, from: fixture.history))
        #expect(!loaded.requiresFlattenedCopy && loaded.document == fixture.document)
    }

    @Test(arguments: [PictureOperation.rotateRight, .flipHorizontally])
    func orientationOnlyEditsToLongCapturesReopenWithTheirMarks(operation: PictureOperation) async throws {
        let fixture = try Fixture(base: makeBase(width: 16, height: 18_000))
        defer { try? FileManager.default.removeItem(at: fixture.history.directory) }
        let document = try #require(fixture.document.applying(operation))
        try JSONEncoder().encode(document).write(to: fixture.history.annotationsURL(for: fixture.item))
        let loaded = try #require(await AnnotationCaptureSource.load(fixture.item, from: fixture.history))
        #expect(!loaded.requiresFlattenedCopy && loaded.document == document)
    }

    @Test func aValidPairKeepsItsOriginalAndEditableMarks() async throws {
        let fixture = try Fixture(), history = fixture.history, item = fixture.item
        defer { try? FileManager.default.removeItem(at: history.directory) }
        let loaded = try #require(await AnnotationCaptureSource.load(item, from: history))
        #expect(!loaded.requiresFlattenedCopy && loaded.document == fixture.document)
        #expect(Pixels(loaded.image)[20, 20].r == 255)
        #expect(try await loaded.itemForEditing(item, in: history) == item)
    }

    @Test func missingBothMarksAndRenditionNeverOpensTheOriginal() async throws {
        let fixture = try Fixture(), history = fixture.history, item = fixture.item
        defer { try? FileManager.default.removeItem(at: history.directory) }
        try FileManager.default.removeItem(at: history.annotationsURL(for: item))
        try FileManager.default.removeItem(at: history.fileURL(for: item))
        #expect(await AnnotationCaptureSource.load(item, from: history) == nil)
    }
}
