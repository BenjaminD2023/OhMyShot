import CoreGraphics
import Foundation
import Testing
@testable import OMSUI

/// What is kept of the pins for the next launch, in a folder of the test's own.
@MainActor
struct PinArchiveTests {
    private func archive() -> PinArchive {
        PinArchive(folder: FileManager.default.temporaryDirectory.appending(path: "PinArchiveTests-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    private func picture(width: Int = 6, height: Int = 4) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func record(_ pin: PinController.Pin, x: CGFloat = 10) throws -> PinArchive.Record {
        try #require(PinArchive.Record(pin, frame: CGRect(x: x, y: 20, width: 300, height: 200), zoom: 1.5, opacity: 0.6, locked: true))
    }

    @Test func everyKindComesBackAsItWas() throws {
        let archive = archive()
        defer { try? FileManager.default.removeItem(at: archive.folder) }
        let image = try picture()
        let p3 = try #require(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [1, 0, 0, 0.5]))
        let pins = [
            PinController.Pin(id: UUID(), content: .image(image, scale: 2), origin: .capture(UUID())),
            PinController.Pin(id: UUID(), content: .text("npm run dev"), origin: .clipboard),
            PinController.Pin(id: UUID(), content: .color(try #require(PinColor(p3))), origin: .file(URL(filePath: "/tmp/a b.png"))),
        ]
        let manifest = PinArchive.Manifest(hidden: true, pins: try pins.enumerated().map { try record($1, x: CGFloat($0) * 100) })
        archive.keepPicture(image, id: pins[0].id)
        archive.save(manifest)

        let (loaded, pictures) = try #require(archive.loadNow())
        #expect(loaded == manifest)
        let kept = try #require(pictures[pins[0].id])
        #expect(kept.width == 6 && kept.height == 4)
        guard case .image(_, let scale) = loaded.pins[0].pinContent(picture: kept) else { Issue.record("not a picture"); return }
        #expect(scale == 2)
        guard case .text("npm run dev") = loaded.pins[1].pinContent(picture: nil) else { Issue.record("not the text"); return }
        guard case .color(let color) = loaded.pins[2].pinContent(picture: nil) else { Issue.record("not a color"); return }
        // A Display P3 color comes back in Display P3, not clamped to sRGB.
        #expect(color.original.colorSpace?.name == CGColorSpace.displayP3)
        #expect(color.hex == (try #require(PinColor(p3))).hex)
    }

    @Test func aPinWhosePictureIsMissingIsLeftOutAndALeftoverPictureRemoved() throws {
        let archive = archive()
        defer { try? FileManager.default.removeItem(at: archive.folder) }
        let image = try picture()
        let shown = PinController.Pin(id: UUID(), content: .image(image, scale: 1), origin: .clipboard)
        let lost = PinController.Pin(id: UUID(), content: .image(image, scale: 1), origin: .clipboard)
        let closed = UUID()
        archive.keepPicture(image, id: shown.id)
        archive.keepPicture(image, id: closed)
        archive.save(PinArchive.Manifest(hidden: false, pins: [try record(shown), try record(lost)]))

        let (loaded, pictures) = try #require(archive.loadNow())
        #expect(loaded.pins.map(\.id) == [shown.id])
        #expect(Set(pictures.keys) == [shown.id])
        let files = try FileManager.default.contentsOfDirectory(atPath: archive.folder.path(percentEncoded: false))
        #expect(Set(files) == ["Pins.json", "\(shown.id.uuidString).png"])
    }

    @Test func closingThePinsRemovesWhatWasKept() throws {
        let archive = archive()
        defer { try? FileManager.default.removeItem(at: archive.folder) }
        let image = try picture()
        let first = PinController.Pin(id: UUID(), content: .image(image, scale: 1), origin: .clipboard)
        let second = PinController.Pin(id: UUID(), content: .text("kept"), origin: .clipboard)
        archive.keepPicture(image, id: first.id)
        archive.save(PinArchive.Manifest(hidden: false, pins: [try record(first), try record(second)]))
        // Closing one forgets its picture, and the list follows.
        archive.forget(first.id)
        archive.save(PinArchive.Manifest(hidden: false, pins: [try record(second)]), waits: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: archive.folder.path(percentEncoded: false))
        #expect(files == ["Pins.json"])
        // With none left, nothing is.
        archive.save(PinArchive.Manifest(hidden: false, pins: []), waits: true)
        #expect(!FileManager.default.fileExists(atPath: archive.folder.path(percentEncoded: false)))
        #expect(archive.loadNow() == nil)
    }

    @Test func nothingKeptReadsNothing() throws {
        let archive = archive()
        #expect(archive.loadNow() == nil)
        #expect(!FileManager.default.fileExists(atPath: archive.folder.path(percentEncoded: false)))
    }

    @Test func aListThatCantBeReadIsRemoved() throws {
        let archive = archive()
        defer { try? FileManager.default.removeItem(at: archive.folder) }
        try FileManager.default.createDirectory(at: archive.folder, withIntermediateDirectories: true)
        try Data("not a list".utf8).write(to: archive.folder.appending(path: "Pins.json"))
        #expect(archive.loadNow() == nil)
        #expect(!FileManager.default.fileExists(atPath: archive.folder.path(percentEncoded: false)))
    }

    @Test func aPictureWhoseFirstWriteFailedIsWrittenWithTheNextList() throws {
        let archive = archive()
        defer { try? FileManager.default.removeItem(at: archive.folder) }
        let image = try picture()
        let pin = PinController.Pin(id: UUID(), content: .image(image, scale: 2), origin: .clipboard)
        // No keepPicture: as if its write had failed when the pin opened.
        archive.save(PinArchive.Manifest(hidden: false, pins: [try record(pin)]), pictures: [pin.id: image], waits: true)
        let (manifest, pictures) = try #require(archive.loadNow())
        #expect(manifest.pins.map(\.id) == [pin.id] && pictures[pin.id]?.width == image.width)
    }

    @Test func aColorWithAProfileOfItsOwnComesBackAsItLooked() throws {
        let space = try #require(CGColorSpace(calibratedGrayWhitePoint: [0.9505, 1, 1.089], blackPoint: [0, 0, 0], gamma: 2.2))
        #expect(space.name == nil)
        let gray = try #require(CGColor(colorSpace: space, components: [0.4, 0.8]))
        let color = try #require(PinColor(gray))
        let pin = PinController.Pin(id: UUID(), content: .color(color), origin: .clipboard)
        let kept = try #require(PinArchive.Record(pin, frame: CGRect(x: 0, y: 0, width: 128, height: 128), zoom: 1, opacity: 1, locked: false))
        guard case .color(let back) = try #require(kept.pinContent(picture: nil)) else {
            Issue.record("not a color")
            return
        }
        #expect(abs(back.red - color.red) < 0.001 && abs(back.green - color.green) < 0.001 && abs(back.blue - color.blue) < 0.001)
        #expect(abs(back.alpha - 0.8) < 0.001)
    }

    @Test func picturesLeftWithoutAListAreRemoved() throws {
        let archive = archive()
        defer { try? FileManager.default.removeItem(at: archive.folder) }
        // The app stopped after a pin's picture was written and before the list was.
        archive.keepPicture(try picture(), id: UUID())
        archive.finish()
        #expect(archive.loadNow() == nil)
        #expect(!FileManager.default.fileExists(atPath: archive.folder.path(percentEncoded: false)))
    }

    @Test func aListThatCantBeReadNowIsLeftForTheNextLaunch() throws {
        let archive = archive()
        defer { try? FileManager.default.removeItem(at: archive.folder) }
        let image = try picture()
        let pin = PinController.Pin(id: UUID(), content: .image(image, scale: 2), origin: .clipboard)
        archive.keepPicture(image, id: pin.id)
        archive.save(PinArchive.Manifest(hidden: false, pins: [try record(pin)]), waits: true)
        let list = archive.folder.appending(path: "Pins.json").path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: list)
        #expect(archive.loadNow() == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: list)
        let (manifest, pictures) = try #require(archive.loadNow())
        #expect(manifest.pins.map(\.id) == [pin.id] && pictures[pin.id] != nil)
    }
}
