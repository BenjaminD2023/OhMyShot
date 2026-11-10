import AppKit
import Foundation
import OMSCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Sharing: the storage captures are uploaded to, and whether the link is copied. This pane is the
/// only place the capture interface mentions uploading until a destination exists.
struct SharingSettingsView: View {
    @Bindable var settings: SettingsStore
    let destinations: UploadDestinationStore
    let records: UploadRecordStore
    let actions: SettingsDependencies.UploadRecordActions
    @State private var editing: UploadDestinationDraft?
    @State private var removing: UploadDestination?
    @State private var importProblem: String?
    @State private var importNotes: ImportNotes?
    #if DEBUG
    @State private var debugRunsTest = false
    #endif

    private struct ImportNotes: Identifiable {
        let id = UUID()
        let name: String
        let notes: [String]
    }

    /// How many finished uploads the list shows; the rest wait behind them.
    private static let recentLimit = 8

    var body: some View {
        SettingsPane {
            SettingsRow(String(localized: "Destinations", bundle: .module), help: [
                HelpTopic(String(localized: "Destinations", bundle: .module), Text("Add storage you own, such as an S3 bucket, a WebDAV folder, or your own server. Captures go from this Mac straight to it; OhMyShot has no server of its own.", bundle: .module)),
            ]) {
                VStack(alignment: .leading, spacing: 10) {
                    if destinations.destinations.isEmpty {
                        Text("No destinations yet", bundle: .module)
                            .foregroundStyle(.secondary)
                    } else {
                        list
                    }
                    addMenu
                }
            }

            SettingsDivider()

            SettingsRow(String(localized: "After upload", bundle: .module), help: [
                HelpTopic(String(localized: "Copy link after upload", bundle: .module), Text("With this off, the link waits in the capture’s menu: choose Copy Link on its card.", bundle: .module)),
            ]) {
                Toggle(isOn: $settings.copyLinkAfterUpload) {
                    Text("Copy link after upload", bundle: .module)
                }
            }

            if !records.records.isEmpty {
                SettingsDivider()

                SettingsRow(String(localized: "Recent uploads", bundle: .module), help: [
                    HelpTopic(String(localized: "Recent uploads", bundle: .module), Text("Forgetting an upload only takes it off this list. The file stays where it is, and its link keeps working.", bundle: .module)),
                ]) {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(spacing: 0) {
                            ForEach(Array(records.records.prefix(Self.recentLimit).enumerated()), id: \.element.id) { index, record in
                                if index > 0 { Divider() }
                                RecordRow(record: record, actions: actions)
                            }
                        }
                        .frame(minWidth: 280, maxWidth: 360)
                        .settingsWell()
                        HStack(spacing: 8) {
                            if records.records.count > Self.recentLimit {
                                Text("\(records.records.count - Self.recentLimit) older", bundle: .module)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Button(action: actions.forgetAll) { Text("Forget All", bundle: .module) }
                                .buttonStyle(.link)
                                .font(.callout)
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { draft in
            #if DEBUG
            UploadDestinationEditor(initial: draft, destinations: destinations, runsTestOnAppear: debugRunsTest) { editing = nil }
                .id(draft.id)
            #else
            UploadDestinationEditor(initial: draft, destinations: destinations) { editing = nil }
                .id(draft.id)
            #endif
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugOpenUploadEditor)) { note in
            // Scripted checks open an editor: a new one of a kind, or a saved destination by name.
            debugRunsTest = note.userInfo?["test"] as? Bool ?? false
            if let name = note.userInfo?["name"] as? String, let destination = destinations.destinations.first(where: { $0.name == name }) {
                edit(destination)
            } else if let kind = (note.userInfo?["kind"] as? String).flatMap(UploadDestinationDraft.Kind.init(rawValue:)) {
                editing = UploadDestinationDraft(kind: kind)
            } else {
                editing = nil
            }
        }
        #endif
        .confirmationDialog(
            removing.map { Text("Remove “\($0.name)”?", bundle: .module) } ?? Text(verbatim: ""),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { destination in
            Button(role: .destructive) {
                destinations.remove(id: destination.id)
            } label: {
                Text("Remove", bundle: .module)
            }
        } message: { _ in
            Text("Its saved keys and passwords are deleted from the Keychain. Files already uploaded stay where they are.", bundle: .module)
        }
        .alert(
            Text("The uploader couldn’t be imported", bundle: .module),
            isPresented: Binding(get: { importProblem != nil }, set: { if !$0 { importProblem = nil } })
        ) {
            Button { importProblem = nil } label: { Text("OK", bundle: .module) }
        } message: {
            Text(importProblem ?? "")
        }
        .alert(
            Text("Imported “\(importNotes?.name ?? "")”", bundle: .module),
            isPresented: Binding(get: { importNotes != nil }, set: { if !$0 { importNotes = nil } })
        ) {
            Button { importNotes = nil } label: { Text("OK", bundle: .module) }
        } message: {
            Text((importNotes?.notes ?? []).joined(separator: "\n"))
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            ForEach(Array(destinations.destinations.enumerated()), id: \.element.id) { index, destination in
                if index > 0 { Divider() }
                DestinationRow(
                    destination: destination,
                    isDefault: destination.id == destinations.defaultDestinationID,
                    edit: { edit(destination) },
                    makeDefault: { destinations.setDefault(id: destination.id) },
                    remove: { removing = destination }
                )
            }
        }
        .frame(minWidth: 280, maxWidth: 360)
        .settingsWell()
    }

    private var addMenu: some View {
        Menu {
            Button { editing = UploadDestinationDraft(kind: .amazonS3) } label: { Text("Amazon S3…", bundle: .module) }
            Button { editing = UploadDestinationDraft(kind: .s3Compatible) } label: { Text("S3-Compatible Storage…", bundle: .module) }
            Button { editing = UploadDestinationDraft(kind: .webDAV) } label: { Text("WebDAV…", bundle: .module) }
            Button { editing = UploadDestinationDraft(kind: .customHTTP) } label: { Text("Custom HTTP…", bundle: .module) }
            Divider()
            Button(action: importShareX) { Text("Import ShareX Uploader…", bundle: .module) }
        } label: {
            Label { Text("Add Destination", bundle: .module) } icon: { Image(systemName: "plus") }
        }
        .fixedSize()
    }

    private func edit(_ destination: UploadDestination) {
        let stored = Set(destination.secretFields.filter { destinations.hasSecret($0, of: destination) })
        editing = UploadDestinationDraft(destination: destination, storedSecrets: stored)
    }

    private func importShareX() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sxcu") ?? .json, .json]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a ShareX custom uploader file (.sxcu).", bundle: .module)
        panel.prompt = String(localized: "Import", bundle: .module)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try ShareXImporter.importUploader(fromFileAt: url)
            try destinations.add(imported)
            if !imported.notes.isEmpty { importNotes = ImportNotes(name: imported.destination.name, notes: imported.notes) }
        } catch {
            importProblem = error.localizedDescription
        }
    }
}

/// One finished upload in the list: its name, where it went and when, and its actions.
private struct RecordRow: View {
    let record: UploadRecord
    let actions: SettingsDependencies.UploadRecordActions

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(record.fileName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button { actions.copyLink(record) } label: { Text("Copy Link", bundle: .module) }
                .controlSize(.small)
                .disabled(record.isExpired())
            SettingsMoreMenu {
                Button { actions.open(record) } label: { Text("Open in Browser", bundle: .module) }
                    .disabled(record.isExpired())
                if actions.canDelete(record) {
                    // The coordinator asks in an alert, so a card and this list share one question.
                    Button(role: .destructive) { actions.delete(record) } label: { Text("Delete from Storage…", bundle: .module) }
                }
                Divider()
                Button { actions.forget(record) } label: { Text("Forget", bundle: .module) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private var subtitle: Text {
        let when = Text(record.date, format: .relative(presentation: .named))
        if record.isExpired() { return Text("\(record.destinationName) · \(when) · Expired", bundle: .module) }
        if let expiry = record.expiresAt {
            return Text("\(record.destinationName) · \(when) · Expires \(Text(expiry, format: .relative(presentation: .numeric)))", bundle: .module)
        }
        return Text("\(record.destinationName) · \(when)", bundle: .module)
    }
}

/// One destination in the list: its kind, name and where it points, a Default mark, and its actions.
private struct DestinationRow: View {
    let destination: UploadDestination
    let isDefault: Bool
    let edit: () -> Void
    let makeDefault: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(destination.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if isDefault {
                        Text("Default", bundle: .module)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary.opacity(0.7))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.primary.opacity(0.1), in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: edit) { Text("Edit…", bundle: .module) }
                .controlSize(.small)
            SettingsMoreMenu {
                Button(action: makeDefault) { Text("Make Default", bundle: .module) }
                    .disabled(isDefault)
                Divider()
                Button(role: .destructive, action: remove) { Text("Remove…", bundle: .module) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
    }

    private var symbol: String {
        switch destination.configuration {
        case .s3: "shippingbox"
        case .webDAV: "externaldrive"
        case .customHTTP: "server.rack"
        }
    }

    private var subtitle: String {
        switch destination.configuration {
        case .s3(let settings):
            "\(destination.localizedKindName) · \(settings.bucket) · \(settings.endpoint.host() ?? settings.endpoint.absoluteString)"
        case .webDAV(let settings):
            "\(destination.localizedKindName) · \(settings.baseURL.host() ?? settings.baseURL.absoluteString)"
        case .customHTTP(let settings):
            "\(destination.localizedKindName) · \(URL(string: settings.requestURL)?.host() ?? settings.requestURL)"
        }
    }
}

#if DEBUG
public extension Notification.Name {
    /// Opens an editor in Settings › Sharing for scripted checks: `kind` for a new destination, `name` for a
    /// saved one, `test` to run its Test Upload at once.
    static let debugOpenUploadEditor = Notification.Name("io.github.fzlzjerry.ohmyshot.debug.openUploadEditor")
}
#endif
