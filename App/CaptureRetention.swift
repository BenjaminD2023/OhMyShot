import AppKit
import Foundation
import OMSAnnotate
import OMSCore
import OSLog

/// How long captures stay in the history. Settings' Keep Captures takes the old ones away; with history off a capture
/// lives as long as something holds it (`heldCaptureIDs`: a card, an editor or a recording's window, an upload, the
/// clipboard) and goes once nothing does. The desktop pictures' pieces kept for window screenshots go with the last
/// capture that used them.
final class CaptureRetention {
    private let settings: SettingsStore
    private let history: HistoryStore
    /// The captures with a Quick Access card.
    private let cards: () -> Set<UUID>
    /// The captures open in the editor, which also keeps the wallpaper sweep off while any is: its Undo may bring a
    /// background back.
    private let editors: () -> Set<UUID>
    /// The recordings with a window open (a Studio one included).
    private let recordingWindows: () -> Set<UUID>
    /// The captures being uploaded.
    private let uploads: () -> Set<UUID>
    /// Captures were removed from the history: Capture History shows it.
    private let historyChanged: () -> Void
    private var pictureSweep: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    /// The recording whose file is on the clipboard, and the clipboard's change count when it went there.
    private var clipboardRecording: (id: UUID, changeCount: Int)?
    private var clipboardWatch: Task<Void, Never>?

    init(
        settings: SettingsStore, history: HistoryStore, cards: @escaping () -> Set<UUID>, editors: @escaping () -> Set<UUID>,
        recordingWindows: @escaping () -> Set<UUID>, uploads: @escaping () -> Set<UUID>, historyChanged: @escaping () -> Void
    ) {
        self.settings = settings
        self.history = history
        self.cards = cards
        self.editors = editors
        self.recordingWindows = recordingWindows
        self.uploads = uploads
        self.historyChanged = historyChanged
    }

    /// Captures something still needs the file of: a card, an open editor, an open recording window (a Studio one
    /// included), an upload on its way, the clipboard.
    var heldCaptureIDs: Set<UUID> {
        cards()
            .union(editors())
            .union(recordingWindows())
            .union(uploads())
            .union(clipboardRecordingID.map { [$0] } ?? [])
    }

    /// With history off, a capture lives as long as something holds it (`heldCaptureIDs`); deletes it once nothing does.
    func releaseIfUnheld(_ id: UUID) {
        guard settings.historyRetention == .never, !heldCaptureIDs.contains(id), let entry = history.item(id: id) else { return }
        history.delete(entry)
        historyChanged()
        sweepWallpaperPictures()
    }

    /// A recording went to the clipboard as a reference to its file in the history, which is all the clipboard has of it.
    /// With history off, the file stays until the clipboard holds something else, or until the next launch.
    func recordingCopied(_ id: UUID) {
        let former = clipboardRecording?.id
        clipboardRecording = (id, NSPasteboard.general.changeCount)
        clipboardWatch?.cancel()
        clipboardWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                guard clipboardRecordingID == nil else { continue }
                clipboardRecording = nil
                releaseIfUnheld(id)
                return
            }
        }
        if let former, former != id { releaseIfUnheld(former) }
    }

    /// The recording whose file the clipboard still holds: nothing else has been copied since it was.
    private var clipboardRecordingID: UUID? {
        guard let held = clipboardRecording, held.changeCount == NSPasteboard.general.changeCount else { return nil }
        return held.id
    }

    /// Takes away the captures older than Settings keep them, but those something holds. The history is listed off the
    /// main actor, as it runs after every capture (Docs/perf.md › Main-thread work after a capture); a newer request
    /// takes over from one under way.
    func removeExpired() {
        expiry?.cancel()
        let retention = settings.historyRetention, keeping = heldCaptureIDs, now = Date.now
        expiry = Task { [weak self, history] in
            let expired = await history.loadExpired(retention: retention, keeping: keeping, now: now)
            guard let self, !Task.isCancelled else { return }
            // Back on the main actor, and the listing took a while: a capture taken since is newer than `now`, and one
            // a card, an editor, or the clipboard took up since is held now; neither goes. With history off, that is
            // every capture but the ones still in use.
            let removable = HistoryStore.removable(expired, held: heldCaptureIDs, checkedAt: now)
            removable.forEach(history.delete)
            if !removable.isEmpty {
                Log.capture.notice("Removed \(removable.count, privacy: .public) expired capture(s) from the history")
            }
            historyChanged()
            sweepWallpaperPictures()
        }
    }

    /// How many captures a retention would delete now; captures still on screen as cards are kept.
    func expiredCount(for retention: HistoryRetention) -> Int {
        history.expired(retention: retention, keeping: heldCaptureIDs).count
    }

    /// Takes away the desktop pictures' pieces kept for window screenshots once nothing uses them: no capture's
    /// marks in the history (the Trash keeps a capture's picture, not its marks), no saved background, not the
    /// last picture chosen for one. Never while an editor is open, as its Undo may bring a background back.
    /// Captures going one after another are swept once.
    func sweepWallpaperPictures() {
        pictureSweep?.cancel()
        pictureSweep = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, editors().isEmpty else { return }
            let marks = await history.loadItems().map { history.annotationsURL(for: $0) }
            var used = BackdropPresets.shared.pictureNames
            used.formUnion(await Self.wallpaperPictures(namedIn: marks))
            guard !Task.isCancelled, editors().isEmpty else { return }
            // A piece just made may not be in a capture's marks yet.
            let removed = PictureStore.shared.removeUnused(prefix: CaptureBackground.wallpaperPrefix, used: used, olderThan: 10 * 60)
            if removed > 0 {
                Log.capture.notice("Removed \(removed, privacy: .public) desktop picture piece(s) no capture uses")
            }
        }
    }

    /// The desktop pictures' pieces named in the marks files at `urls`.
    @concurrent private nonisolated static func wallpaperPictures(namedIn urls: [URL]) async -> Set<String> {
        guard let name = try? Regex(CaptureBackground.wallpaperPrefix + "[0-9a-f]{16}\\.jpg") else { return [] }
        var names = Set<String>()
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for match in text.matches(of: name) { names.insert(String(text[match.range])) }
        }
        return names
    }
}
