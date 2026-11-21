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
    private let cards: (HistoryRetention) -> Set<UUID>
    /// The captures open in the editor, which also keeps the wallpaper sweep off while any is: its Undo may bring a
    /// background back.
    private let editors: () -> Set<UUID>
    /// The recordings with a window open (a Studio one included).
    private let recordingWindows: () -> Set<UUID>
    /// The captures being uploaded.
    private let uploads: () -> Set<UUID>
    /// Captures were removed from the history: Capture History shows it.
    private let historyChanged: ([UUID]) -> Void
    private var pictureSweep: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private lazy var clipboard = RecordingClipboardHold(
        changeCount: { NSPasteboard.general.changeCount },
        released: { [weak self] in self?.releaseIfUnheld($0) }
    )

    init(
        settings: SettingsStore, history: HistoryStore, cards: @escaping (HistoryRetention) -> Set<UUID>, editors: @escaping () -> Set<UUID>,
        recordingWindows: @escaping () -> Set<UUID>, uploads: @escaping () -> Set<UUID>, historyChanged: @escaping ([UUID]) -> Void
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
    private func heldCaptureIDs(for retention: HistoryRetention) -> Set<UUID> {
        cards(retention)
            .union(editors())
            .union(recordingWindows())
            .union(uploads())
            .union(clipboard.heldID.map { [$0] } ?? [])
    }

    /// With history off, a capture lives as long as something holds it (`heldCaptureIDs`); deletes it once nothing does.
    func releaseIfUnheld(_ id: UUID) {
        guard settings.historyRetention == .never, !heldCaptureIDs(for: .never).contains(id), let entry = history.item(id: id) else { return }
        history.delete(entry)
        historyChanged([id])
        sweepWallpaperPictures()
    }

    /// A recording went to the clipboard as a reference to its file in the history, which is all the clipboard has of it.
    /// With history off, the file stays until the clipboard holds something else, or until the next launch.
    func recordingCopied(_ id: UUID) {
        clipboard.copied(id, retention: settings.historyRetention)
    }

    /// Takes away the captures older than Settings keep them, but those something holds. The history is listed off the
    /// main actor, as it runs after every capture (Docs/perf.md › Main-thread work after a capture); a newer request
    /// takes over from one under way.
    func removeExpired() {
        expiry?.cancel()
        let retention = settings.historyRetention, keeping = heldCaptureIDs(for: retention), now = Date.now
        clipboard.updatePolling(for: retention)
        expiry = Task { [weak self, history] in
            let expired = await history.loadExpired(retention: retention, keeping: keeping, now: now)
            guard let self, !Task.isCancelled, settings.historyRetention == retention else { return }
            // Back on the main actor, and the listing took a while: a capture taken since is newer than `now`, one a
            // card, an editor, or the clipboard took up since is held now, and one added to Favorites since is kept;
            // none of them goes. With history off, that is every capture but the ones still in use.
            let current = history.stillExpired(expired, retention: retention, now: now)
            let removable = HistoryStore.removable(current, held: heldCaptureIDs(for: retention), checkedAt: now)
            removable.forEach(history.delete)
            if !removable.isEmpty {
                Log.capture.notice("Removed \(removable.count, privacy: .public) expired capture(s) from the history")
            }
            historyChanged(removable.map(\.id))
            sweepWallpaperPictures()
        }
    }

    /// How many captures a retention would delete now; captures still on screen as cards are kept.
    func expiredCount(for retention: HistoryRetention) -> Int {
        history.expired(retention: retention, keeping: heldCaptureIDs(for: retention)).count
    }

    /// How many of those are favorites, which only turning History off deletes.
    func expiredFavoriteCount(for retention: HistoryRetention) -> Int {
        history.expired(retention: retention, keeping: heldCaptureIDs(for: retention)).filter(\.isFavorite).count
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
