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
            SettingsRow(Text("Destinations", bundle: .module)) {
                VStack(alignment: .leading, spacing: 10) {
                    if destinations.destinations.isEmpty {
                        Text("No destinations yet", bundle: .module)
                            .foregroundStyle(.secondary)
                    } else {
                        list
                    }
                    HStack(spacing: 6) {
                        addMenu
                        InfoButton(Text("Add storage you own, such as an S3 bucket, a WebDAV folder, or your own server. Captures go from this Mac straight to it; OhMyShot has no server of its own.", bundle: .module))
                    }
                }
            }

            SettingsDivider()

            SettingsRow(Text("After upload", bundle: .module)) {
                HStack(spacing: 6) {
                    Toggle(isOn: $settings.copyLinkAfterUpload) {
                        Text("Copy link after upload", bundle: .module)
                    }
                    InfoButton(Text("With this off, the link waits in the capture’s menu: choose Copy Link on its card.", bundle: .module))
                }
            }

            if !records.records.isEmpty {
                SettingsDivider()

                SettingsRow(Text("Recent uploads", bundle: .module)) {
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(spacing: 0) {
                            ForEach(Array(records.records.prefix(Self.recentLimit).enumerated()), id: \.element.id) { index, record in
                                if index > 0 { Divider() }
                                RecordRow(record: record, actions: actions)
                            }
                        }
                        .frame(width: 360)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                        HStack(spacing: 8) {
                            if records.records.count > Self.recentLimit {
                                Text("\(records.records.count - Self.recentLimit) older", bundle: .module)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Button(action: actions.forgetAll) { Text("Forget All", bundle: .module) }
                                .buttonStyle(.link)
                                .font(.callout)
                            InfoButton(Text("Forgetting an upload only takes it off this list. The file stays where it is, and its link keeps working.", bundle: .module))
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
        .frame(width: 360)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
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
            Menu {
                Button { actions.open(record) } label: { Text("Open in Browser", bundle: .module) }
                    .disabled(record.isExpired())
                if actions.canDelete(record) {
                    // The coordinator asks in an alert, so a card and this list share one question.
                    Button(role: .destructive) { actions.delete(record) } label: { Text("Delete from Storage…", bundle: .module) }
                }
                Divider()
                Button { actions.forget(record) } label: { Text("Forget", bundle: .module) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel(Text("More", bundle: .module))
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
            Menu {
                Button(action: makeDefault) { Text("Make Default", bundle: .module) }
                    .disabled(isDefault)
                Divider()
                Button(role: .destructive, action: remove) { Text("Remove…", bundle: .module) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel(Text("More", bundle: .module))
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
            "\(destination.kindName) · \(settings.bucket) · \(settings.endpoint.host() ?? settings.endpoint.absoluteString)"
        case .webDAV(let settings):
            "\(destination.kindName) · \(settings.baseURL.host() ?? settings.baseURL.absoluteString)"
        case .customHTTP(let settings):
            "\(destination.kindName) · \(URL(string: settings.requestURL)?.host() ?? settings.requestURL)"
        }
    }
}

// MARK: - Editor

/// A row of the editor: a label in a column of fixed width, a field that fills the rest, and a slot at the
/// right edge for the help button, kept empty where a row has none, so every field ends at the same place.
private struct EditorRow<Content: View>: View {
    let label: Text
    var info: Text?
    /// Whether the content fills the row (fields) or sits at its start (pop-ups, checkboxes).
    var fills = true
    @ViewBuilder var content: Content

    init(_ label: Text, info: Text? = nil, fills: Bool = true, @ViewBuilder content: () -> Content) {
        self.label = label
        self.info = info
        self.fills = fills
        self.content = content()
    }

    var body: some View {
        SettingsRow(label, labelWidth: 104) {
            HStack(spacing: 6) {
                content
                if let info {
                    InfoButton(info)
                } else if fills {
                    Color.clear.frame(width: 24, height: 1)
                }
            }
        }
    }
}

/// The sheet that adds or changes a destination. Secrets are typed into secure fields that say "Saved" when
/// the Keychain has one, and never show it; a field left empty keeps what is stored.
private struct UploadDestinationEditor: View {
    @State var draft: UploadDestinationDraft
    let destinations: UploadDestinationStore
    let close: () -> Void
    @State private var problem: String?
    @State private var test = TestState.idle
    @State private var testTask: Task<Void, Never>?

    #if DEBUG
    private let runsTestOnAppear: Bool
    init(initial: UploadDestinationDraft, destinations: UploadDestinationStore, runsTestOnAppear: Bool = false, close: @escaping () -> Void) {
        _draft = State(initialValue: initial)
        self.destinations = destinations
        self.runsTestOnAppear = runsTestOnAppear
        self.close = close
    }
    #else
    init(initial: UploadDestinationDraft, destinations: UploadDestinationStore, close: @escaping () -> Void) {
        _draft = State(initialValue: initial)
        self.destinations = destinations
        self.close = close
    }
    #endif

    enum TestState: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: UploadDestinationDraft.title(for: draft.kind))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .accessibilityAddTraits(.isHeader)
            SettingsPane(spacing: 10) {
                EditorRow(Text("Name", bundle: .module)) {
                    TextField(text: $draft.name) { Text("Name", bundle: .module) }
                        .labelsHidden()
                }
                switch draft.kind {
                case .amazonS3, .s3Compatible: s3Rows
                case .webDAV: webDAVRows
                case .customHTTP: customRows
                }
                SettingsDivider()
                EditorRow(
                    Text("File names", bundle: .module),
                    info: Text("Random names (ten letters and digits) can’t be guessed from the link before it. A capture’s own name carries its date and time and often the app it came from, which anyone with the link can read.", bundle: .module),
                    fills: false
                ) {
                    Picker(selection: $draft.fileNaming) {
                        Text("Random", bundle: .module).tag(FileNaming.random)
                        Text("As captured", bundle: .module).tag(FileNaming.original)
                    } label: {
                        Text("File names", bundle: .module)
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                }
                SettingsDivider()
                EditorRow(Text("Test", bundle: .module), fills: false) { testRow }
            }
            Divider()
            HStack {
                if let problem {
                    Label { Text(problem) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(role: .cancel, action: close) { Text("Cancel", bundle: .module) }
                    .keyboardShortcut(.cancelAction)
                Button(action: save) { Text("Save", bundle: .module) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: paneWidth)
        .onDisappear { testTask?.cancel() }
        #if DEBUG
        .onAppear { if runsTestOnAppear { runTest() } }
        #endif
        .onChange(of: draft) { problem = nil }
    }

    private func save() {
        guard let built = draft.build() else {
            problem = draft.firstIssue()
            return
        }
        do {
            try destinations.save(built.destination, secrets: built.secrets)
            close()
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: S3

    @ViewBuilder private var s3Rows: some View {
        if draft.kind == .s3Compatible {
            EditorRow(
                Text("Endpoint", bundle: .module),
                info: Text("The address of the S3 service, without the bucket. Cloudflare R2, MinIO, Backblaze B2, Wasabi, and other S3-compatible services each give you one.", bundle: .module)
            ) {
                TextField(text: $draft.endpoint, prompt: Text(verbatim: "https://<account>.r2.cloudflarestorage.com")) { Text("Endpoint", bundle: .module) }
                    .labelsHidden()
            }
        }
        EditorRow(
            Text("Region", bundle: .module),
            info: draft.kind == .s3Compatible
                ? Text("The region requests are signed for. Cloudflare R2 uses “auto”; MinIO usually accepts “us-east-1”.", bundle: .module)
                : nil
        ) {
            TextField(text: $draft.region) { Text("Region", bundle: .module) }
                .labelsHidden()
        }
        EditorRow(Text("Bucket", bundle: .module)) {
            TextField(text: $draft.bucket, prompt: Text(verbatim: "my-captures")) { Text("Bucket", bundle: .module) }
                .labelsHidden()
        }
        EditorRow(Text("Folder", bundle: .module)) {
            TextField(text: $draft.keyPrefix, prompt: Text("Optional", bundle: .module)) { Text("Folder", bundle: .module) }
                .labelsHidden()
        }
        SettingsDivider()
        EditorRow(Text("Access key ID", bundle: .module), fills: false) {
            SecretInput(text: $draft.accessKeyID, isStored: draft.isStored(SecretField.s3AccessKeyID), label: Text("Access key ID", bundle: .module))
        }
        EditorRow(Text("Secret key", bundle: .module), fills: false) {
            SecretInput(text: $draft.secretAccessKey, isStored: draft.isStored(SecretField.s3SecretAccessKey), label: Text("Secret key", bundle: .module))
        }
        SettingsDivider()
        EditorRow(
            Text("Link", bundle: .module),
            info: Text("S3 never hands back a link, so OhMyShot builds one. A public URL uses your bucket’s public domain below. An expiring link is signed with your key and works for anyone who has it until it runs out, which suits a private bucket.", bundle: .module),
            fills: false
        ) {
            Picker(selection: $draft.linkStyle) {
                Text("Public URL", bundle: .module).tag(S3Settings.LinkStyle.publicURL)
                Text("Expiring link", bundle: .module).tag(S3Settings.LinkStyle.presigned)
            } label: {
                Text("Link", bundle: .module)
            }
            .labelsHidden()
            .fixedSize()
        }
        if draft.linkStyle == .publicURL {
            EditorRow(
                Text("Public address", bundle: .module),
                info: Text("Where the files are served to people with the link: a custom domain, or an address like https://pub-xxxx.r2.dev. Leave it empty if the bucket itself allows anonymous reads; the link is then the file’s own address.", bundle: .module)
            ) {
                TextField(text: $draft.publicBaseURL, prompt: Text(verbatim: "https://img.example.com")) { Text("Public address", bundle: .module) }
                    .labelsHidden()
            }
        } else {
            EditorRow(
                Text("Expires after", bundle: .module),
                info: Text("S3 signatures last at most 7 days. After that the link stops working and the file stays in the bucket.", bundle: .module),
                fills: false
            ) {
                Stepper(value: $draft.presignedDays, in: 1...7) {
                    Text("\(draft.presignedDays) days", bundle: .module)
                        .monospacedDigit()
                }
            }
        }
        if draft.kind == .s3Compatible {
            EditorRow(
                Text("Addressing", bundle: .module),
                info: Text("Puts the bucket in the path (host/bucket/file) instead of the host name (bucket.host/file). Most self-hosted services and addresses like 127.0.0.1 need it; leave it on unless the service says otherwise.", bundle: .module),
                fills: false
            ) {
                Toggle(isOn: $draft.usesPathStyle) { Text("Path-style", bundle: .module) }
            }
        }
        EditorRow(
            Text("Access control", bundle: .module),
            info: Text("An optional canned ACL sent with each file, such as public-read. Leave it empty for Cloudflare R2, which refuses ACLs, and for buckets with a public policy.", bundle: .module)
        ) {
            TextField(text: $draft.acl, prompt: Text(verbatim: "public-read")) { Text("Access control", bundle: .module) }
                .labelsHidden()
        }
    }

    // MARK: WebDAV

    @ViewBuilder private var webDAVRows: some View {
        EditorRow(
            Text("Folder", bundle: .module),
            info: Text("The WebDAV address of the folder uploads go into. Nextcloud shows it under Files settings as the WebDAV address.", bundle: .module)
        ) {
            TextField(text: $draft.davURL, prompt: Text(verbatim: "https://cloud.example.com/remote.php/dav/files/me/")) { Text("Folder address", bundle: .module) }
                .labelsHidden()
        }
        EditorRow(Text("Subfolder", bundle: .module)) {
            TextField(text: $draft.keyPrefix, prompt: Text("Optional, created if missing", bundle: .module)) { Text("Subfolder", bundle: .module) }
                .labelsHidden()
        }
        EditorRow(Text("User name", bundle: .module)) {
            TextField(text: $draft.username, prompt: Text(verbatim: "me")) { Text("User name", bundle: .module) }
                .labelsHidden()
        }
        EditorRow(Text("Password", bundle: .module), fills: false) {
            SecretInput(text: $draft.password, isStored: draft.isStored(SecretField.webDAVPassword), label: Text("Password", bundle: .module))
        }
        SettingsDivider()
        EditorRow(
            Text("Public address", bundle: .module),
            info: Text("Where the folder is served to people with the link. Without it the link is the WebDAV address itself, which only opens for someone who can sign in.", bundle: .module)
        ) {
            TextField(text: $draft.publicBaseURL, prompt: Text("Optional", bundle: .module)) { Text("Public address", bundle: .module) }
                .labelsHidden()
        }
    }

    // MARK: Custom HTTP

    @ViewBuilder private var customRows: some View {
        EditorRow(Text("Request", bundle: .module)) {
            Picker(selection: $draft.method) {
                ForEach(CustomHTTPSettings.Method.allCases, id: \.self) { method in
                    Text(verbatim: method.rawValue).tag(method)
                }
            } label: {
                Text("Method", bundle: .module)
            }
            .labelsHidden()
            .fixedSize()
            TextField(text: $draft.requestURL, prompt: Text(verbatim: "https://example.com/upload")) { Text("Upload address", bundle: .module) }
                .labelsHidden()
        }
        EditorRow(
            Text("Body", bundle: .module),
            info: Text("A form sends the file in one field, with the form fields below; File only sends the file as the whole body.", bundle: .module)
        ) {
            Picker(selection: $draft.bodyType) {
                Text("Form", bundle: .module).tag(CustomHTTPSettings.BodyType.multipartFormData)
                Text("File only", bundle: .module).tag(CustomHTTPSettings.BodyType.binary)
            } label: {
                Text("Body", bundle: .module)
            }
            .labelsHidden()
            .fixedSize()
            if draft.bodyType == .multipartFormData {
                TextField(text: $draft.fileFormName, prompt: Text("File field", bundle: .module)) { Text("File field", bundle: .module) }
                    .labelsHidden()
                    .frame(width: 120)
            }
            Spacer(minLength: 0)
        }
        EditorRow(Text("Query", bundle: .module), fills: true) {
            ValueRows(rows: $draft.parameters, addTitle: Text("Add Parameter", bundle: .module))
        }
        EditorRow(Text("Headers", bundle: .module), fills: true) {
            ValueRows(rows: $draft.headers, addTitle: Text("Add Header", bundle: .module))
        }
        if draft.bodyType == .multipartFormData {
            EditorRow(Text("Form fields", bundle: .module), fills: true) {
                ValueRows(rows: $draft.arguments, addTitle: Text("Add Field", bundle: .module))
            }
        }
        SettingsDivider()
        EditorRow(
            Text("Link", bundle: .module),
            info: Text("How to find the link in the server’s answer, as in ShareX: {json:path.to.link}, {response}, {header:Location}. Empty means the whole answer is the link.", bundle: .module)
        ) {
            TextField(text: $draft.urlTemplate, prompt: Text(verbatim: "{json:data.link}")) { Text("Link", bundle: .module) }
                .labelsHidden()
        }
        EditorRow(
            Text("Error text", bundle: .module),
            info: Text("Optional. Shown when the server answers with an error, so a failed upload says why.", bundle: .module)
        ) {
            TextField(text: $draft.errorMessageTemplate, prompt: Text(verbatim: "{json:error}")) { Text("Error text", bundle: .module) }
                .labelsHidden()
        }
        EditorRow(Text("Deletion link", bundle: .module)) {
            TextField(text: $draft.deletionURLTemplate, prompt: Text("Optional", bundle: .module)) { Text("Deletion link", bundle: .module) }
                .labelsHidden()
        }
    }

    // MARK: Test

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: runTest) { Text("Test Upload", bundle: .module) }
                    .disabled(test == .running)
                    .help(Text("Uploads a small test image to this destination. It stays there.", bundle: .module))
                InfoButton(Text("Uploads a small test image to this destination. It stays there.", bundle: .module))
                if test == .running {
                    ProgressView().controlSize(.small)
                }
            }
            switch test {
            case .idle, .running:
                EmptyView()
            case .succeeded(let link):
                Label {
                    Text(link)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .font(.callout)
            case .failed(let message):
                Label {
                    Text(message)
                        .textSelection(.enabled)
                        .lineLimit(4)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func runTest() {
        guard let built = draft.build() else {
            test = .failed(draft.firstIssue() ?? "")
            return
        }
        test = .running
        let uploader = Uploader(secrets: draft.secretStore(over: destinations.secrets))
        testTask?.cancel()
        testTask = Task {
            let file = FileManager.default.temporaryDirectory.appending(path: "OhMyShot-test-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                try TestPicture.png().write(to: file)
                let result = try await uploader.upload(fileAt: file, to: built.destination, originalName: "OhMyShot test.png")
                if !Task.isCancelled { test = .succeeded(result.link.absoluteString) }
            } catch is CancellationError {
                test = .idle
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }
}

/// A secure field for a secret, which says "Saved" instead of showing what the Keychain holds.
private struct SecretInput: View {
    @Binding var text: String
    let isStored: Bool
    let label: Text

    var body: some View {
        HStack(spacing: 6) {
            SecureField(text: $text, prompt: isStored ? Text("Saved in Keychain", bundle: .module) : Text("Required", bundle: .module)) { label }
                .labelsHidden()
            // The lock takes the help button's place, so this field ends where the others do.
            ZStack {
                if isStored {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help(Text("Saved in the Keychain. Type a new value to replace it.", bundle: .module))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 24, height: 1)
        }
    }
}

/// The names and secret values of a custom uploader's query parameters, headers, or form fields.
private struct ValueRows: View {
    @Binding var rows: [UploadDestinationDraft.Row]
    let addTitle: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    TextField(text: $row.name, prompt: Text("Name", bundle: .module)) { Text("Name", bundle: .module) }
                        .labelsHidden()
                        .frame(width: 120)
                        // A renamed row is a new secret: what was stored under the old name no longer applies.
                        .onChange(of: row.name) { row.isStored = false }
                    SecureField(text: $row.value, prompt: row.isStored ? Text("Saved in Keychain", bundle: .module) : Text("Value", bundle: .module)) { Text("Value", bundle: .module) }
                        .labelsHidden()
                    Button {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Remove", bundle: .module))
                    .accessibilityLabel(Text("Remove", bundle: .module))
                }
            }
            Button { rows.append(.init()) } label: { addTitle }
                .controlSize(.small)
        }
    }
}

/// The small picture a test upload sends: a soft gradient with a rounded card on it, about a kilobyte.
enum TestPicture {
    static func png() throws -> Data {
        let size = CGSize(width: 160, height: 100)
        guard
            let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(srgbRed: 0.55, green: 0.76, blue: 1, alpha: 1), CGColor(srgbRed: 0.83, green: 0.78, blue: 1, alpha: 1)] as CFArray,
                locations: [0, 1]
            )
        else { throw CocoaError(.fileWriteUnknown) }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        context.setFillColor(CGColor(gray: 1, alpha: 0.9))
        context.addPath(CGPath(roundedRect: CGRect(x: 36, y: 26, width: 88, height: 48), cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.fillPath()
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}

#if DEBUG
public extension Notification.Name {
    /// Opens an editor in Settings › Sharing for scripted checks: `kind` for a new destination, `name` for a
    /// saved one, `test` to run its Test Upload at once.
    static let debugOpenUploadEditor = Notification.Name("io.github.fzlzjerry.ohmyshot.debug.openUploadEditor")
}
#endif
