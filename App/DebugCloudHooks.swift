#if DEBUG
import AppKit
import Foundation
import OMSCore
import OMSUI
import OSLog
import Synchronization

/// Scripted checks' cloud models: kept in memory and a defaults domain of their own, never in the person's settings or
/// Keychain. A model at demo.invalid answers from here, as told; any other reads for real, which the checks use only
/// with a server on this Mac.
nonisolated enum DebugCloudDemo {
    enum Behavior: String {
        /// Streams the demo page's text, with its table, in about a second.
        case succeed
        /// As succeed, but stops at its length limit.
        case incomplete
        /// Answers with nothing.
        case empty
        /// Never answers until cancelled.
        case hang
        /// The service refuses the key.
        case fail
        /// The service is busy (worth trying again).
        case busy
    }

    static let host = "demo.invalid"
    private static let behavior = Mutex(Behavior.succeed)

    static func setBehavior(_ new: Behavior) {
        behavior.withLock { $0 = new }
    }

    /// A store holding Claude at demo.invalid, its key in memory; `panel` and `captureText` say where it reads by itself.
    @MainActor
    static func store(panel: Bool, captureText: Bool) -> CloudModelStore {
        let suite = "\(Log.subsystem).debug.cloud"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let store = CloudModelStore(defaults: defaults, secrets: InMemorySecretStore())
        store.choose(.anthropic)
        if var claude = store.model {
            claude.address = "https://\(host)"
            store.update(claude)
        }
        try? store.setKey("demo-key")
        store.readsInPanel = panel
        store.readsCaptureText = captureText
        return store
    }

    /// The answer of a model at demo.invalid; nil for any other.
    static func stub(for model: CloudModel) -> (@Sendable (@escaping @Sendable (Int) -> Void) async throws -> CloudReading)? {
        guard model.host == host else { return nil }
        let behavior = behavior.withLock { $0 }
        return { progress in
            switch behavior {
            case .hang:
                try await Task.sleep(for: .seconds(3600))
                throw CancellationError()
            case .fail:
                try await Task.sleep(for: .milliseconds(400))
                throw CloudReadingError.keyRejected("invalid x-api-key")
            case .busy:
                try await Task.sleep(for: .milliseconds(400))
                throw CloudReadingError.overloaded(nil)
            case .empty:
                try await Task.sleep(for: .milliseconds(400))
                return CloudReading(text: "", model: model.model, isComplete: true, inputTokens: 1840, outputTokens: 1)
            case .succeed, .incomplete:
                var sent = 0
                for step in 1...5 {
                    try await Task.sleep(for: .milliseconds(200))
                    sent = demoText.count * step / 5
                    progress(sent)
                }
                return CloudReading(
                    text: demoText, model: model.model, isComplete: behavior == .succeed,
                    inputTokens: 2691, outputTokens: 214
                )
            }
        }
    }

    /// What a model might read on the drawn demo page.
    static let demoText = """
    OhMyShot Release Notes
    Capture text from anything on screen, then copy it as plain text, a table, or LaTeX.

    | Plan | Storage | Price |
    | --- | --- | --- |
    | Free | 5 GB | $0 |
    | Pro | 1 TB | $9.99 |

    The area of a circle is $A = \\pi r^2$.
    Contact: hello@example.com
    """
}

extension DebugHooks {
    /// Returns true when `hook` was one of these.
    func handleCloudHook(_ hook: String, _ url: URL) -> Bool {
        func value(_ name: String) -> String? { Self.parameter(name, in: url) }
        switch hook {
        case "cloud-demo":
            // on=1|0, panel=1 (every picture in the panel), capture=1 (Capture Text),
            // behavior=succeed|incomplete|empty|hang|fail|busy. Puts the demo model in place of the person's for the next
            // panel and Settings window (both are closed first).
            if let behavior = value("behavior").flatMap(DebugCloudDemo.Behavior.init(rawValue:)) {
                DebugCloudDemo.setBehavior(behavior)
            }
            if let on = value("on") {
                textCapture.closePanel()
                setCloudDemo(on == "1" ? DebugCloudDemo.store(panel: value("panel") == "1", captureText: value("capture") == "1") : nil)
                Log.app.notice("debug.cloud-demo on=\(on, privacy: .public)")
            }
        case "cloud-local":
            // name=, kind=openai|anthropic, address=http://127.0.0.1:<port>/v1, model=, key=: makes the demo model one at a
            // server on this Mac (demo models must be on).
            let kind: CloudModel.Kind = value("kind") == "anthropic" ? .anthropic : .openAICompatible
            let model = CloudModel(kind: kind, name: value("name") ?? "Local", address: value("address") ?? "http://127.0.0.1:19010/v1", model: value("model") ?? "local-vision")
            addCloudDemoModel(model, value("key"))
        default:
            return false
        }
        return true
    }
}
#endif
