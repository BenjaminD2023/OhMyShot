import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OMSCore

struct HistoryStoreTests {
    private func makeStore() -> HistoryStore {
        HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString)"))
    }

    @Test func addedItemsAreListedNewestFirst() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let older = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 20, appName: "Safari", date: .now.addingTimeInterval(-60))
        let newer = try store.add(data: Data([2]), fileExtension: "png", kind: .screenshot, pixelWidth: 30, pixelHeight: 40, appName: nil)
        #expect(store.items().map(\.id) == [newer.id, older.id])
        #expect(FileManager.default.contents(atPath: store.fileURL(for: older).path(percentEncoded: false)) == Data([1]))
    }

    /// The URL API's `add-quick-access-overlay` copies the user's file: it stays where it was.
    @Test func aCopiedPictureKeepsItsNameAndSizeAndTheFileStays() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "My Shot.PNG")
        let context = try #require(CGContext(
            data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let item = try await store.add(copyOf: source)
        #expect(item.kind == .screenshot)
        #expect(item.pixelWidth == 3 && item.pixelHeight == 2)
        #expect(item.fileName == "My Shot.png")
        #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        #expect(FileManager.default.contents(atPath: store.fileURL(for: item).path(percentEncoded: false)) == FileManager.default.contents(atPath: source.path(percentEncoded: false)))
        #expect(store.items().map(\.id) == [item.id])
    }

    @Test func aFileThatIsNoPictureIsNotCopied() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let source = FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        await #expect(throws: (any Error).self) { try await store.add(copyOf: source) }
        #expect(store.items().isEmpty)
    }

    @Test func deletingRemovesTheFileAndTheRecord() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        store.delete(item)
        #expect(store.items().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: item).path(percentEncoded: false)))
    }

    @Test func expiredItemsAreRemovedByRetention() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let now = Date()
        let old = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, date: now.addingTimeInterval(-2 * 86_400))
        let fresh = try store.add(data: Data([2]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, date: now.addingTimeInterval(-3_600))
        #expect(store.removeExpired(retention: .oneDay, now: now) == 1)
        #expect(store.items().map(\.id) == [fresh.id])
        #expect(store.item(id: old.id) == nil)
    }

    @Test func neverRetentionKeepsOnlyCapturesStillOnScreen() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        _ = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, date: .now.addingTimeInterval(-60))
        let onScreen = try store.add(data: Data([2]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        #expect(store.removeExpired(retention: .never, keeping: [onScreen.id]) == 1)
        #expect(store.items().map(\.id) == [onScreen.id])
    }

    @Test func expiredItemsCanBeCountedBeforeRemoving() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let now = Date()
        _ = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, date: now.addingTimeInterval(-2 * 86_400))
        _ = try store.add(data: Data([2]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, date: now.addingTimeInterval(-60))
        #expect(store.expired(retention: .oneDay, now: now).count == 1)
        #expect(store.items().count == 2)
    }

    @Test func recordingsKeepTheirDuration() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "mp4", kind: .recording, pixelWidth: 1920, pixelHeight: 1080, appName: nil, duration: 12.5)
        #expect(store.item(id: item.id)?.duration == 12.5)
        #expect(store.item(id: item.id)?.kind == .recording)
    }

    @Test func expiryNeverRemovesCapturesStillOnScreen() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let now = Date()
        let old = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil, date: now.addingTimeInterval(-2 * 86_400))
        #expect(store.removeExpired(retention: .oneDay, keeping: [old.id], now: now) == 0)
        #expect(store.item(id: old.id) != nil)
    }

    @Test func markingUpKeepsTheOriginalAndTheMarksBesideTheCapture() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 20, appName: nil)
        let marked = try store.replaceImage(of: item, with: Data([2]), pixelWidth: 8, pixelHeight: 6, annotations: Data([9]))
        #expect(marked.pixelWidth == 8 && marked.pixelHeight == 6)
        #expect(store.item(id: item.id)?.pixelWidth == 8)
        #expect(FileManager.default.contents(atPath: store.fileURL(for: item).path(percentEncoded: false)) == Data([2]))
        #expect(FileManager.default.contents(atPath: store.originalURL(for: item).path(percentEncoded: false)) == Data([1]))
        // Marking up again keeps the first original.
        try store.replaceImage(of: marked, with: Data([3]), pixelWidth: 8, pixelHeight: 6, annotations: Data([9]))
        #expect(FileManager.default.contents(atPath: store.originalURL(for: item).path(percentEncoded: false)) == Data([1]))
        // The extra files are never listed as captures.
        #expect(store.items().count == 1)
    }

    @Test func deletingAMarkedUpCaptureLeavesNothingBehind() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 20, appName: nil)
        try store.replaceImage(of: item, with: Data([2]), pixelWidth: 10, pixelHeight: 20, annotations: Data([9]))
        store.delete(item)
        let left = try FileManager.default.contentsOfDirectory(atPath: store.directory.path(percentEncoded: false))
        #expect(left.isEmpty)
    }

    @Test func restoringTheOriginalForgetsTheMarks() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 20, appName: nil)
        let marked = try store.replaceImage(of: item, with: Data([2]), pixelWidth: 10, pixelHeight: 20, annotations: Data([9]))
        try store.restoreOriginal(of: marked)
        #expect(FileManager.default.contents(atPath: store.fileURL(for: item).path(percentEncoded: false)) == Data([1]))
        #expect(!store.hasOriginal(item))
        #expect(!FileManager.default.fileExists(atPath: store.annotationsURL(for: item).path(percentEncoded: false)))
    }

    @Test func anEditedRecordingKeepsTheRecordingAsItWasMade() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "mp4", kind: .recording, pixelWidth: 1920, pixelHeight: 1080, appName: nil, duration: 12)
        let edited = FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString).mp4")
        try Data([2]).write(to: edited)
        let trimmed = try store.replaceRecording(of: item, withFileAt: edited, pixelWidth: 960, pixelHeight: 540, duration: 5)
        #expect((trimmed.pixelWidth, trimmed.pixelHeight, trimmed.duration) == (960, 540, 5))
        #expect(store.item(id: item.id)?.duration == 5)
        #expect(FileManager.default.contents(atPath: store.fileURL(for: item).path(percentEncoded: false)) == Data([2]))
        #expect(FileManager.default.contents(atPath: store.originalURL(for: item).path(percentEncoded: false)) == Data([1]))
        #expect(!FileManager.default.fileExists(atPath: edited.path(percentEncoded: false)))
        // Editing again keeps the first original.
        let again = FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString).mp4")
        try Data([3]).write(to: again)
        try store.replaceRecording(of: trimmed, withFileAt: again, pixelWidth: 960, pixelHeight: 540, duration: 4)
        #expect(FileManager.default.contents(atPath: store.fileURL(for: item).path(percentEncoded: false)) == Data([3]))
        #expect(FileManager.default.contents(atPath: store.originalURL(for: item).path(percentEncoded: false)) == Data([1]))
        #expect(store.items().count == 1)
    }

    @Test func studioFilmsACopyThatStaysPutWhenItsMovieTakesTheRecordingsPlace() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "mp4", kind: .recording, pixelWidth: 1600, pixelHeight: 1000, appName: nil, duration: 4)
        let source = try store.studioSource(for: item)
        #expect(FileManager.default.contents(atPath: source.path(percentEncoded: false)) == Data([1]))
        #expect(!store.hasStudioMovie(item))
        let exported = FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString).mp4")
        try Data([2]).write(to: exported)
        let movie = try store.replaceStudioMovie(of: item, withFileAt: exported, pixelWidth: 1760, pixelHeight: 1160, duration: 4, project: Data([7]))
        #expect((movie.pixelWidth, movie.pixelHeight) == (1760, 1160))
        #expect(store.hasStudioMovie(item))
        #expect(store.studioMovieProject(of: item) == Data([7]))
        #expect(FileManager.default.contents(atPath: store.fileURL(for: item).path(percentEncoded: false)) == Data([2]))
        // The copy Studio films is where it was, as it was.
        #expect(try store.studioSource(for: item) == source)
        #expect(FileManager.default.contents(atPath: source.path(percentEncoded: false)) == Data([1]))
        // A second movie replaces the first and leaves the copy alone.
        try Data([3]).write(to: exported)
        try store.replaceStudioMovie(of: movie, withFileAt: exported, pixelWidth: 1760, pixelHeight: 1160, duration: 3, project: Data([8]))
        #expect(FileManager.default.contents(atPath: store.fileURL(for: item).path(percentEncoded: false)) == Data([3]))
        #expect(store.studioMovieProject(of: item) == Data([8]))
        #expect(FileManager.default.contents(atPath: source.path(percentEncoded: false)) == Data([1]))
        #expect(store.items().count == 1)
        store.delete(movie)
        #expect(!store.hasStudioProject(item))
    }

    @Test func aStudioProjectThatLostItsRecordingIsNotGivenTheMovieInstead() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "mp4", kind: .recording, pixelWidth: 10, pixelHeight: 10, appName: nil, duration: 1)
        let exported = FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString).mp4")
        try Data([2]).write(to: exported)
        try store.replaceStudioMovie(of: item, withFileAt: exported, pixelWidth: 10, pixelHeight: 10, duration: 1, project: Data())
        try FileManager.default.removeItem(at: store.studioSourceURL(for: item))
        #expect(throws: CocoaError.self) { try store.studioSource(for: item) }
    }

    @Test func aScreenshotKeepsItsScaleItsWindowTitleAndHowItWasNamed() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(
            data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 800, pixelHeight: 600, appName: "Safari",
            pixelsPerPoint: 2, windowTitle: "Apple", isTemplateNamed: true
        )
        let read = try #require(store.item(id: item.id))
        #expect(read.pixelsPerPoint == 2 && read.windowTitle == "Apple" && read.isTemplateNamed == true)
        // Marks drawn in the editor change the picture, not what the record knows of it.
        let marked = try store.replaceImage(of: item, with: Data([2]), pixelWidth: 900, pixelHeight: 700, annotations: Data("{}".utf8))
        #expect(marked.pixelsPerPoint == 2 && marked.windowTitle == "Apple" && marked.isTemplateNamed == true)
        let restored = try store.restoreOriginal(of: marked)
        #expect(store.item(id: restored.id)?.windowTitle == "Apple")
    }

    @Test func aRecordFromBeforeTheseFieldsExistedStillReads() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 4, pixelHeight: 4, appName: nil)
        let read = try #require(store.item(id: item.id))
        #expect(read.pixelsPerPoint == nil && read.windowTitle == nil && read.isTemplateNamed == nil)
    }

    @Test func aFilesRecordIsFoundByItsPath() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let first = try store.add(data: Data([1]), name: "Shot", fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        _ = try store.add(data: Data([2]), name: "Other", fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        #expect(store.item(forFileAt: store.fileURL(for: first))?.id == first.id)
        let outside = FileManager.default.temporaryDirectory.appending(path: "Shot.png")
        #expect(store.item(forFileAt: outside) == nil)
    }

    @Test func aFileWithNoRecordOrARecordWithNoFileIsNoCapture() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let kept = try store.add(data: Data([1]), name: "Shot", fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        let stray = store.directory.appending(path: "Stray.png")
        try Data([3]).write(to: stray)
        #expect(store.item(forFileAt: stray) == nil)
        try FileManager.default.removeItem(at: store.fileURL(for: kept))
        #expect(store.item(forFileAt: store.fileURL(for: kept)) == nil)
    }
}
