import AppKit
import OMSCore
import UniformTypeIdentifiers

/// What OhMyShot offers in any app's Share menu: the pictures being shared go to the annotation editor or onto
/// the screen as pins.
///
/// The extension is sandboxed, so it cannot hand pictures to the app directly. It copies them into a batch
/// folder in the app's Share Inbox (its entitlements allow that one folder) and opens the app with a URL
/// naming the batch and what to do (see `ShareHandoff`). The app reads the pictures from its own inbox, so
/// nothing in the URL points outside it.
@objc(OMSShareViewController)
final class ShareViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private lazy var annotateButton = NSButton(title: String(localized: "Annotate"), target: self, action: #selector(annotate))
    private lazy var pinButton = NSButton(title: String(localized: "Pin"), target: self, action: #selector(pin))
    private lazy var cancelButton = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel))
    private lazy var closeButton = NSButton(title: String(localized: "Close"), target: self, action: #selector(cancel))

    /// The items being shared that are pictures; known once `offer()` has looked at them.
    private var pictures: [NSItemProvider] = []

    private var candidates: [NSItemProvider] {
        (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }.filter(\.mayHoldPicture)
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "OhMyShot"
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 120))
        preferredContentSize = view.frame.size

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 300
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        annotateButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        closeButton.keyEquivalent = "\r"
        closeButton.isHidden = true
        // Until the items have been looked at, there is nothing to choose between.
        for button in [annotateButton, pinButton] { button.isEnabled = false }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        for item in [spinner, cancelButton, closeButton, pinButton, annotateButton] { buttons.addView(item, in: .trailing) }
        let stack = NSStackView(views: [titleLabel, detailLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(14, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -18),
            buttons.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        offer()
    }

    /// The choice: what the pictures are to become. Only what is a picture is counted: a document shared
    /// with them is not handed over, so it is not offered.
    private func offer() {
        titleLabel.stringValue = String(localized: "Send to \(appName)")
        let candidates = candidates
        // Pictures say what they are. Files shared from Finder may be only an address, which takes a look.
        if candidates.allSatisfy(\.registersPictureType) { return show(candidates, announcing: false) }
        Task {
            var found: [NSItemProvider] = []
            for provider in candidates where await provider.holdsPicture() { found.append(provider) }
            show(found, announcing: true)
        }
    }

    private func show(_ found: [NSItemProvider], announcing: Bool) {
        pictures = found
        guard !found.isEmpty else {
            return fail(String(localized: "There is no picture here. \(appName) takes pictures to mark up or pin."))
        }
        // String(localized:) leaves the inflection markup as it is; an attributed string applies it.
        let count = found.count
        let line = String(AttributedString(localized: "^[\(count) picture](inflect: true) to mark up in the editor or keep on screen.").characters)
        if announcing { say(line) } else { detailLabel.stringValue = line }
        for button in [annotateButton, pinButton] { button.isEnabled = true }
    }

    @objc private func annotate() { handOver(.annotate) }
    @objc private func pin() { handOver(.pin) }

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func handOver(_ action: ShareHandoff.Action) {
        let pictures = pictures
        for button in [annotateButton, pinButton, cancelButton] { button.isEnabled = false }
        say(String(localized: "Sending…"))
        spinner.startAnimation(nil)
        Task {
            let inbox = ShareInbox.hosted(by: hostBundleIdentifier)
            do {
                let batch = try inbox.newBatch()
                var stored = 0
                for provider in pictures {
                    // One picture that cannot be read does not stop the others.
                    if (try? await batch.addPicture(from: provider)) != nil { stored += 1 }
                }
                guard stored > 0 else { throw ShareInbox.Failure.noPictures }
                guard await open(ShareHandoff(batch: batch.id, action: action).url(scheme: urlScheme)) else {
                    // Nobody is coming for them.
                    inbox.discard(batch: batch.id)
                    throw HandOverFailure.appNotOpened
                }
                extensionContext?.completeRequest(returningItems: nil)
            } catch {
                fail(String(localized: "The pictures could not be handed to \(appName). Open \(appName) once, then try again."))
            }
        }
    }

    private enum HandOverFailure: Error {
        /// The system could not open the app with the hand-over URL.
        case appNotOpened
    }

    private func fail(_ message: String) {
        spinner.stopAnimation(nil)
        say(message)
        for button in [annotateButton, pinButton, cancelButton] { button.isHidden = true }
        closeButton.isHidden = false
    }

    /// Changes the line under the title, and tells VoiceOver, which does not follow text that changes by itself.
    private func say(_ text: String) {
        detailLabel.stringValue = text
        NSAccessibility.post(element: detailLabel, notification: .announcementRequested, userInfo: [.announcement: text])
    }

    // MARK: Opening the app

    private var hostBundleIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "OMSHostBundleIdentifier") as? String ?? "io.github.fzlzjerry.ohmyshot"
    }

    private var urlScheme: String {
        Bundle.main.object(forInfoDictionaryKey: "OMSURLScheme") as? String ?? "ohmyshot"
    }

    /// The app this extension is inside (`App.app/Contents/PlugIns/This.appex`), so the pictures go to that
    /// copy even with others installed, when it is the app they are meant for.
    private var hostApplicationURL: URL? {
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: app)?.bundleIdentifier == hostBundleIdentifier ? app : nil
    }

    /// Opens the app with the hand-over URL; whether the system could.
    private func open(_ url: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let app = hostApplicationURL {
            return (try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)) != nil
        }
        return NSWorkspace.shared.open(url)
    }
}
