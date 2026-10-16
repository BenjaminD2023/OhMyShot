import CoreGraphics
import Foundation
import ImageIO
@testable import OMSCore
import Testing
import UniformTypeIdentifiers

struct ShareHandoffTests {
    private let batch = UUID(uuidString: "6F1D2A4E-0B3C-4D5E-8F70-91A2B3C4D5E6")!

    private func parse(_ string: String) -> Result<ShareHandoff, AutomationURLError> {
        ShareHandoff.parse(URL(string: string)!, scheme: "ohmyshot")
    }

    @Test func handoffRoundTripsThroughItsURL() {
        for action in ShareHandoff.Action.allCases {
            let handoff = ShareHandoff(batch: batch, action: action)
            #expect(parse(handoff.url(scheme: "ohmyshot").absoluteString) == .success(handoff))
        }
    }

    @Test func handoffNamesOnlyABatchAndAnAction() {
        let url = ShareHandoff(batch: batch, action: .pin).url(scheme: "ohmyshot-dev")
        #expect(url.absoluteString == "ohmyshot-dev://share?id=6F1D2A4E-0B3C-4D5E-8F70-91A2B3C4D5E6&action=pin")
    }

    @Test func schemeAndCommandNamesAreCaseInsensitive() {
        let result = parse("OHMYSHOT://Share?ID=6f1d2a4e-0b3c-4d5e-8f70-91a2b3c4d5e6&Action=ANNOTATE")
        #expect(result == .success(ShareHandoff(batch: batch, action: .annotate)))
    }

    @Test func aBatchIsAUUIDNotAPath() {
        #expect(parse("ohmyshot://share?id=..%2F..%2Fetc&action=pin") == .failure(.invalidParameter(name: "id", value: "../../etc")))
        #expect(parse("ohmyshot://share?id=%2FUsers%2Fme%2Fa.png&action=pin") == .failure(.invalidParameter(name: "id", value: "/Users/me/a.png")))
    }

    @Test func missingAndUnknownParametersAreRefused() {
        #expect(parse("ohmyshot://share?action=pin") == .failure(.missingParameter("id")))
        #expect(parse("ohmyshot://share?id=\(batch.uuidString)") == .failure(.missingParameter("action")))
        #expect(parse("ohmyshot://share?id=\(batch.uuidString)&action=delete") == .failure(.invalidParameter(name: "action", value: "delete")))
    }

    @Test func otherSchemesAndCommandsAreNotHandoffs() {
        #expect(!ShareHandoff.isHandoff(URL(string: "ohmyshot://pin?filepath=/tmp/a.png")!, scheme: "ohmyshot"))
        #expect(!ShareHandoff.isHandoff(URL(string: "ohmyshot-dev://share?id=1")!, scheme: "ohmyshot"))
        #expect(ShareHandoff.isHandoff(URL(string: "ohmyshot://share")!, scheme: "ohmyshot"))
        #expect(parse("cleanshot://share?id=\(batch.uuidString)&action=pin") == .failure(.wrongScheme("cleanshot")))
    }

    /// It is not a CleanShot command: the automation parser does not know it, so it can never be reached
    /// through the gate by accident.
    @Test func theAutomationParserDoesNotKnowIt() {
        let url = URL(string: "ohmyshot://share?id=\(batch.uuidString)&action=pin")!
        #expect(AutomationURLParser.parse(url, scheme: "ohmyshot") == .failure(.unknownCommand("share")))
    }
}

struct ShareInboxTests {
    /// An inbox in a folder of its own, with the folder around it so a path beside the inbox can be tried.
    private struct Scratch {
        let root = FileManager.default.temporaryDirectory.appending(path: "OMSShareInbox-\(UUID().uuidString)", directoryHint: .isDirectory)
        var inbox: ShareInbox { ShareInbox(directory: root.appending(path: ShareInbox.folderName, directoryHint: .isDirectory)) }

        init() throws {
            try FileManager.default.createDirectory(at: root.appending(path: ShareInbox.folderName), withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func pictureData(_ type: UTType = .png) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    // MARK: Inside the inbox

    @Test func insideMeansWholePathComponents() {
        let inbox = URL(filePath: "/x/Share Inbox")
        #expect(ShareInbox.isInside(URL(filePath: "/x/Share Inbox/A/b.png"), folder: inbox))
        #expect(!ShareInbox.isInside(URL(filePath: "/x/Share Inbox"), folder: inbox))
        #expect(!ShareInbox.isInside(URL(filePath: "/x/Share Inbox-evil/A/b.png"), folder: inbox))
        #expect(!ShareInbox.isInside(URL(filePath: "/x/Share Inbox/../Other/b.png"), folder: inbox))
        #expect(!ShareInbox.isInside(URL(filePath: "/Share Inbox/A/b.png"), folder: inbox))
    }

    // MARK: Names

    @Test func namesKeepAnImageExtensionAndLoseTheirFolders() {
        func name(_ suggested: String?, _ type: UTType? = nil) -> String {
            ShareInbox.fileName(suggested: suggested, type: type) { _ in false }
        }
        #expect(name("Screenshot 2026-10-17 at 10.00.00.png") == "Screenshot 2026-10-17 at 10.00.00.png")
        #expect(name("../../etc/photo.JPG") == "photo.JPG")
        #expect(name(".hidden.png") == "hidden.png")
        #expect(name("a:b.png") == "a-b.png")
        // No extension, or one that is not a picture's: the type says what the file is.
        #expect(name("holiday", .jpeg) == "holiday.jpeg")
        #expect(name("10.00.00", .png) == "10.00.00.png")
        #expect(name(nil, .heic) == "Picture.heic")
        #expect(name("", nil) == "Picture.png")
        #expect(name("notes.txt", .png) == "notes.txt.png")
    }

    @Test func aTakenNameIsNumbered() {
        let taken: Set = ["a.png", "a 2.png"]
        #expect(ShareInbox.fileName(suggested: "a.png", type: nil) { taken.contains($0) } == "a 3.png")
    }

    @Test func aLongNameIsCut() {
        let name = ShareInbox.fileName(suggested: String(repeating: "x", count: 400) + ".png", type: nil) { _ in false }
        #expect(name.count == 124)
    }

    // MARK: A batch

    @Test func aBatchHoldsWhatWasStoredAndNothingMore() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let batch = try scratch.inbox.newBatch()
        let data = try pictureData()
        try batch.store(data, named: "b", type: .png)
        try batch.store(data, named: "a.png", type: .png)
        try batch.store(data, named: "a.png", type: .png)
        let pictures = try scratch.inbox.pictures(inBatch: batch.id)
        #expect(pictures.map(\.lastPathComponent) == ["a 2.png", "a.png", "b.png"])
        #expect(pictures.allSatisfy { ShareInbox.isInside($0, folder: scratch.inbox.directory) })
    }

    @Test func storingACopyLeavesTheOriginal() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let original = scratch.root.appending(path: "Shot.png")
        try pictureData().write(to: original)
        let batch = try scratch.inbox.newBatch()
        let copy = try batch.store(copyOf: original)
        #expect(copy.lastPathComponent == "Shot.png")
        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
        #expect(try scratch.inbox.pictures(inBatch: batch.id).map(\.lastPathComponent) == [copy.lastPathComponent])
    }

    @Test func discardingABatchRemovesIt() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let batch = try scratch.inbox.newBatch()
        try batch.store(pictureData(), named: "a.png", type: .png)
        scratch.inbox.discard(batch: batch.id)
        #expect(throws: ShareInbox.Failure.noSuchBatch) { try scratch.inbox.pictures(inBatch: batch.id) }
    }

    @Test func unreadBatchesAreClearedAfterADay() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let old = try scratch.inbox.newBatch()
        let fresh = try scratch.inbox.newBatch()
        try pictureData().write(to: old.directory.appending(path: "a.png"))
        try pictureData().write(to: fresh.directory.appending(path: "a.png"))
        // Seen from now neither is stale; seen from two days on, both are.
        scratch.inbox.removeStaleBatches(now: .now)
        #expect(FileManager.default.fileExists(atPath: old.directory.path(percentEncoded: false)))
        scratch.inbox.removeStaleBatches(now: .now.addingTimeInterval(2 * ShareInbox.staleAfter))
        #expect(!FileManager.default.fileExists(atPath: old.directory.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: fresh.directory.path(percentEncoded: false)))
    }

    @Test func foldersThatAreNotBatchesAreLeftAlone() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let other = scratch.inbox.directory.appending(path: "Keep Me", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        scratch.inbox.removeStaleBatches(now: .now.addingTimeInterval(10 * ShareInbox.staleAfter))
        #expect(FileManager.default.fileExists(atPath: other.path(percentEncoded: false)))
    }

    // MARK: Only pictures, only here

    @Test func onlyPicturesAreTaken() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let batch = try scratch.inbox.newBatch()
        try pictureData().write(to: batch.directory.appending(path: "good.png"))
        try Data("not a picture".utf8).write(to: batch.directory.appending(path: "notes.txt"))
        // Named like a picture, but not one.
        try Data("<script>alert(1)</script>".utf8).write(to: batch.directory.appending(path: "fake.png"))
        try Data().write(to: batch.directory.appending(path: "empty.png"))
        // A picture saved under the wrong name is still a picture.
        try pictureData(.jpeg).write(to: batch.directory.appending(path: "wrong.png"))
        try FileManager.default.createDirectory(at: batch.directory.appending(path: "folder.png"), withIntermediateDirectories: true)
        let names = try scratch.inbox.pictures(inBatch: batch.id).map(\.lastPathComponent)
        #expect(names == ["good.png", "wrong.png"])
    }

    @Test func aBatchWithNoPictureIsRefused() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let batch = try scratch.inbox.newBatch()
        try Data("hello".utf8).write(to: batch.directory.appending(path: "a.txt"))
        #expect(throws: ShareInbox.Failure.noPictures) { try scratch.inbox.pictures(inBatch: batch.id) }
    }

    @Test func aBatchThatDoesNotExistIsRefused() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        #expect(throws: ShareInbox.Failure.noSuchBatch) { try scratch.inbox.pictures(inBatch: UUID()) }
    }

    @Test func aLinkToAPictureElsewhereIsNotFollowed() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let outside = scratch.root.appending(path: "Secret.png")
        try pictureData().write(to: outside)
        let batch = try scratch.inbox.newBatch()
        try pictureData().write(to: batch.directory.appending(path: "real.png"))
        try FileManager.default.createSymbolicLink(at: batch.directory.appending(path: "link.png"), withDestinationURL: outside)
        let names = try scratch.inbox.pictures(inBatch: batch.id).map(\.lastPathComponent)
        #expect(names == ["real.png"])
    }

    @Test func aBatchThatIsALinkOutOfTheInboxIsNotFollowed() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let elsewhere = scratch.root.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try pictureData().write(to: elsewhere.appending(path: "a.png"))
        let id = UUID()
        try FileManager.default.createSymbolicLink(
            at: scratch.inbox.directory.appending(path: id.uuidString), withDestinationURL: elsewhere
        )
        #expect(throws: ShareInbox.Failure.noSuchBatch) { try scratch.inbox.pictures(inBatch: id) }
    }

    @Test func aHandOverOfManyKeepsTheFirstTwenty() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let batch = try scratch.inbox.newBatch()
        let data = try pictureData()
        for number in 1...25 { try batch.store(data, named: "Shot \(number).png", type: .png) }
        let names = try scratch.inbox.pictures(inBatch: batch.id).map(\.lastPathComponent)
        #expect(names.count == ShareInbox.maximumPictures)
        // Numbers in names sort as numbers.
        #expect(names.first == "Shot 1.png" && names.last == "Shot 20.png")
    }

    @Test func theInboxOfAHostIsInItsApplicationSupport() {
        let inbox = ShareInbox.hosted(by: "io.example.host")
        #expect(inbox.directory.pathComponents.suffix(4) == ["Library", "Application Support", "io.example.host", "Share Inbox"])
    }

    // MARK: Item providers

    @Test func aPictureFileIsCopiedFromItsProvider() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let file = scratch.root.appending(path: "Provided.png")
        try pictureData().write(to: file)
        let provider = try #require(NSItemProvider(contentsOf: file))
        #expect(provider.mayHoldPicture)
        let batch = try scratch.inbox.newBatch()
        let stored = try #require(try await batch.addPicture(from: provider))
        #expect(stored.deletingLastPathComponent().standardizedFileURL == batch.directory.standardizedFileURL)
        #expect(stored.pathExtension == "png")
        #expect(try scratch.inbox.pictures(inBatch: batch.id).count == 1)
    }

    @Test func pictureDataIsWrittenFromItsProvider() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let data = try pictureData(.jpeg)
        let provider = NSItemProvider()
        provider.suggestedName = "Camera"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.jpeg.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        #expect(provider.mayHoldPicture)
        let batch = try scratch.inbox.newBatch()
        let stored = try #require(try await batch.addPicture(from: provider))
        #expect(stored.lastPathComponent.hasPrefix("Camera."))
        #expect(try scratch.inbox.pictures(inBatch: batch.id).map(\.lastPathComponent) == [stored.lastPathComponent])
    }

    @Test func anItemThatIsNoPictureStoresNothing() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let provider = NSItemProvider(item: "just words" as NSString, typeIdentifier: UTType.plainText.identifier)
        #expect(!provider.mayHoldPicture)
        let batch = try scratch.inbox.newBatch()
        #expect(try await batch.addPicture(from: provider) == nil)
        #expect(throws: ShareInbox.Failure.noPictures) { try scratch.inbox.pictures(inBatch: batch.id) }
    }

    // MARK: Which items are pictures

    @Test func anItemThatSaysItIsAPictureIsOne() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(nil, nil)
            return nil
        }
        #expect(provider.registersPictureType)
        #expect(await provider.holdsPicture())
    }

    @Test func aPictureFileIsAPictureAndADocumentIsNot() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let picture = scratch.root.appending(path: "Shot.png")
        try pictureData().write(to: picture)
        let document = scratch.root.appending(path: "Notes.pdf")
        try Data("%PDF-1.4".utf8).write(to: document)
        let words = scratch.root.appending(path: "Words.txt")
        try Data("words".utf8).write(to: words)

        let ofPicture = try #require(NSItemProvider(contentsOf: picture))
        let ofDocument = try #require(NSItemProvider(contentsOf: document))
        let ofWords = try #require(NSItemProvider(contentsOf: words))
        #expect(await ofPicture.holdsPicture())
        #expect(!(await ofDocument.holdsPicture()))
        #expect(!(await ofWords.holdsPicture()))
    }

    /// Finder can share a file as its address alone, with nothing to say what it holds: the name decides, and
    /// the item still may hold a picture until it has been looked at.
    @Test func aFileAddressIsAPictureWhenItsNameSaysSo() async throws {
        let picture = NSItemProvider(item: URL(filePath: "/tmp/Shot.heic") as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let document = NSItemProvider(item: URL(filePath: "/tmp/Notes.pdf") as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let folder = NSItemProvider(item: URL(filePath: "/tmp/Photos", directoryHint: .isDirectory) as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let asData = NSItemProvider(item: URL(filePath: "/tmp/Shot.jpg").dataRepresentation as NSData, typeIdentifier: UTType.fileURL.identifier)
        for provider in [picture, document, folder, asData] { #expect(provider.mayHoldPicture && !provider.registersPictureType) }

        #expect(await picture.holdsPicture())
        #expect(!(await document.holdsPicture()))
        #expect(!(await folder.holdsPicture()))
        #expect(await asData.holdsPicture())
    }

    @Test func wordsAreNotAPicture() async {
        let provider = NSItemProvider(item: "just words" as NSString, typeIdentifier: UTType.plainText.identifier)
        #expect(!(await provider.holdsPicture()))
    }
}
