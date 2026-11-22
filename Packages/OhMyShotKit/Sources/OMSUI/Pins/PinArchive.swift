import CoreGraphics
import Foundation
import ImageIO
import OMSCore
import OSLog

/// The pins open now, kept on disk so they come back after the app quits, updates, or crashes: `Pins.json` holds each
/// pin's kind, place, zoom, opacity, and lock, its text or color, when it was pinned, and whether the pins were hidden;
/// each picture is a PNG beside it, named by its pin, as is the capture of a pin that shows it without the background it
/// was put on (`PinController.Pin.onBackground`). Nothing is there while no pin is open. Reads and writes go through one
/// queue of their own, in the order they were asked for, so a picture is on disk before the list that names it.
nonisolated final class PinArchive: Sendable {
    /// One pin as it is kept.
    struct Record: Codable, Equatable, Sendable {
        enum Content: Codable, Equatable, Sendable {
            /// The picture is `<id>.png`, at `scale` pixels per point; its capture on its background, when it has one,
            /// `<id>-background.png`.
            case picture(scale: CGFloat)
            case text(String)
            /// The color as it came: its color space's name and its components.
            case color(space: String, components: [CGFloat])
        }

        var id: UUID
        var content: Content
        var origin: PinController.Origin
        /// The window's frame, in global points.
        var frame: CGRect
        var zoom: CGFloat
        var opacity: CGFloat
        var locked: Bool
        /// When it was pinned, in seconds since 2001 (`Date.timeIntervalSinceReferenceDate`): to the fraction, which the
        /// list's ISO 8601 dates drop, while Capture Area and Pin writes its capture's file in the second before it pins.
        /// Nil in a list kept before pins kept it.
        var pinnedAt: TimeInterval?
    }

    struct Manifest: Codable, Equatable, Sendable {
        var hidden: Bool
        /// Back to front, as they are stacked: the last is in front.
        var pins: [Record]
    }

    let folder: URL
    private let queue = DispatchQueue(label: "OhMyShot.pins.archive", qos: .utility)

    init(folder: URL = AppFolders.support.appending(path: "Pins", directoryHint: .isDirectory)) {
        self.folder = folder
    }

    private var manifestURL: URL { folder.appending(path: "Pins.json") }

    private func pictureURL(_ id: UUID) -> URL { folder.appending(path: "\(id.uuidString).png") }

    private func backgroundURL(_ id: UUID) -> URL { folder.appending(path: "\(id.uuidString)-background.png") }

    /// Writes a pin's picture, and its capture on its background when it has one (`PinController.Pin.onBackground`),
    /// once, as it opens or as keeping begins.
    func keepPicture(_ image: CGImage, onBackground: Data? = nil, id: UUID) {
        queue.async { [self] in writePicture(image, onBackground: onBackground, id: id) }
    }

    /// On the queue: writes a pin's picture, its capture on its background first, so a picture on disk has it beside it.
    private func writePicture(_ image: CGImage, onBackground: Data?, id: UUID) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let onBackground { try ImageExporter.write(onBackground, to: backgroundURL(id)) }
            try ImageExporter.write(ImageExporter.encoded(image, as: .png), to: pictureURL(id))
        } catch {
            Log.app.error("Could not keep a pin's picture: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes the list of pins, and each of `pictures` (the open picture pins', by pin) that isn't on disk, as one whose
    /// first write failed, with its capture on its background from `onBackground`; or with no pin removes everything
    /// kept. `waits` when the app is about to quit: until the list is written, and every picture asked for before it.
    func save(_ manifest: Manifest, pictures: [UUID: CGImage] = [:], onBackground: [UUID: Data] = [:], waits: Bool = false) {
        let write: @Sendable () -> Void = { [self] in
            if manifest.pins.isEmpty {
                try? FileManager.default.removeItem(at: folder)
                return
            }
            for (id, image) in pictures where !FileManager.default.fileExists(atPath: pictureURL(id).path(percentEncoded: false)) {
                writePicture(image, onBackground: onBackground[id], id: id)
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try JSONEncoder.records.encode(manifest).write(to: manifestURL, options: .atomic)
            } catch {
                Log.app.error("Could not keep the pins: \(error.localizedDescription, privacy: .public)")
            }
        }
        if waits { queue.sync(execute: write) } else { queue.async(execute: write) }
    }

    /// Removes a closed pin's picture, and its capture on its background; the list follows with the next save.
    func forget(_ id: UUID) {
        let urls = [pictureURL(id), backgroundURL(id)]
        queue.async { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
    }

    /// Removes everything kept.
    func removeAll() {
        queue.async { [folder] in try? FileManager.default.removeItem(at: folder) }
    }

    /// Reads what was kept: the list, and each picture it names, decoded. A pin whose picture can't be read is left
    /// out, and a picture no pin names (its pin closed as the app stopped) is removed, as are pictures with no list at
    /// all (the app stopped before writing it). A list that is there but can't be read now is left for the next
    /// launch. `done` runs on the main actor, only when a pin was kept; with nothing kept this does no more than find
    /// that the list isn't there.
    func load(_ done: @escaping @MainActor @Sendable (Manifest, [UUID: CGImage], [UUID: Data]) -> Void) {
        queue.async { [self] in
            guard let (manifest, pictures, onBackground) = read() else { return }
            Task { @MainActor in done(manifest, pictures, onBackground) }
        }
    }

    /// What `load` reads, read now, for tests.
    func loadNow() -> (Manifest, [UUID: CGImage], [UUID: Data])? {
        queue.sync { read() }
    }

    /// Waits for every read and write asked for so far.
    func finish() {
        queue.sync {}
    }

    /// On the queue: the list, its pictures, and the captures on their backgrounds kept beside them; nil when no pin was
    /// kept.
    private func read() -> (Manifest, [UUID: CGImage], [UUID: Data])? {
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch CocoaError.fileReadNoSuchFile {
            try? FileManager.default.removeItem(at: folder)
            return nil
        } catch {
            Log.app.error("Could not read the kept pins: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard var manifest = try? JSONDecoder.records.decode(Manifest.self, from: data) else {
            Log.app.error("Could not read the kept pins")
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        var pictures: [UUID: CGImage] = [:], onBackground: [UUID: Data] = [:]
        manifest.pins.removeAll { record in
            guard case .picture = record.content else { return false }
            guard let source = CGImageSourceCreateWithURL(pictureURL(record.id) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { return true }
            pictures[record.id] = image
            onBackground[record.id] = try? Data(contentsOf: backgroundURL(record.id))
            return false
        }
        let named = Set(manifest.pins.flatMap { [pictureURL($0.id).lastPathComponent, backgroundURL($0.id).lastPathComponent] })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        for file in files where file.hasSuffix(".png") && !named.contains(file) {
            try? FileManager.default.removeItem(at: folder.appending(path: file))
        }
        return manifest.pins.isEmpty ? nil : (manifest, pictures, onBackground)
    }
}

@MainActor
extension PinArchive.Record {
    /// A pin as it is kept, with its window's place, zoom, opacity, and lock. A color whose color space has no name to keep
    /// it by (a profile of its own) is kept as it looks, in extended sRGB; nil when it can't be.
    init?(_ pin: PinController.Pin, frame: CGRect, zoom: CGFloat, opacity: CGFloat, locked: Bool) {
        let content: Content
        switch pin.content {
        case .image(_, let scale):
            content = .picture(scale: scale)
        case .text(let text):
            content = .text(text)
        case .color(let color):
            let named = color.original.colorSpace?.name == nil
                ? CGColorSpace(name: CGColorSpace.extendedSRGB).flatMap { color.original.converted(to: $0, intent: .defaultIntent, options: nil) }
                : color.original
            guard let named, let space = named.colorSpace?.name as String?, let components = named.components else { return nil }
            content = .color(space: space, components: components)
        }
        self.init(
            id: pin.id, content: content, origin: pin.origin, frame: frame, zoom: zoom, opacity: opacity, locked: locked,
            pinnedAt: pin.pinnedAt.timeIntervalSinceReferenceDate
        )
    }

    /// The pin as it was kept, with its picture when it is one and its capture on its background when it has one; nil when
    /// it can't be made. It was pinned when it was, so a capture changed since, before the app quit, still holds a picture
    /// other than the pin's; one from a list kept before pins kept that is taken as pinned before its capture's every
    /// change, and hands over its own picture.
    func pin(picture: CGImage?, onBackground: Data? = nil) -> PinController.Pin? {
        guard let content = pinContent(picture: picture) else { return nil }
        let pinnedAt = pinnedAt.map(Date.init(timeIntervalSinceReferenceDate:)) ?? .distantPast
        return PinController.Pin(id: id, content: content, origin: origin, pinnedAt: pinnedAt, onBackground: onBackground)
    }

    /// What the pin shows, made again, with its picture when it is one; nil when it can't be.
    func pinContent(picture: CGImage?) -> PinController.Content? {
        switch content {
        case .picture(let scale):
            return picture.map { .image($0, scale: scale) }
        case .text(let text):
            return .text(text)
        case .color(let space, let components):
            guard let colorSpace = CGColorSpace(name: space as CFString), components.count == colorSpace.numberOfComponents + 1,
                  let color = CGColor(colorSpace: colorSpace, components: components)
            else { return nil }
            return PinColor(color).map { .color($0) }
        }
    }
}
