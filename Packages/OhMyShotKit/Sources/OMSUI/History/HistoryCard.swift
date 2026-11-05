import AppKit
import Foundation
import OMSCore
import OMSDesign
import SwiftUI

struct HistoryCard: View {
    let item: HistoryItem
    let model: HistoryModel
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                // The picture fills the card and is cropped to it, like a photo grid; the clear base keeps
                // the picture's own size out of the layout.
                Color.clear
                    .background(.background.secondary)
                    .overlay {
                        if let thumbnail = model.thumbnails[item.id] {
                            Image(decorative: thumbnail, scale: 2)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                if item.kind == .recording {
                    recordingBadge
                }
                if hovering {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(.black.opacity(0.28))
                    hoverActions
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.Radius.card + 4, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(-5)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .onHover { hovering = $0 }
            // Dragged out as the file, as from a Quick Access card: copied wherever it lands, never moved out
            // of the history.
            .onDrag { NSItemProvider(object: fileToHandOver as NSURL) }
            .dragConfiguration(DragConfiguration(operationsOutsideApp: .init(allowCopy: true, allowMove: false, allowDelete: false)))
            // Opens the capture in the annotation editor, a recording in the recording window, as in CleanShot;
            // Return and the hover button restore it to Quick Access.
            .onTapGesture(count: 2) { model.actions.annotate(item) }
            .simultaneousGesture(TapGesture().onEnded { model.click(item.id, modifiers: NSEvent.modifierFlags) })
            .task { await model.loadThumbnail(for: item) }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.createdAt, format: .relative(presentation: .named))
                    .font(.callout.weight(.medium))
                if let excerpt {
                    // What the search found, in the line it was found in.
                    Text(Self.attributed(excerpt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(verbatim: "\(item.pixelWidth) × \(item.pixelHeight)" + (item.appName.map { "  ·  \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .contextMenu { menu }
        .task(id: model.searchResultRevision) { await model.loadExcerpt(for: item.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        // VoiceOver's press does what a double-click does.
        .accessibilityAction { model.actions.annotate(item) }
        .accessibilityAction(named: Text("Restore", bundle: .module)) { model.actions.restore(item) }
        .accessibilityAction(named: Text("Copy", bundle: .module)) { model.actions.copy(item) }
        .accessibilityAction(named: Text("Save", bundle: .module)) { model.actions.save(item) }
        .accessibilityAction(named: Text("Quick Look", bundle: .module)) { model.quickLook(item) }
        .accessibilityActions {
            if item.kind == .screenshot {
                Button { model.actions.annotate(item) } label: { Text("Annotate", bundle: .module) }
                Button { model.actions.recognizeText(item) } label: { Text("Recognize Text", bundle: .module) }
                Button { model.actions.pin(item) } label: { Text("Pin to Screen", bundle: .module) }
                Button { model.print(item) } label: { Text("Print", bundle: .module) }
            }
            Button { Self.share(fileToHandOver) } label: { Text("Share", bundle: .module) }
            if EmailSharing.canSendRecently(model.store.fileURL(for: item)) {
                Button { EmailSharing.send(fileToHandOver) } label: { Text("Send by Email", bundle: .module) }
            }
            ForEach(Array(sharingEntries.enumerated()), id: \.offset) { _, entry in
                if case .uploadTo(let targets) = entry {
                    ForEach(targets) { target in
                        Button { model.actions.sharing.upload(item, target.id) } label: { Text(SharingEntry.uploadTitle(to: target)) }
                    }
                } else {
                    Button { run(entry) } label: { Text(entry.actionTitle) }
                }
            }
        }
        .accessibilityAction(named: Text("Move to Trash", bundle: .module)) { model.moveToTrash(item) }
    }

    /// The upload entries History offers for the capture now, for its menu and VoiceOver alike. A failed upload is the
    /// card's to show and retry: here a capture is being uploaded or not.
    private var sharingEntries: [SharingEntry] {
        let sharing = model.actions.sharing
        return sharing.menu().entries(
            state: sharing.isUploading(item) ? .uploading : .idle, hasLink: sharing.hasLink(item), canDelete: sharing.canDeleteFromStorage(item)
        )
    }

    /// Does what an upload entry of the menu or VoiceOver says.
    private func run(_ entry: SharingEntry) {
        let sharing = model.actions.sharing
        switch entry {
        case .cancelUpload: sharing.cancel(item)
        case .upload: sharing.upload(item, nil)
        case .copyLink: sharing.copyLink(item)
        case .deleteFromStorage: sharing.deleteFromStorage(item)
        // History offers no Retry or Copy Error, and each destination of Upload To is its own button.
        case .retryUpload, .copyError, .uploadTo: break
        }
    }

    /// The capture's file for another app, shared or dragged out: a copy in the format Settings choose, made when it is
    /// asked for, or the capture's own.
    private var fileToHandOver: URL {
        model.actions.fileToHandOver(item) ?? model.store.fileURL(for: item)
    }

    /// The system share sheet over the window: where the pointer is when the menu's Share… was chosen, else (for
    /// VoiceOver) the middle. Not a `ShareLink`, which needs its file before the menu opens, so every capture's copy
    /// would be made then.
    private static func share(_ file: URL, atPointer: Bool = false) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, let view = window.contentView else { return }
        var anchor = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        if atPointer {
            let pointer = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if view.bounds.contains(pointer) { anchor = pointer }
        }
        NSSharingServicePicker(items: [file]).show(relativeTo: CGRect(x: anchor.x, y: anchor.y, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    private var excerpt: HistorySearch.Excerpt? {
        model.matches?[item.id]?.excerpt
    }

    /// The excerpt with what was found in label ink and semibold, the rest left to the line's secondary ink.
    static func attributed(_ excerpt: HistorySearch.Excerpt) -> AttributedString {
        var found = AttributedString(excerpt.found)
        found.foregroundColor = .primary
        found.font = .caption.weight(.semibold)
        return AttributedString((excerpt.continuesBefore ? "…" : "") + excerpt.before) + found + AttributedString(excerpt.after)
    }

    /// When it was taken, and what the search found in it.
    private var accessibilityValue: Text {
        let time = Text(item.createdAt, format: .relative(presentation: .named))
        guard let excerpt else { return time }
        return Text("\(time), \(excerpt.before + excerpt.found + excerpt.after)", bundle: .module)
    }

    /// What it is, the app it was taken in, as the card's caption shows, and its size.
    private var accessibilityLabel: Text {
        let (width, height) = (item.pixelWidth, item.pixelHeight)
        guard let app = item.appName else {
            return switch item.media {
            case .screenshot: Text("Screenshot, \(width) by \(height) pixels", bundle: .module)
            case .movie: Text("Recording, \(width) by \(height) pixels", bundle: .module)
            case .gif: Text("GIF, \(width) by \(height) pixels", bundle: .module)
            }
        }
        return switch item.media {
        case .screenshot: Text("Screenshot from \(app), \(width) by \(height) pixels", bundle: .module)
        case .movie: Text("Recording from \(app), \(width) by \(height) pixels", bundle: .module)
        case .gif: Text("GIF from \(app), \(width) by \(height) pixels", bundle: .module)
        }
    }

    /// A small play badge in the corner, or "GIF" for a GIF, with the length when it is known.
    private var recordingBadge: some View {
        HStack(spacing: 4) {
            if item.media == .gif {
                Text(verbatim: "GIF")
            } else {
                Image(systemName: "play.fill")
            }
            if let duration = item.duration {
                Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                    .monospacedDigit()
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var hoverActions: some View {
        VStack(spacing: 10) {
            Button {
                model.actions.restore(item)
            } label: {
                Label {
                    Text("Restore", bundle: .module)
                } icon: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .font(.callout.weight(.semibold))
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)

            HStack(spacing: 6) {
                iconButton("doc.on.doc", Text("Copy", bundle: .module)) { model.actions.copy(item) }
                iconButton("square.and.arrow.down", Text("Save", bundle: .module)) { model.actions.save(item) }
                iconButton("folder", Text("Show in Finder", bundle: .module)) { model.actions.reveal(item) }
                iconButton("trash", Text("Move to Trash", bundle: .module)) { model.moveToTrash(item) }
            }
        }
    }

    private func iconButton(_ symbol: String, _ label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.glass)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var menu: some View {
        Button { model.actions.restore(item) } label: { Text("Restore", bundle: .module) }
            .keyboardShortcut(.return, modifiers: [])
        Button { model.actions.copy(item) } label: { Text("Copy", bundle: .module) }
            .keyboardShortcut("c")
        Button { model.actions.save(item) } label: { Text("Save", bundle: .module) }
            .keyboardShortcut("s")
        Divider()
        Button { model.quickLook(item) } label: { Text("Quick Look", bundle: .module) }
            .keyboardShortcut(.space, modifiers: [])
        Button { model.actions.annotate(item) } label: { Text(item.media.openMenuTitle) }
            .keyboardShortcut("o")
        Button { model.actions.open(item) } label: { Text("Open", bundle: .module) }
        if item.kind == .screenshot {
            Button { model.actions.recognizeText(item) } label: { Text("Recognize Text…", bundle: .module) }
            Button { model.actions.pin(item) } label: { Text("Pin to Screen", bundle: .module) }
            Button { model.print(item) } label: { Text("Print…", bundle: .module) }
        }
        Button { model.actions.reveal(item) } label: { Text("Show in Finder", bundle: .module) }
        Divider()
        Button { Self.share(fileToHandOver, atPointer: true) } label: { Text("Share…", bundle: .module) }
        if EmailSharing.canSendRecently(model.store.fileURL(for: item)) {
            Button { EmailSharing.send(fileToHandOver) } label: { Text("Send by Email", bundle: .module) }
        }
        ForEach(Array(sharingEntries.enumerated()), id: \.offset) { _, entry in
            if case .uploadTo(let targets) = entry {
                Menu {
                    ForEach(targets) { target in
                        Button { model.actions.sharing.upload(item, target.id) } label: {
                            if target.isDefault { Label(target.name, systemImage: "checkmark") } else { Text(target.name) }
                        }
                    }
                } label: {
                    Text(entry.menuTitle)
                }
            } else {
                Button { run(entry) } label: { Text(entry.menuTitle) }
            }
        }
        Divider()
        Button(role: .destructive) { model.moveToTrash(item) } label: { Text("Move to Trash", bundle: .module) }
            .keyboardShortcut(.delete)
    }
}
