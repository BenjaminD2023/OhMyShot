import Foundation
import OMSCore
import SwiftUI

/// A row of the editor: a label in a column of fixed width, a field that fills the rest, and a slot at the
/// right edge for the help button, kept empty where a row has none, so every field ends at the same place.
struct EditorRow<Content: View>: View {
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
struct UploadDestinationEditor: View {
    @State var draft: UploadDestinationDraft
    let destinations: UploadDestinationStore
    let close: () -> Void
    @State private var problem: String?
    @State private var test = SettingsTestState.idle
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
                    SettingsWarning(Text(problem))
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
                Stepper(value: $draft.presignedDays, in: S3Settings.presignedDayRange) {
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
        SettingsTestRow(
            state: test, title: Text("Test Upload", bundle: .module),
            help: Text("Uploads a small test image to this destination. It stays there.", bundle: .module), succeedsWithLink: true,
            run: runTest
        )
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
            do {
                let result = try await uploader.testUpload(to: built.destination)
                if !Task.isCancelled { test = .succeeded(result.link.absoluteString) }
            } catch is CancellationError {
                test = .idle
            } catch {
                test = .failed(error.localizedDescription)
            }
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
