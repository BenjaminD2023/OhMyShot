import AppKit
import OMSCore
import OMSDesign

/// One app, one preview, one capture action. Other windows stay inside their app's switcher instead of
/// becoming a flat inventory. The panel takes key focus without activating us or moving the target.
final class WindowPickerController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    var onChoose: ((WindowTarget, RecordingChoices?) -> Void)?
    var onCancel: (() -> Void)?
    var onBack: (() -> Void)?
    var onRecordingChange: ((WindowTarget, RecordingChoices) -> Void)?

    private let layout: DisplayLayout
    private let preferredProcessID: pid_t?
    private let load: () async throws -> [WindowCatalog.Choice]
    private let preview: (WindowTarget) async throws -> CGImage
    private let root = WindowPickerContent()
    private let apps = NSStackView()
    private let appScroll = NSScrollView()
    private let search = NSSearchField()
    private let searchButton = NSButton()
    private let picture = NSImageView()
    private let previewSurface = WindowPreviewSurface()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retry = NSButton(title: String(localized: "Try Again", bundle: .module), target: nil, action: nil)
    private let windowTitle = NSTextField(labelWithString: "")
    private let windowSwitch = NSPopUpButton()
    private let capture = NSButton(title: String(localized: "Capture", bundle: .module), target: nil, action: nil)
    private let back: NSButton
    private let recordingBar: RecordingBar?
    private var barWidth: NSLayoutConstraint?
    private var choices: RecordingChoices?
    private(set) var model = WindowPickerModel()
    private var loading: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var generation = 0
    private var previewGeneration = 0
    private var isLoading = false
    private var previewReady = false
    private var listFailed = false
    private var hasClosed = false
    private var appButtons: [pid_t: WindowAppButton] = [:]
    private var menuLevel: NSWindow.Level?

    init(
        layout: DisplayLayout, recording: RecordingChoices?, preferredProcessID: pid_t? = nil, offersBack: Bool = false,
        load: @escaping () async throws -> [WindowCatalog.Choice], preview: @escaping (WindowTarget) async throws -> CGImage
    ) {
        self.layout = layout
        self.preferredProcessID = preferredProcessID
        self.load = load
        self.preview = preview
        choices = recording
        recordingBar = recording.map { RecordingBar(choices: $0, recordsWindow: true, compact: true) }
        back = NSButton(title: offersBack ? String(localized: "Back", bundle: .module) : String(localized: "Cancel", bundle: .module), target: nil, action: nil)
        let panel = WindowPickerPanel(
            contentRect: CGRect(x: 0, y: 0, width: 620, height: 452),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.title = recording == nil ? String(localized: "Capture Window", bundle: .module) : String(localized: "Record Window", bundle: .module)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.level = OverlayPanel.annotationLevel
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = root
        super.init(window: panel)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.goBack() }
        panel.onSearch = { [weak self] in self?.showSearch() }
        panel.onRefresh = { [weak self] in self?.reload() }
        root.onConfirm = { [weak self] in self?.choose() }
        root.onMove = { [weak self] step in self?.moveApplication(by: step) }
        buildContent(offersBack: offersBack)
        configureRecordingBar()
        showStatus(String(localized: "Loading windows…", bundle: .module), busy: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(on display: DisplayInfo) {
        guard let window else { return }
        window.setFrameOrigin(CGPoint(x: display.frame.midX - window.frame.width / 2, y: display.frame.midY - window.frame.height / 2))
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(root)
        reload()
    }

    override func close() {
        hasClosed = true
        generation += 1
        previewGeneration += 1
        loading?.cancel()
        previewTask?.cancel()
        loading = nil
        previewTask = nil
        picture.image = nil
        super.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { onCancel?(); return false }

    private func buildContent(offersBack: Bool) {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        search.placeholderString = String(localized: "Find an app or window", bundle: .module)
        search.setAccessibilityLabel(search.placeholderString)
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.isHidden = true
        search.heightAnchor.constraint(equalToConstant: 24).isActive = true

        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        picture.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        picture.translatesAutoresizingMaskIntoConstraints = false
        picture.setAccessibilityLabel(String(localized: "Window preview", bundle: .module))
        previewSurface.addSubview(picture)
        NSLayoutConstraint.activate([
            picture.leadingAnchor.constraint(equalTo: previewSurface.leadingAnchor, constant: 8),
            picture.trailingAnchor.constraint(equalTo: previewSurface.trailingAnchor, constant: -8),
            picture.topAnchor.constraint(equalTo: previewSurface.topAnchor, constant: 8),
            picture.bottomAnchor.constraint(equalTo: previewSurface.bottomAnchor, constant: -8),
            previewSurface.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        let previewHeight = previewSurface.heightAnchor.constraint(equalToConstant: 246)
        previewHeight.priority = .defaultHigh
        previewHeight.isActive = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.alignment = .center
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 13)
        status.maximumNumberOfLines = 3
        retry.bezelStyle = .rounded
        retry.target = self
        retry.action = #selector(retryClicked(_:))
        let placeholder = NSStackView(views: [spinner, status, retry])
        placeholder.orientation = .vertical
        placeholder.spacing = 10
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        previewSurface.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: previewSurface.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: previewSurface.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: previewSurface.widthAnchor, constant: -72),
        ])

        let caption = NSView()
        windowTitle.lineBreakMode = .byTruncatingTail
        windowTitle.font = .systemFont(ofSize: 12)
        windowTitle.textColor = .secondaryLabelColor
        windowSwitch.target = self
        windowSwitch.action = #selector(windowChosen(_:))
        windowSwitch.setAccessibilityLabel(String(localized: "Window", bundle: .module))
        windowSwitch.menu?.delegate = self
        searchButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: String(localized: "Find an app or window", bundle: .module))
        searchButton.isBordered = false
        searchButton.target = self
        searchButton.action = #selector(searchClicked(_:))
        searchButton.toolTip = String(localized: "Find an app or window", bundle: .module)
        for view in [windowTitle, windowSwitch, searchButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            caption.addSubview(view)
            view.centerYAnchor.constraint(equalTo: caption.centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            caption.heightAnchor.constraint(equalToConstant: 26),
            searchButton.trailingAnchor.constraint(equalTo: caption.trailingAnchor),
            searchButton.widthAnchor.constraint(equalToConstant: 28),
            searchButton.heightAnchor.constraint(equalToConstant: 26),
            windowTitle.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            windowTitle.trailingAnchor.constraint(equalTo: searchButton.leadingAnchor, constant: -12),
            windowSwitch.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            windowSwitch.trailingAnchor.constraint(equalTo: searchButton.leadingAnchor, constant: -12),
        ])

        apps.orientation = .horizontal
        apps.spacing = 6
        apps.alignment = .centerY
        appScroll.documentView = apps
        appScroll.drawsBackground = false
        appScroll.hasHorizontalScroller = true
        appScroll.autohidesScrollers = true
        appScroll.scrollerStyle = .overlay
        appScroll.heightAnchor.constraint(equalToConstant: 76).isActive = true
        appScroll.setAccessibilityLabel(String(localized: "Applications", bundle: .module))

        let footer = NSView()
        back.target = self
        back.action = #selector(backClicked(_:))
        back.bezelStyle = .rounded
        back.isHidden = recordingBar != nil && !offersBack
        capture.target = self
        capture.action = #selector(captureClicked(_:))
        capture.bezelStyle = .rounded
        capture.keyEquivalent = "\r"
        capture.isHidden = recordingBar != nil
        for view in [back, recordingBar ?? capture] {
            view.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(view)
            view.centerYAnchor.constraint(equalTo: footer.centerYAnchor).isActive = true
        }
        back.leadingAnchor.constraint(equalTo: footer.leadingAnchor).isActive = true
        let action: NSView = recordingBar ?? capture
        action.trailingAnchor.constraint(equalTo: footer.trailingAnchor).isActive = true
        if let recordingBar {
            barWidth = recordingBar.widthAnchor.constraint(equalToConstant: recordingBar.fittingSize.width)
            barWidth?.isActive = true
            recordingBar.heightAnchor.constraint(equalToConstant: RecordingBar.height).isActive = true
        } else {
            capture.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        }
        footer.heightAnchor.constraint(equalToConstant: 42).isActive = true
        for view in [search, previewSurface, caption, appScroll, footer] {
            content.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        updateActions()
    }

    private func configureRecordingBar() {
        guard let bar = recordingBar else { return }
        bar.onOutput = { [weak self] output in self?.change { $0.output = output } }
        bar.onMicrophone = { [weak self] id in
            self?.change { $0.microphone = id != nil; if let id { $0.microphoneID = id } }
        }
        bar.onToggle = { [weak self] toggle in
            self?.change {
                switch toggle {
                case .systemAudio: $0.systemAudio.toggle()
                case .microphone: $0.microphone.toggle()
                case .clicks: $0.showsClicks.toggle()
                case .keystrokes: $0.showsKeystrokes.toggle()
                case .camera: break
                }
            }
        }
        bar.onRecord = { [weak self] in self?.choose() }
        bar.onCancel = { [weak self] in self?.onCancel?() }
    }

    private func change(_ update: (inout RecordingChoices) -> Void) {
        guard var choices else { return }
        update(&choices)
        self.choices = choices
        recordingBar?.update(choices)
        barWidth?.constant = recordingBar?.fittingSize.width ?? 0
        if let selected = model.selected { onRecordingChange?(selected.target, choices) }
    }

    @discardableResult
    func reload() -> Task<Void, Never> {
        loading?.cancel()
        previewTask?.cancel()
        generation += 1
        let generation = generation
        isLoading = true
        listFailed = false
        previewReady = false
        picture.image = nil
        showStatus(String(localized: "Loading windows…", bundle: .module), busy: true)
        updateActions()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await load()
                guard !hasClosed, !Task.isCancelled, generation == self.generation else { return }
                model.replace(fetched, preferredProcessID: preferredProcessID)
            } catch {
                guard !hasClosed, !Task.isCancelled, generation == self.generation else { return }
                model.replace([], preferredProcessID: nil)
                listFailed = true
            }
            isLoading = false
            rebuildApps()
            await selectCurrent().value
        }
        loading = task
        return task
    }

    private func rebuildApps() {
        for view in apps.arrangedSubviews { apps.removeArrangedSubview(view); view.removeFromSuperview() }
        appButtons = [:]
        for application in model.applications {
            let button = WindowAppButton(name: application.name, processID: application.processID)
            button.target = self
            button.action = #selector(appChosen(_:))
            button.tag = Int(application.processID)
            apps.addArrangedSubview(button)
            appButtons[application.processID] = button
        }
        apps.frame = CGRect(origin: .zero, size: CGSize(width: max(appScroll.contentSize.width, apps.fittingSize.width), height: 72))
    }

    @discardableResult
    private func selectCurrent() -> Task<Void, Never> {
        previewTask?.cancel()
        previewGeneration += 1
        let revision = previewGeneration
        previewReady = false
        picture.image = nil
        for (pid, button) in appButtons { button.selected = pid == model.selectedProcessID }
        windowSwitch.removeAllItems()
        for item in model.application?.windows ?? [] {
            let menuItem = NSMenuItem(title: title(of: item.target), action: nil, keyEquivalent: "")
            menuItem.representedObject = item.target.id
            windowSwitch.menu?.addItem(menuItem)
        }
        if let index = model.application?.windows.firstIndex(where: { $0.target.id == model.selectedWindowID }) { windowSwitch.selectItem(at: index) }
        windowSwitch.isHidden = (model.application?.windows.count ?? 0) <= 1
        windowTitle.isHidden = !windowSwitch.isHidden
        windowTitle.stringValue = model.selected.map { title(of: $0.target) } ?? ""
        windowTitle.toolTip = model.selected.map { "\($0.target.ownerName) — \(title(of: $0.target))\n\($0.target.display(in: layout)?.name ?? "")" }
        updateActions()
        guard let selected = model.selected, !isLoading else {
            let message = listFailed ? String(localized: "Could not load windows. Try again.", bundle: .module)
                : model.query.isEmpty ? String(localized: "Open an app to capture its window.", bundle: .module)
                : String(localized: "No matching apps or windows.", bundle: .module)
            showStatus(message, busy: isLoading, canRetry: model.query.isEmpty)
            return Task {}
        }
        if let choices { onRecordingChange?(selected.target, choices) }
        showStatus(String(localized: "Loading preview…", bundle: .module), busy: true)
        appButtons[selected.processID]?.scrollToVisible(appButtons[selected.processID]?.bounds ?? .zero)
        let target = selected.target
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await preview(target)
                guard !hasClosed, !Task.isCancelled, revision == previewGeneration, model.selectedWindowID == target.id else { return }
                picture.image = NSImage(cgImage: image, size: .zero)
                picture.setAccessibilityValue(title(of: target))
                previewReady = true
                showStatus(nil)
            } catch {
                guard !hasClosed, !Task.isCancelled, revision == previewGeneration else { return }
                showStatus(String(localized: "This window is not available. Try another window or refresh.", bundle: .module), canRetry: true)
            }
            updateActions()
        }
        previewTask = task
        return task
    }

    private func title(of target: WindowTarget) -> String {
        let title = target.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? target.ownerName : title
    }

    private func updateActions() {
        let enabled = !isLoading && previewReady && model.selected != nil
        capture.isEnabled = enabled
        recordingBar?.canRecord = enabled
        windowSwitch.isEnabled = !isLoading
        for button in appButtons.values { button.isEnabled = !isLoading }
    }

    private func showStatus(_ message: String?, busy: Bool = false, canRetry: Bool = false) {
        status.stringValue = message ?? ""
        status.isHidden = message == nil
        retry.isHidden = !canRetry
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    private func choose() {
        guard !isLoading, previewReady, let selected = model.selected else { return }
        onChoose?(selected.target, choices)
    }

    private func goBack() {
        if !search.isHidden {
            search.stringValue = ""
            search.isHidden = true
            model.filter("")
            rebuildApps()
            selectCurrent()
            window?.makeFirstResponder(root)
        } else if let onBack { onBack() } else { onCancel?() }
    }

    private func showSearch() {
        search.isHidden = false
        root.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(search)
    }

    private func moveApplication(by step: Int) {
        guard !isLoading else { return }
        model.moveApplication(by: step)
        selectCurrent()
    }

    @objc private func appChosen(_ sender: NSButton) {
        guard !isLoading else { return }
        model.selectApplication(pid_t(sender.tag))
        selectCurrent()
        window?.makeFirstResponder(root)
    }
    @objc private func windowChosen(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? UInt32 else { return }
        model.selectWindow(id)
        selectCurrent()
    }
    @objc private func retryClicked(_ sender: Any?) { reload() }
    @objc private func searchClicked(_ sender: Any?) { showSearch() }
    @objc private func captureClicked(_ sender: Any?) { choose() }
    @objc private func backClicked(_ sender: Any?) { goBack() }

    func controlTextDidChange(_ obj: Notification) {
        model.filter(search.stringValue)
        rebuildApps()
        selectCurrent()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveDown(_:)) { window?.makeFirstResponder(root); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { choose(); return true }
        if selector == #selector(NSResponder.cancelOperation(_:)) { goBack(); return true }
        return false
    }
    func menuWillOpen(_ menu: NSMenu) {
        menuLevel = window?.level
        window?.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
    }
    func menuDidClose(_ menu: NSMenu) {
        if let menuLevel { window?.level = menuLevel }
        menuLevel = nil
    }
}

private final class WindowPickerPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onSearch: (() -> Void)?
    var onRefresh: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            if event.charactersIgnoringModifiers == "f" { onSearch?(); return true }
            if event.charactersIgnoringModifiers == "r" { onRefresh?(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class WindowPickerContent: NSView {
    var onConfirm: (() -> Void)?
    var onMove: ((Int) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onConfirm?()
        case 123: onMove?(-1)
        case 124: onMove?(1)
        case 53: window?.cancelOperation(nil)
        default: super.keyDown(with: event)
        }
    }
}

private final class WindowPreviewSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}

private final class WindowAppButton: NSButton {
    var selected = false { didSet { state = selected ? .on : .off; needsDisplay = true } }
    init(name: String, processID: pid_t) {
        super.init(frame: .zero)
        title = name
        let icon = (NSRunningApplication(processIdentifier: processID)?.icon?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 28, weight: .regular))
        icon?.size = NSSize(width: 32, height: 32)
        image = icon
        imagePosition = .imageAbove
        imageScaling = .scaleProportionallyDown
        font = .systemFont(ofSize: 11)
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        isBordered = false
        setButtonType(.onOff)
        toolTip = name
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(name)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 76).isActive = true
        heightAnchor.constraint(equalToConstant: 66).isActive = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.24 : 0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()
        }
        super.draw(dirtyRect)
    }
}
