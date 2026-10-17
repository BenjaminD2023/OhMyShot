#if DEBUG
import AppKit
import Foundation
import OMSCore
import OMSUI
import OSLog

/// `debug/modelpack-*` endpoints: a pack served from this Mac (`Tools/model-packs/lab-server.py`) offered beside the
/// build's own, its download driven step by step, and the Settings pane rendered behind the wallpaper. Nothing is
/// shown and nothing leaves the Mac.
@MainActor
struct DebugModelPackHooks {
    /// Made when a hook first needs it, as Settings would.
    let center: () -> ModelPackCenter
    /// A Settings window of the hooks' own, not the one the user may have open.
    let makeSettings: () -> SettingsWindowController
    let capture: (NSWindow, String) async -> Void

    private static var settings: SettingsWindowController?

    /// Returns true when `url` was one of these.
    func handle(_ url: URL) -> Bool {
        let hook = url.pathComponents.dropFirst().first ?? ""
        guard hook.hasPrefix("modelpack-") else { return false }
        func value(_ name: String) -> String? { DebugHooks.parameter(name, in: url) }
        let center = self.center()
        let pack = value("id").flatMap { id in center.packs.first { $0.id == id } } ?? center.packs.last
        switch hook {
        case "modelpack-lab":
            // base=http://127.0.0.1:19010/ (default): offers the pack the lab server lists at <base>pack.json.
            let base = value("base").flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:19010/")!
            Task {
                do {
                    let (data, _) = try await URLSession(configuration: .ephemeral).data(from: base.appending(path: "pack.json"))
                    let offered = try JSONDecoder().decode(ModelPack.self, from: data)
                    center.debugOffer(offered)
                    await center.refresh()
                    Log.app.notice("debug.modelpack-lab offered \(offered.id, privacy: .public) \(offered.version, privacy: .public), \(offered.size, privacy: .public) bytes in \(offered.files.count, privacy: .public) files; \(state(of: offered), privacy: .public)")
                } catch {
                    Log.app.error("debug.modelpack-lab failed: \(String(describing: error), privacy: .public)")
                }
            }
        case "modelpack-offer":
            // Offers a pack the build lists but doesn't offer yet (`ModelPackCatalog.ppocrV6Small`), from its real host.
            center.debugOffer(ModelPackCatalog.ppocrV6Small)
            Task {
                await center.refresh()
                logStates()
            }
        case "modelpack-l2-read":
            // Reads the drawn demo page in the text reader with the installed pack (id=, default the L2 pack), twice:
            // the first read compiles the models into the pack's folder, the second finds them there. Logs time and size.
            let target = pack ?? ModelPackCatalog.ppocrV6Small
            guard let folder = center.installedFolder(of: target), let png = DebugPanelDemo.png(),
                  let helper = Bundle.main.url(forAuxiliaryExecutable: "OhMyShot Text Reader")
            else {
                Log.app.error("debug.modelpack-l2-read: the pack isn't installed")
                return true
            }
            Task {
                let file = FileManager.default.temporaryDirectory.appending(path: "OhMyShot L2 Demo.png")
                try? png.write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                for run in 1...2 {
                    let started = ContinuousClock.now
                    do {
                        let text = try await TextReaderTool.text(ofPictureAt: file, joinsWrappedLines: false, pack: folder, helper: helper)
                        Log.app.notice("debug.modelpack-l2-read run \(run, privacy: .public): \(text.count, privacy: .public) characters, \(text.split(separator: "\n").count, privacy: .public) lines in \(String(describing: ContinuousClock.now - started), privacy: .public)")
                    } catch {
                        Log.app.error("debug.modelpack-l2-read run \(run, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        case "modelpack-withdraw":
            // id=: takes the lab pack off the list again (its files stay until removed).
            if let pack { center.debugWithdraw(id: pack.id) }
            logStates()
        case "modelpack-act":
            // action=download|pause|cancel|remove|refresh, id= (default: the last pack listed).
            guard let pack else { return true }
            switch value("action") {
            case "download": center.download(pack)
            case "pause": center.pause(pack)
            case "cancel": center.cancel(pack)
            case "remove": center.remove(pack)
            default: Task { await center.refresh(); logStates() }
            }
            logStates()
        case "modelpack-state":
            logStates()
        case "modelpack-license":
            guard let pack else { return true }
            Task {
                do {
                    let text = try await center.license(of: pack)
                    Log.app.notice("debug.modelpack-license \(pack.id, privacy: .public): \(text.count, privacy: .public) characters, \(text.split(separator: "\n").count, privacy: .public) lines")
                } catch {
                    Log.app.error("debug.modelpack-license failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        case "modelpack-render":
            // Settings › Tools behind the wallpaper as <name>.png (modelpack-tools); consent=1 opens the first-download
            // sheet for the pack (license=1 an installed pack's license sheet) and renders it as <name>-consent.png. The
            // window closes once captured.
            // Each render has a window of its own, closed once it is captured, so no sheet stays over the next.
            Self.settings?.close()
            Self.settings = nil
            if value("close") == "1" { return true }
            let controller = makeSettings()
            Self.settings = controller
            controller.showBehindWallpaper(.tools)
            Task {
                defer {
                    if Self.settings === controller {
                        controller.close()
                        Self.settings = nil
                    }
                }
                try? await Task.sleep(for: .milliseconds(600))
                guard let window = controller.window else { return }
                if value("consent") == "1" || value("license") == "1", let pack {
                    let sheet: Notification.Name = value("license") == "1" ? .debugOpenModelPackLicense : .debugOpenModelPackConsent
                    NotificationCenter.default.post(name: sheet, object: nil, userInfo: ["id": pack.id])
                    try? await Task.sleep(for: .milliseconds(Int(value("wait") ?? "") ?? 1500))
                    if let sheet = window.attachedSheet {
                        await capture(sheet, "\(value("name") ?? "modelpack-tools")-consent")
                    } else {
                        Log.app.error("debug.modelpack-render no sheet")
                    }
                } else {
                    await capture(window, value("name") ?? "modelpack-tools")
                }
            }
        default:
            Log.app.error("debug.unknown \(hook, privacy: .public)")
        }
        return true
    }

    private func state(of pack: ModelPack) -> String {
        switch center().state(of: pack) {
        case .available: "available"
        case .paused(let done): "paused \(done)"
        case .downloading(let done): "downloading \(done)"
        case .installed(let receipt): "installed \(receipt.version) \(receipt.size)"
        case .failed(let message, let done): "failed \(done): \(message)"
        }
    }

    private func logStates() {
        let center = self.center()
        let states = center.packs.map { "\($0.id)=\(state(of: $0))" }.joined(separator: "; ")
        Log.app.notice("debug.modelpack-state \(states.isEmpty ? "no packs" : states, privacy: .public); resources \(ActiveResources.shared.isIdle ? "idle" : String(describing: ActiveResources.shared.snapshot), privacy: .public)")
    }
}
#endif
