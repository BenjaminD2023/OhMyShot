import AppKit
import Foundation
import OMSCore
import UniformTypeIdentifiers

/// What OhMyShot offers in any app's Share menu: the pictures being shared go to the annotation editor,
/// onto the screen as pins, or to text recognition.
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
    private let buttonsStack = NSStackView()
    private let contentStack = NSStackView()
    private lazy var annotateButton = NSButton(title: String(localized: "Annotate"), target: self, action: #selector(annotate))
    private lazy var pinButton = NSButton(title: String(localized: "Pin"), target: self, action: #selector(pin))
    private lazy var recognizeTextButton = NSButton(title: String(localized: "Recognize Text"), target: self, action: #selector(recognizeText))
    private lazy var cancelButton = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel))
    private lazy var closeButton = NSButton(title: String(localized: "Close"), target: self, action: #selector(cancel))

    /// The items being shared that are pictures (capped at `ShareInbox.maximumPictures`); known once `offer()` finishes.
    private var pictures: [NSItemProvider] = []
    /// Total picture items found before capping at `ShareInbox.maximumPictures`.
    private var totalPictureCount = 0
    private var offerTask: Task<Void, Never>?
    private var handOverTask: Task<Void, Never>?
    private var activeBatch: (inbox: ShareInbox, id: UUID)?
    private var keyMonitor: Any?
    private var isFinished = false

    private var actionButtons: [NSButton] {
        [annotateButton, pinButton, recognizeTextButton]
    }

    private var candidates: [NSItemProvider] {
        (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }.filter(\.mayHoldPicture)
    }

    private var appName: String {
        AppIdentity.displayName
    }

    isolated deinit {
        removeKeyMonitor()
        offerTask?.cancel()
        handOverTask?.cancel()
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 124))
        preferredContentSize = view.frame.size

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 400
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityLabel(String(localized: "Sending"))

        annotateButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        closeButton.keyEquivalent = "\r"
        closeButton.isHidden = true
        // Until the items have been looked at, there is nothing to choose between.
        for button in actionButtons { button.isEnabled = false }

        buttonsStack.orientation = .horizontal
        buttonsStack.spacing = 8
        buttonsStack.addView(spinner, in: .leading)
        buttonsStack.addView(cancelButton, in: .leading)
        for item in [closeButton, recognizeTextButton, pinButton, annotateButton] {
            buttonsStack.addView(item, in: .trailing)
        }

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6
        contentStack.setViews([titleLabel, detailLabel, buttonsStack], in: .top)
        contentStack.setCustomSpacing(14, after: detailLabel)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            contentStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -18),
            buttonsStack.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            buttonsStack.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
        ])
        offer()
        updatePreferredContentSize()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        installKeyMonitor()
        updatePreferredContentSize()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        removeKeyMonitor()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updatePreferredContentSize()
    }

    override func cancelOperation(_ sender: Any?) {
        cancel()
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let isEscape = event.keyCode == 53
            let isCommandPeriod = event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "."
            guard isEscape || isCommandPeriod else { return event }
            MainActor.assumeIsolated { self.cancel() }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// Recomputes preferredContentSize so localized button titles and wrapped detail text never clip.
    private func updatePreferredContentSize() {
        view.layoutSubtreeIfNeeded()
        let minimumWidth: CGFloat = 420
        let buttonsWidth = buttonsStack.fittingSize.width + 40
        let width = max(minimumWidth, ceil(buttonsWidth))
        if abs(detailLabel.preferredMaxLayoutWidth - (width - 40)) > 0.5 {
            detailLabel.preferredMaxLayoutWidth = width - 40
            view.layoutSubtreeIfNeeded()
        }
        let height = max(116, ceil(contentStack.fittingSize.height + 36))
        let target = NSSize(width: width, height: height)
        if abs(preferredContentSize.width - target.width) > 0.5 || abs(preferredContentSize.height - target.height) > 0.5 {
            preferredContentSize = target
        }
    }

    /// The choice: what the pictures are to become. Only what is a picture is counted: a document shared
    /// with them is not handed over, so it is not offered.
    private func offer() {
        titleLabel.stringValue = String(localized: "Send to \(appName)")
        let candidates = candidates
        // Pictures say what they are. Files shared from Finder may be only an address, which takes a look.
        if candidates.allSatisfy(\.registersPictureType) { return show(candidates, announcing: false) }
        detailLabel.stringValue = String(localized: "Checking shared items…")
        spinner.startAnimation(nil)
        offerTask = Task {
            var found: [NSItemProvider] = []
            for provider in candidates {
                if Task.isCancelled { return }
                if await provider.holdsPicture() { found.append(provider) }
            }
            guard !Task.isCancelled, !isFinished else { return }
            spinner.stopAnimation(nil)
            show(found, announcing: true)
        }
    }

    private func show(_ found: [NSItemProvider], announcing: Bool) {
        totalPictureCount = found.count
        let limit = ShareInbox.maximumPictures
        pictures = Array(found.prefix(limit))
        guard !found.isEmpty else {
            return fail(String(localized: "No readable pictures were shared. \(appName) takes pictures to mark up, pin, or recognize text from."))
        }
        // String(localized:) leaves the inflection markup as it is; an attributed string applies it.
        let line: String
        if found.count > limit {
            line = String(localized: "Only the first \(limit) of \(found.count) pictures can be sent at once.")
        } else {
            let count = found.count
            line = String(AttributedString(localized: "^[\(count) picture](inflect: true) to mark up, pin, or recognize text from.").characters)
        }
        if announcing { say(line) } else { detailLabel.stringValue = line }
        for button in actionButtons { button.isEnabled = true }
        updatePreferredContentSize()
    }

    @objc private func annotate() { handOver(.annotate) }
    @objc private func pin() { handOver(.pin) }
    @objc private func recognizeText() { handOver(.recognizeText) }

    @objc private func cancel() {
        guard !isFinished else { return }
        isFinished = true
        removeKeyMonitor()
        offerTask?.cancel()
        offerTask = nil
        handOverTask?.cancel()
        handOverTask = nil
        if let activeBatch {
            activeBatch.inbox.discard(batch: activeBatch.id)
            self.activeBatch = nil
        }
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func handOver(_ action: ShareHandoff.Action) {
        guard !isFinished else { return }
        let pictures = pictures
        let totalCount = totalPictureCount
        for button in actionButtons { button.isEnabled = false }
        if totalCount > pictures.count {
            say(String(localized: "Sending the first \(pictures.count) of \(totalCount) pictures…"))
        } else {
            say(String(localized: "Sending…"))
        }
        spinner.startAnimation(nil)
        updatePreferredContentSize()
        handOverTask = Task {
            let inbox = ShareInbox.hosted(by: hostBundleIdentifier)
            do {
                let batch = try inbox.newBatch()
                activeBatch = (inbox, batch.id)
                var stored = 0
                for provider in pictures {
                    if Task.isCancelled {
                        inbox.discard(batch: batch.id)
                        activeBatch = nil
                        return
                    }
                    // One picture that cannot be read does not stop the others.
                    if (try? await batch.addPicture(from: provider)) != nil { stored += 1 }
                }
                if Task.isCancelled {
                    inbox.discard(batch: batch.id)
                    activeBatch = nil
                    return
                }
                guard stored > 0 else {
                    inbox.discard(batch: batch.id)
                    activeBatch = nil
                    throw ShareInbox.Failure.noPictures
                }
                guard await open(ShareHandoff(batch: batch.id, action: action).url(scheme: urlScheme)) else {
                    // Nobody is coming for them.
                    inbox.discard(batch: batch.id)
                    activeBatch = nil
                    throw HandOverFailure.appNotOpened
                }
                activeBatch = nil
                guard !isFinished else { return }
                isFinished = true
                removeKeyMonitor()
                extensionContext?.completeRequest(returningItems: nil)
            } catch ShareInbox.Failure.noPictures {
                guard !isFinished else { return }
                fail(String(localized: "No readable pictures were found in the shared items."))
            } catch HandOverFailure.appNotOpened {
                guard !isFinished else { return }
                fail(String(localized: "Couldn’t reach \(appName). Open \(appName) once, then try again."))
            } catch {
                guard !isFinished else { return }
                fail(String(localized: "Couldn’t reach \(appName). Open \(appName) once, then try again."))
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
        for button in actionButtons + [cancelButton] { button.isHidden = true }
        closeButton.isHidden = false
        updatePreferredContentSize()
    }

    /// Changes the line under the title, and tells VoiceOver, which does not follow text that changes by itself.
    private func say(_ text: String) {
        detailLabel.stringValue = text
        NSAccessibility.post(element: detailLabel, notification: .announcementRequested, userInfo: [.announcement: text])
        updatePreferredContentSize()
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
