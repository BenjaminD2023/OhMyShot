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

    @Test func concurrentCapturesWithTheSameNameKeepTheirOwnFilesAndRecords() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let items = try await withThrowingTaskGroup(of: (HistoryItem, UInt8).self) { group in
            for byte: UInt8 in 0..<16 {
                group.addTask {
                    let item = try store.add(
                        data: Data(repeating: byte, count: 128 * 1024), name: "Capture", fileExtension: "png",
                        kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil
                    )
                    return (item, byte)
                }
            }
            var result: [(HistoryItem, UInt8)] = []
            for try await pair in group { result.append(pair) }
            return result
        }
        #expect(Set(items.map { $0.0.fileName }).count == items.count)
        #expect(Set(store.items().map(\.id)) == Set(items.map { $0.0.id }))
        for (item, byte) in items {
            #expect(store.item(id: item.id)?.fileName == item.fileName)
            #expect(try Data(contentsOf: store.fileURL(for: item)) == Data(repeating: byte, count: 128 * 1024))
        }
    }

    /// A name with a slash in it (a shortcut's file may carry one) never takes another capture's file.
    @Test func aNameWithASlashKeepsItsOwnFile() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let first = try store.add(data: Data([1]), name: "b", fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        let second = try store.add(data: Data([2]), name: "a/b", fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        #expect(first.fileName == "b.png" && second.fileName == "a-b.png")
        #expect(FileManager.default.contents(atPath: store.fileURL(for: first).path(percentEncoded: false)) == Data([1]))
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

    /// A capture whose record cannot be written does not stay in the folder, where nothing would show it and no retention
    /// would remove it: one written or copied in is removed, and one moved in goes back where it was.
    @Test func aCaptureWhoseRecordCannotBeWrittenLeavesNothingBehind() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString)")
        let outside = manager.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString)")
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? manager.removeItem(at: directory)
            try? manager.removeItem(at: outside)
        }
        let store = HistoryStore(directory: directory) { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        #expect(throws: CocoaError.self) {
            try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        }
        let picture = outside.appending(path: "Picture.png")
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let png = try ImageExporter.encoded(#require(context.makeImage()), as: .png)
        try png.write(to: picture)
        await #expect(throws: CocoaError.self) { try await store.add(copyOf: picture) }
        #expect(try Data(contentsOf: picture) == png)
        let recording = outside.appending(path: "Recording.mov")
        try Data([2]).write(to: recording)
        #expect(throws: CocoaError.self) {
            try store.add(movingFileAt: recording, kind: .recording, pixelWidth: 1, pixelHeight: 1, appName: nil, duration: 1)
        }
        #expect(try Data(contentsOf: recording) == Data([2]))
        // Opened again, the history holds no capture and no file.
        let reopened = HistoryStore(directory: directory)
        #expect(reopened.items().isEmpty)
        #expect(try manager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).isEmpty)
    }

    @Test func copyingAndMovingSkipANameAlreadyClaimedByAnotherCapture() async throws {
        let store = makeStore(), manager = FileManager.default
        try manager.createDirectory(at: store.directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: store.directory) }
        let claim = store.directory.appending(path: "Capture.png.json")
        try Data().write(to: claim)
        let input = store.directory.appending(path: "input")
        try manager.createDirectory(at: input, withIntermediateDirectories: false)
        let source = input.appending(path: "Capture.png")
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let data = try ImageExporter.encoded(#require(context.makeImage()), as: .png)
        try data.write(to: source)
        let copied = try await store.add(copyOf: source)
        let moved = try store.add(movingFileAt: source, name: "Capture", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        #expect(copied.fileName == "Capture (2).png")
        #expect(moved.fileName == "Capture (3).png")
        #expect(try Data(contentsOf: claim).isEmpty)
        #expect(Set(store.items().map(\.id)) == [copied.id, moved.id])
    }

    /// A photo kept on its side, to be turned upright as it is shown (EXIF orientation 6), has its shown size in the
    /// record: when it is copied in, and again when it is put back as it was after being marked up.
    @Test func aPictureTurnedUprightKeepsItsShownSizeWhenPutBack() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let folder = FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "Photo.jpg")
        let context = try #require(CGContext(
            data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        let item = try await store.add(copyOf: source)
        #expect(item.pixelWidth == 2 && item.pixelHeight == 4)
        let marked = try store.replaceImage(of: item, with: Data([2]), pixelWidth: 2, pixelHeight: 4, annotations: Data("{}".utf8))
        let restored = try store.restoreOriginal(of: marked)
        #expect(restored.pixelWidth == 2 && restored.pixelHeight == 4)
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

    @Test func aFailedTrashKeepsTheCaptureAndAllItsSidecars() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        let marked = try store.replaceImage(of: item, with: Data([2]), pixelWidth: 1, pixelHeight: 1, annotations: Data([3]))
        try store.setText("indexed", of: marked, readFrom: #require(store.stamp(of: marked)))
        let project = store.studioURL(for: marked)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let asset = project.appending(path: "kept")
        try Data([4]).write(to: asset)
        let savedRecord = try #require(store.item(id: marked.id))
        #expect(throws: CocoaError.self) {
            try store.moveToTrash(marked) { url in
                #expect(url == store.fileURL(for: marked))
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        #expect(store.item(id: marked.id) == savedRecord)
        #expect(try Data(contentsOf: store.fileURL(for: marked)) == Data([2]))
        #expect(try Data(contentsOf: store.originalURL(for: marked)) == Data([1]))
        #expect(try Data(contentsOf: store.annotationsURL(for: marked)) == Data([3]))
        #expect(store.text(of: marked) == "indexed")
        #expect(try Data(contentsOf: asset) == Data([4]))
    }

    @Test(arguments: [false, true])
    func anUnavailableReplacementLeavesTheLastKeptMovieIntact(studio: Bool) throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "mp4", kind: .recording, pixelWidth: 10, pixelHeight: 10, appName: nil)
        let incoming = store.directory.appending(path: "edit.mp4")
        func replace(_ entry: HistoryItem, duration: Int) throws -> HistoryItem {
            if studio {
                return try store.replaceStudioMovie(of: entry, withFileAt: incoming, pixelWidth: 5, pixelHeight: 5, duration: Double(duration), project: Data([UInt8(duration)]))
            }
            return try store.replaceRecording(of: entry, withFileAt: incoming, pixelWidth: 5, pixelHeight: 5, duration: Double(duration))
        }
        #expect(throws: (any Error).self) { try replace(item, duration: 9) }
        #expect(try Data(contentsOf: store.fileURL(for: item)) == Data([1]))
        try Data([2]).write(to: incoming)
        let prior = try replace(item, duration: 8)
        let savedRecord = try #require(store.item(id: item.id))
        #expect(throws: (any Error).self) { try replace(prior, duration: 7) }
        #expect(store.item(id: item.id) == savedRecord)
        #expect(try Data(contentsOf: store.fileURL(for: item)) == Data([2]))
        #expect(try Data(contentsOf: studio ? store.studioSourceURL(for: item) : store.originalURL(for: item)) == Data([1]))
        if studio { #expect(store.studioMovieProject(of: item) == Data([8])) }
    }

    @Test func aSidecarFailureLeavesThePreviousMovieAndStudioSettingsIntact() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "mp4", kind: .recording, pixelWidth: 10, pixelHeight: 10, appName: nil)
        let incoming = store.directory.appending(path: "edit.mp4")
        try Data([2]).write(to: incoming)
        let previous = try store.replaceStudioMovie(of: item, withFileAt: incoming, pixelWidth: 5, pixelHeight: 5, duration: 8, project: Data([8]))
        let record = store.directory.appending(path: item.fileName + ".json")
        try FileManager.default.removeItem(at: record)
        try FileManager.default.createDirectory(at: record, withIntermediateDirectories: false)
        try Data([3]).write(to: incoming)
        #expect(throws: (any Error).self) {
            try store.replaceStudioMovie(of: previous, withFileAt: incoming, pixelWidth: 4, pixelHeight: 4, duration: 7, project: Data([7]))
        }
        #expect(try Data(contentsOf: store.fileURL(for: item)) == Data([2]))
        #expect(store.studioMovieProject(of: item) == Data([8]))
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

    /// The original comes back with the date it was taken; the file is dated now, so a converted copy of the marked
    /// picture, or a pin of it, reads as older than the capture.
    @Test func restoringTheOriginalDatesTheFileNow() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 20, appName: nil)
        let file = store.fileURL(for: item).path(percentEncoded: false)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: file)
        let marked = try store.replaceImage(of: item, with: Data([2]), pixelWidth: 10, pixelHeight: 20, annotations: Data([9]))
        let markedAt = try #require(FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date)

        try store.restoreOriginal(of: marked)

        let restoredAt = try #require(FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date)
        #expect(restoredAt >= markedAt)
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

    @Test func invalidatingAStudioExportClearsItsProjectWhileKeepingTheMovieMarker() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "mp4", kind: .recording, pixelWidth: 1600, pixelHeight: 1000, appName: nil, duration: 4)
        // No export yet: invalidating is a no-op and does not fabricate a movie marker.
        store.invalidateStudioMovieExport(of: item)
        #expect(!store.hasStudioMovie(item))

        let exported = FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString).mp4")
        try Data([2]).write(to: exported)
        let movie = try store.replaceStudioMovie(of: item, withFileAt: exported, pixelWidth: 1600, pixelHeight: 1000, duration: 4, project: Data([7]))
        #expect(store.hasStudioMovie(movie))
        #expect(store.studioMovieProject(of: movie) == Data([7]))

        store.invalidateStudioMovieExport(of: movie)
        #expect(store.hasStudioMovie(movie))
        #expect(store.studioMovieProject(of: movie) == nil)
        #expect(FileManager.default.contents(atPath: try store.studioSource(for: movie).path(percentEncoded: false)) == Data([1]))
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

    /// The editor's resize scales the document's scale with the picture, and every reader of the record (saving at 1×,
    /// dragging out, pins, printing) goes by it: a 2× capture resized to half is 1× in the record too, and 2× again
    /// once the resize is undone in the editor and the capture put back.
    @Test func aResizedPictureCarriesItsScaleIntoTheRecord() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(
            data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 800, pixelHeight: 600, appName: nil, pixelsPerPoint: 2
        )
        let resized = try store.replaceImage(of: item, with: Data([2]), pixelWidth: 400, pixelHeight: 300, annotations: Data([9]), pixelsPerPoint: 1)
        #expect(resized.pixelWidth == 400 && resized.pixelsPerPoint == 1)
        #expect(store.item(id: item.id)?.pixelsPerPoint == 1)
        // Marking up again without a new scale leaves the record's as it is.
        let marked = try store.replaceImage(of: resized, with: Data([3]), pixelWidth: 400, pixelHeight: 300, annotations: Data([9]))
        #expect(marked.pixelsPerPoint == 1)
        // The resize undone: the original comes back, at the scale the editor's document has again.
        let restored = try store.restoreOriginal(of: marked, pixelsPerPoint: 2)
        #expect(restored.pixelsPerPoint == 2)
        #expect(store.item(id: item.id)?.pixelsPerPoint == 2)
        // Restoring without one leaves the record's scale as it is.
        let again = try store.replaceImage(of: restored, with: Data([2]), pixelWidth: 400, pixelHeight: 300, annotations: Data([9]), pixelsPerPoint: 1)
        #expect(try store.restoreOriginal(of: again).pixelsPerPoint == 1)
    }

    /// A capture whose scale is not known stays so: the record gets one only when it is given.
    @Test func aPictureWithNoScaleKeepsNoneWhenMarked() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 10, pixelHeight: 10, appName: nil)
        let marked = try store.replaceImage(of: item, with: Data([2]), pixelWidth: 10, pixelHeight: 10, annotations: Data([9]))
        #expect(marked.pixelsPerPoint == nil && store.item(id: item.id)?.pixelsPerPoint == nil)
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
