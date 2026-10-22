import AppKit
import OMSCore
import SwiftUI

/// Settings › Text › Model packs: what each pack the build offers is for, what of it is on this Mac, and its
/// download. Shown only when the build offers a pack.
///
/// The first download of a pack asks first, with the pack's license to read, where it comes from, and its size;
/// going on with a paused or failed one doesn't ask again. An installed pack's license can be read again.
struct ModelPacksRow: View {
    let center: ModelPackCenter
    /// Its group's help, which it holds as the group's first row.
    var help: [HelpTopic] = []
    @State private var consenting: ModelPack?
    @State private var reading: ModelPack?
    @State private var removing: ModelPack?

    var body: some View {
        SettingsRow(String(localized: "Model packs", bundle: .module), help: help) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 0) {
                    ForEach(Array(center.packs.enumerated()), id: \.element.id) { index, pack in
                        if index > 0 { Divider() }
                        ModelPackRow(
                            pack: pack, state: center.state(of: pack),
                            download: {
                                if case .available = center.state(of: pack) { consenting = pack } else { center.download(pack) }
                            },
                            pause: { center.pause(pack) },
                            cancel: { center.cancel(pack) },
                            readLicense: { reading = pack },
                            remove: { removing = pack }
                        )
                    }
                }
                .frame(minWidth: 280, maxWidth: 360)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            }
        }
        .task { await center.refresh() }
        .sheet(item: $consenting) { pack in
            ModelPackConsent(pack: pack, center: center) { consenting = nil }
        }
        .sheet(item: $reading) { pack in
            ModelPackLicense(pack: pack, center: center) { reading = nil }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugOpenModelPackConsent)) { note in
            consenting = (note.userInfo?["id"] as? String).flatMap { id in center.packs.first { $0.id == id } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .debugOpenModelPackLicense)) { note in
            reading = (note.userInfo?["id"] as? String).flatMap { id in center.packs.first { $0.id == id } }
        }
        #endif
        .confirmationDialog(
            removing.map { Text("Remove “\($0.name)”?", bundle: .module) } ?? Text(verbatim: ""),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { pack in
            Button(role: .destructive) {
                center.remove(pack)
            } label: {
                Text("Remove", bundle: .module)
            }
        } message: { pack in
            // The L2 pack only reads beside Vision; without the formula pack, Capture Formula has nothing to read with; the
            // VLM pack only reads tables and charts in place of Vision's reading.
            if pack.id == ModelPackCatalog.ppFormulaNetPlusL.id {
                Text("Its \(ModelPackRow.size(pack.size)) are deleted from this Mac. Capture Formula is unavailable until it’s downloaded again.", bundle: .module)
            } else if pack.id == ModelPackCatalog.paddleOCRVL.id {
                Text("Its \(ModelPackRow.size(pack.size)) are deleted from this Mac. Tables and charts are read as plain text until it’s downloaded again.", bundle: .module)
            } else {
                Text("Its \(ModelPackRow.size(pack.size)) are deleted from this Mac. Text is read without it until it’s downloaded again.", bundle: .module)
            }
        }
    }

    /// Its part of its group's help: what a pack is, and where the packs come from, named as each pack names its host
    /// ("Hugging Face").
    static func help(center: ModelPackCenter) -> HelpTopic {
        var names: [String] = []
        for pack in center.packs where !names.contains(pack.host) { names.append(pack.host) }
        let hosts = names.formatted(.list(type: .or))
        return HelpTopic(String(localized: "Model packs", bundle: .module), Text("A model pack reads what macOS reads poorly or not at all, such as Chinese and Japanese text, math formulas, or tables and charts. It’s downloaded once, from \(hosts), and stays on this Mac; nothing you capture leaves it.", bundle: .module))
    }
}

/// One pack in the list: its name, where it stands, and what can be done with it now.
private struct ModelPackRow: View {
    let pack: ModelPack
    let state: ModelPackCenter.State
    let download: () -> Void
    let pause: () -> Void
    let cancel: () -> Void
    let readLicense: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(pack.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .help(pack.summary)
                if case .downloading(let done) = state {
                    ProgressView(value: Double(min(done, pack.size)), total: Double(pack.size))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .accessibilityLabel(Text("Downloading \(pack.name)", bundle: .module))
                    Text("\(Self.size(done)) of \(Self.size(pack.size))", bundle: .module)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text(subtitle)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(reason ?? "")
                        .accessibilityValue(Text(verbatim: reason ?? ""))
                }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var actions: some View {
        switch state {
        case .available:
            Button(action: download) { Text("Download…", bundle: .module) }
                .controlSize(.small)
        case .downloading:
            Button(action: pause) { Text("Pause", bundle: .module) }
                .controlSize(.small)
            more {
                Button(action: cancel) { Text("Cancel Download", bundle: .module) }
            }
        case .paused, .failed:
            Button(action: download) { Text("Resume", bundle: .module) }
                .controlSize(.small)
            more {
                Button(action: cancel) { Text("Cancel Download", bundle: .module) }
            }
        case .installed:
            more {
                Button(action: readLicense) { Text("License…", bundle: .module) }
                Divider()
                Button(role: .destructive, action: remove) { Text("Remove…", bundle: .module) }
            }
        }
    }

    private func more(@ViewBuilder _ items: () -> some View) -> some View {
        Menu(content: items) {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel(Text("More", bundle: .module))
    }

    private var subtitle: String {
        switch state {
        case .available:
            String(localized: "\(Self.size(pack.size)) · \(pack.license.name)", bundle: .module)
        case .paused(let done):
            String(localized: "Paused · \(Self.size(done)) of \(Self.size(pack.size))", bundle: .module)
        case .failed(_, let done):
            String(localized: "Couldn’t download · \(Self.size(done)) of \(Self.size(pack.size))", bundle: .module)
        case .installed:
            String(localized: "Installed · \(Self.size(pack.size)) · \(pack.license.name)", bundle: .module)
        case .downloading:
            ""
        }
    }

    /// Why the last download failed, for the tooltip and VoiceOver.
    private var reason: String? {
        if case .failed(let message, _) = state { message } else { nil }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// What a pack's first download asks: what it is, where it comes from, how large it is, and its license to read.
private struct ModelPackConsent: View {
    let pack: ModelPack
    let center: ModelPackCenter
    let done: () -> Void
    @State private var license: Result<String, Error>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download “\(pack.name)”?", bundle: .module)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(pack.summary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Size", bundle: .module).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(verbatim: ModelPackRow.size(pack.size))
                }
                GridRow {
                    Text("From", bundle: .module).foregroundStyle(.secondary)
                    Text(verbatim: pack.host)
                }
                GridRow {
                    Text("License", bundle: .module).foregroundStyle(.secondary)
                    Link(pack.license.name, destination: pack.license.url)
                }
                GridRow {
                    Text("Original model", bundle: .module).foregroundStyle(.secondary)
                    Link(pack.original.host().map { "\($0)\(pack.original.path())" } ?? pack.original.absoluteString, destination: pack.original)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.callout)
            Text("Checked before it’s used and kept on this Mac; nothing you capture is sent. Remove it any time in Settings › Text.", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LicenseWell(license: license) { Task { await load() } }
            HStack {
                Spacer()
                Button(role: .cancel) {
                    // What came to show the license goes; nothing else was fetched.
                    center.cancel(pack)
                    done()
                } label: {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    center.download(pack)
                    done()
                } label: {
                    Text("Download", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasLicense)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { await load() }
    }

    private var hasLicense: Bool {
        if case .success = license { true } else { false }
    }

    private func load() async {
        license = nil
        do {
            license = .success(try await center.license(of: pack))
        } catch is CancellationError {
        } catch {
            license = .failure(error)
        }
    }
}

/// An installed pack's license, to read again.
private struct ModelPackLicense: View {
    let pack: ModelPack
    let center: ModelPackCenter
    let done: () -> Void
    @State private var license: Result<String, Error>?

    private struct Missing: LocalizedError {
        var errorDescription: String? { String(localized: "The license isn’t on this Mac.", bundle: .module) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("“\(pack.name)” License", bundle: .module)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LicenseWell(license: license, height: 260, retry: nil)
            HStack {
                Spacer()
                Button(action: done) { Text("Done", bundle: .module) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task {
            if let text = await center.installedLicense(of: pack) { license = .success(text) } else { license = .failure(Missing()) }
        }
    }
}

/// A license's text in the rounded well, its hard-wrapped lines joined so they flow at the well's width.
struct LicenseWell: View {
    let license: Result<String, Error>?
    var height: CGFloat = 180
    let retry: (() -> Void)?

    var body: some View {
        Group {
            switch license {
            case nil:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .success(let text):
                ScrollView {
                    Text(verbatim: Self.reflowed(text))
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .accessibilityLabel(Text("License", bundle: .module))
            case .failure(let error):
                VStack(spacing: 8) {
                    Text(verbatim: error.localizedDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if let retry {
                        Button(action: retry) { Text("Try Again", bundle: .module) }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: height)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }

    /// Paragraphs as blank lines divide them, each one line: licenses such as Apache-2.0 come wrapped at about 78
    /// characters, which a narrower well would break again mid-line. A web address keeps a line of its own, as a
    /// notice of what was changed lists them one under another.
    static func reflowed(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { paragraph in
                var lines: [String] = []
                var joining = false
                for line in paragraph.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
                    let address = line.hasPrefix("https://") || line.hasPrefix("http://")
                    if joining, !address, let last = lines.popLast() {
                        lines.append(last + " " + line)
                    } else {
                        lines.append(line)
                    }
                    joining = !address
                }
                return lines.joined(separator: "\n")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

#if DEBUG
public extension Notification.Name {
    /// Opens the first-download sheet for the pack whose id is `userInfo["id"]`, in a Text pane on screen.
    static let debugOpenModelPackConsent = Notification.Name("OhMyShotDebugOpenModelPackConsent")
    /// Opens the installed pack's license sheet, as License… in its menu does.
    static let debugOpenModelPackLicense = Notification.Name("OhMyShotDebugOpenModelPackLicense")
    /// Asks to turn cloud reading off, as choosing Off with a key saved does, so its confirmation shows.
    static let debugOpenCloudSwitch = Notification.Name("OhMyShotDebugOpenCloudSwitch")
}
#endif
