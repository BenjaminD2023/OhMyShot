#if DEBUG
import AppKit
import Foundation
import OMSCore
import OMSUI
import OSLog

/// `debug/upload-*` endpoints: test destinations pointing at servers on this Mac, uploads that put their link
/// on a pasteboard of their own, and the card and Settings states for snapshots. The real clipboard is never
/// touched: every hook here points link copying at the private pasteboard first.
extension DebugHooks {
    /// Where links are copied while these hooks are in use.
    private static let pasteboardName = NSPasteboard.Name("\(Log.subsystem).upload-lab")
    /// Names of the destinations the lab adds start with this, so removing them removes nothing else.
    private static let labPrefix = "Lab "

    private func privatePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: Self.pasteboardName)
        uploads.pasteboard = pasteboard
        return pasteboard
    }

    /// Returns true when `hook` was one of these.
    func handleUploadHook(_ hook: String, _ url: URL) -> Bool {
        func value(_ name: String) -> String? { Self.parameter(name, in: url) }
        switch hook {
        case "upload-lab":
            // kind=s3|webdav|custom, name=, default=1; per kind: endpoint/bucket/access/secret/prefix/link=presigned/
            // public= for s3, url/user/pass/public/prefix for webdav, url/body=binary for custom. Defaults point at
            // the servers of the scratchpad lab on 127.0.0.1 (S3 19000, WebDAV 19001, receiver 19002).
            _ = privatePasteboard()
            addLabDestination(kind: value("kind") ?? "s3", value: value)
        case "upload-lab-remove":
            let pasteboard = privatePasteboard()
            let lab = uploads.destinations.destinations.filter { $0.name.hasPrefix(Self.labPrefix) }
            for destination in lab { uploads.destinations.remove(id: destination.id) }
            pasteboard.clearContents()
            // Reading an item that is gone never asks for anything; this proves the Keychain is empty of them.
            let leftover = lab.flatMap { destination in destination.secretFields.filter { uploads.destinations.secrets.secret($0, of: destination.id) != nil } }
            Log.app.notice("debug.upload-lab-remove removed \(lab.count, privacy: .public), secrets left \(leftover.count, privacy: .public), destinations left \(uploads.destinations.destinations.count, privacy: .public)")
        case "upload-test":
            // file=<path> (default: the newest capture), dest=<name> (default: the default destination), card=1
            // uploads the newest capture under its own id, so its card shows the upload.
            let pasteboard = privatePasteboard()
            pasteboard.clearContents()
            guard let file = value("file").map({ URL(filePath: $0) }) ?? latestCaptureFile() else {
                Log.app.notice("debug.upload failed no file")
                return true
            }
            let destination = value("dest").flatMap { name in uploads.destinations.destinations.first { $0.name == name }?.id }
            if value("dest") != nil, destination == nil {
                Log.app.notice("debug.upload failed no such destination")
                return true
            }
            let id = value("card") == "1" ? (latestCaptureID() ?? UUID()) : UUID()
            observeUpload(id, pasteboard: pasteboard)
            let started = uploads.upload(captureID: id, fileURL: file, destinationID: destination)
            Log.app.notice("debug.upload started \(started, privacy: .public)")
        case "upload-cancel":
            if let id = latestCaptureID() { uploads.cancel(captureID: id) }
        case "upload-retry":
            if let id = latestCaptureID() { uploads.retry(captureID: id) }
        case "upload-copy-link":
            // The card's Copy Link, for the newest capture.
            let pasteboard = privatePasteboard()
            if let id = latestCaptureID() { uploads.copyLink(captureID: id) }
            logPasteboard(pasteboard)
        case "upload-pasteboard":
            logPasteboard(privatePasteboard())
        case "upload-card":
            // state=uploading|finished|kept|failed, fraction=0.42: puts the newest card in a state to look at.
            let id = latestCaptureID() ?? UUID()
            let fraction = value("fraction").flatMap(Double.init) ?? 0.42
            let state: CardUpload? = switch value("state") {
            case "uploading": .uploading(fraction: fraction)
            case "finished": .finished(linkCopied: true)
            case "kept": .finished(linkCopied: false)
            case "failed": .failed(message: value("message") ?? UploadError.unreachable(host: "files.example.com").localizedDescription)
            default: nil
            }
            quickAccess.setUpload(state, for: id)
        case "upload-card-menu":
            // The newest card's More menu, opened for a moment and snapshot while open; its titles are logged.
            quickAccess.debugShowMenuOnLatest { titles in
                Log.app.notice("debug.upload-card-menu \(titles.joined(separator: " | "), privacy: .public)")
                await snapshotWindows()
            }
        case "upload-menu":
            // What the menus offer right now, by the one rule cards and History share.
            let menu = uploads.destinations.menu
            Log.app.notice("debug.upload-menu \(String(describing: menu), privacy: .public) destinations \(uploads.destinations.destinations.map(\.name).joined(separator: ", "), privacy: .public)")
        case "upload-editor":
            // kind=amazonS3|s3Compatible|webDAV|customHTTP for a new one, name= for a saved one, test=1 runs its
            // Test Upload at once. Open Settings › Sharing first.
            var info: [String: Any] = [:]
            if let kind = value("kind") { info["kind"] = kind }
            if let name = value("name") { info["name"] = name }
            info["test"] = value("test") == "1"
            NotificationCenter.default.post(name: .debugOpenUploadEditor, object: nil, userInfo: info)
        case "upload-editor-close":
            NotificationCenter.default.post(name: .debugOpenUploadEditor, object: nil, userInfo: [:])
        case "url-command":
            // q=capture-fullscreen%3Faction%3Dupload: the URL API command, through the parser and `perform`.
            // A capture command reads the screen: ask first.
            guard let query = value("q"), let command = URL(string: "ohmyshot-dev://\(query)") else { return true }
            switch AutomationURLParser.parse(command, scheme: "ohmyshot-dev") {
            case .success(let parsed): Log.app.notice("debug.url-command \(String(describing: parsed), privacy: .public)"); perform(parsed)
            case .failure(let error): Log.app.notice("debug.url-command failed \(String(describing: error), privacy: .public)")
            }
        case "upload-area":
            // The centered 400 x 300 region of the primary display captured as capture-test does, then handed to
            // `action=upload`'s follow-up; snap=1 snapshots the windows at once, for the message shown by the pointer.
            _ = privatePasteboard()
            observeUpload(UUID(), pasteboard: uploads.pasteboard, any: true)
            if let display = displays.layout.primary {
                let rect = CGRect(x: display.frame.midX - 200, y: display.frame.midY - 150, width: 400, height: 300)
                let snap = value("snap") == "1"
                Task {
                    await captures.captureArea(rect, appName: "Test", copiesToClipboard: false, followUp: CaptureFollowUp(action: .upload, asksForName: false))
                    if snap { await snapshotWindows() }
                }
            }
        case "upload-card-share":
            quickAccess.debugShareLatest()
        case "upload-quit":
            // Quits as the menu's Quit does, with an upload possibly running.
            NSApp.terminate(nil)
        case "remove-check-captures":
            Log.app.notice("debug.remove-check-captures \(removeCheckCaptures(), privacy: .public)")
        case "upload-after-setting":
            // value=1|0: Settings' Upload after a capture and after a recording.
            settings.uploadAfterCapture = value("value") == "1"
            settings.uploadAfterRecording = value("value") == "1"
            Log.app.notice("debug.upload-after-setting \(settings.uploadAfterCapture, privacy: .public)")
        case "copy-after-setting":
            // value=1|0: Settings' Copy after a capture and after a recording, so a scripted capture that goes
            // through the setting leaves the real clipboard alone.
            settings.copyAfterCapture = value("value") == "1"
            settings.copyAfterRecording = value("value") == "1"
            Log.app.notice("debug.copy-after-setting \(settings.copyAfterCapture, privacy: .public)")
        case "upload-plain-area":
            // The centered region of the primary display, kept as a plain capture (no follow-up of its own), so
            // only Settings' Upload decides whether it is uploaded.
            _ = privatePasteboard()
            observeUpload(UUID(), pasteboard: uploads.pasteboard, any: true)
            if let display = displays.layout.primary {
                let rect = CGRect(x: display.frame.midX - 200, y: display.frame.midY - 150, width: 400, height: 300)
                Task { await captures.captureArea(rect, appName: "Test", copiesToClipboard: false) }
            }
        case "upload-hotkey":
            // name=captureAreaAndUpload|captureFullscreenAndUpload: what the shortcut does, with links going to the
            // private pasteboard. Capture Fullscreen reads the real screen: turn copy-after-setting off first.
            _ = privatePasteboard()
            observeUpload(UUID(), pasteboard: uploads.pasteboard, any: true)
            if let shortcut = value("name").flatMap(CaptureShortcut.init(rawValue:)) { pressShortcut(shortcut) }
        case "upload-records":
            // The finished uploads the records hold, newest first.
            let records = uploads.records.records
            Log.app.notice("debug.upload-records \(records.count, privacy: .public)")
            for record in records.prefix(20) {
                let expiry = record.expiresAt.map { "expires \($0.formatted(.iso8601))" } ?? "no expiry"
                Log.app.notice("debug.upload-record \(record.fileName, privacy: .public) to \(record.destinationName, privacy: .public) (\(record.destinationKind, privacy: .public)) capture \(record.captureID?.uuidString.prefix(8) ?? "none", privacy: .public) \(expiry, privacy: .public) removal \(String(describing: record.removal), privacy: .public) \(record.link.absoluteString, privacy: .public)")
            }
        case "upload-seed":
            // Adds a record for the newest capture without uploading: name=, dest=<destination name>, expired=1,
            // key=<remote key>, link=, deletion=. For states that are hard to reach by uploading.
            let destination = value("dest").flatMap { name in uploads.destinations.destinations.first { $0.name == name } } ?? uploads.destinations.defaultDestination
            guard let destination else { return true }
            let name = value("name") ?? "seeded.png"
            let result = UploadResult(
                link: URL(string: value("link") ?? "https://files.example.com/\(name)")!,
                deletionURL: value("deletion").flatMap(URL.init(string:)), fileName: name,
                expiresAt: value("expired") == "1" ? .now.addingTimeInterval(-3600) : value("expires").flatMap(Double.init).map { .now.addingTimeInterval($0) },
                remoteKey: value("key")
            )
            uploads.records.add(UploadRecord(captureID: latestCaptureID(), date: .now.addingTimeInterval(-Double(value("ago").flatMap(Int.init) ?? 300)), fileName: name, destination: destination, result: result))
            Log.app.notice("debug.upload-seed \(name, privacy: .public)")
        case "upload-forget-all":
            uploads.forgetAllRecords()
            Log.app.notice("debug.upload-forget-all left \(uploads.records.records.count, privacy: .public)")
        case "upload-delete":
            // Delete from Storage for the newest capture. confirm=yes|no answers the question for itself and logs
            // what it asked; without it the real alert shows (snapshot it with `snapshot`).
            let pasteboard = privatePasteboard()
            _ = pasteboard
            if let answer = value("confirm") {
                uploads.confirmDeletion = { title, message, button, _ in
                    Log.app.notice("debug.upload-delete asked: \(title, privacy: .public) | \(message, privacy: .public) | \(button, privacy: .public)")
                    return answer == "yes"
                }
            }
            guard let id = latestCaptureID() else { return true }
            Log.app.notice("debug.upload-delete can \(uploads.canDeleteFromStorage(id), privacy: .public)")
            uploads.deleteFromStorage(captureID: id)
        case "upload-copy-link-setting":
            settings.copyLinkAfterUpload = value("value") != "0"
            Log.app.notice("debug.upload-copy-link-setting \(settings.copyLinkAfterUpload, privacy: .public)")
        default:
            return false
        }
        return true
    }

    private func logPasteboard(_ pasteboard: NSPasteboard) {
        Log.app.notice("debug.upload-pasteboard \(pasteboard.string(forType: .string) ?? "(empty)", privacy: .public)")
    }

    /// Logs an upload's course: its start, each quarter it passes, and how it ended, with the link and what the
    /// private pasteboard then holds. Debug builds only; links are logged because the lab's are local.
    private func observeUpload(_ id: UUID, pasteboard: NSPasteboard, any: Bool = false) {
        var quarter = -1
        uploads.debugStatus = { changed, status in
            guard changed == id || any else { return }
            switch status {
            case .uploading(let fraction)?:
                let now = Int(fraction * 4)
                if now != quarter { quarter = now; Log.app.notice("debug.upload uploading \(Int(fraction * 100), privacy: .public)%") }
            case .finished(let link)?:
                Log.app.notice("debug.upload finished \(link.absoluteString, privacy: .public)")
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    Log.app.notice("debug.upload-pasteboard \(pasteboard.string(forType: .string) ?? "(empty)", privacy: .public)")
                }
            case .failed(let message)?:
                Log.app.notice("debug.upload failed \(message, privacy: .public)")
            case nil:
                Log.app.notice("debug.upload cancelled")
            }
        }
    }

    private func addLabDestination(kind: String, value: (String) -> String?) {
        let naming: FileNaming = value("naming") == "random" ? .random : .original
        let prefix = value("prefix") ?? ""
        let destination: UploadDestination
        var secrets: [String: String] = [:]
        switch kind {
        case "webdav":
            destination = UploadDestination(
                name: value("name") ?? "Lab WebDAV", fileNaming: naming,
                configuration: .webDAV(WebDAVSettings(
                    baseURL: URL(string: value("url") ?? "http://127.0.0.1:19001/")!, username: value("user") ?? "alice",
                    publicBaseURL: value("public").flatMap(URL.init(string:)), keyPrefix: prefix
                ))
            )
            secrets[SecretField.webDAVPassword] = value("pass") ?? "wonderland"
        case "custom":
            let binary = value("body") == "binary"
            let settings = CustomHTTPSettings(
                method: binary ? .put : .post,
                requestURL: value("url") ?? "http://127.0.0.1:19002/upload",
                headerNames: [binary ? "X-Token" : "Authorization"],
                bodyType: binary ? .binary : .multipartFormData,
                urlTemplate: "{json:data.link}",
                errorMessageTemplate: "{json:error}"
            )
            destination = UploadDestination(name: value("name") ?? "Lab Custom", fileNaming: naming, configuration: .customHTTP(settings))
            secrets[SecretField.header(binary ? "X-Token" : "Authorization")] = binary ? "tok123" : "Bearer tok123"
        default:
            var settings = S3Settings(
                endpoint: URL(string: value("endpoint") ?? "http://127.0.0.1:19000")!, region: value("region") ?? "us-east-1",
                bucket: value("bucket") ?? "bk", keyPrefix: prefix, publicBaseURL: value("public").flatMap(URL.init(string:)),
                linkStyle: value("link") == "presigned" ? .presigned : .publicURL
            )
            settings.presignedExpiry = 3600
            destination = UploadDestination(name: value("name") ?? "Lab S3", fileNaming: naming, configuration: .s3(settings))
            secrets[SecretField.s3AccessKeyID] = value("access") ?? "ACCESSKEY"
            secrets[SecretField.s3SecretAccessKey] = value("secret") ?? "SECRETKEY123"
        }
        do {
            try uploads.destinations.save(destination, secrets: secrets)
            if value("default") == "1" { uploads.destinations.setDefault(id: destination.id) }
            Log.app.notice("debug.upload-lab added \(destination.name, privacy: .public) (\(destination.kindName, privacy: .public)), \(uploads.destinations.destinations.count, privacy: .public) destination(s)")
        } catch {
            Log.app.error("debug.upload-lab failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
