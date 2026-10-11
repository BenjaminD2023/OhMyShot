import AppKit
import AVFoundation
import OMSCore

/// The recording bar: after choosing what to record, a small glass capsule under it holding what the
/// recording is kept as (a movie or a GIF), what it takes along (the Mac's sound, the microphone, clicks),
/// and Record.
///
/// Built as the All-In-One bar is: glass because it is small, an opaque window-colored backing inside so
/// the screen never shows through its symbols, a solid capsule with Reduce Transparency, chips concentric
/// with the capsule. Video and GIF are chosen as the All-In-One bar's modes are; a choice that is on takes
/// the selected fill and an accent symbol, as a tool in hand does on the in-place toolbar. A GIF has no
/// sound, so the two sound chips step back while it is chosen, keeping their state for the next movie.
final class RecordingBar: NSView {
    enum Toggle: CaseIterable {
        case systemAudio
        case microphone
        case camera
        case clicks
        case keystrokes
    }

    var onOutput: ((RecordingOutput) -> Void)?
    var onToggle: ((Toggle) -> Void)?
    /// A microphone was chosen from the microphone's menu: its unique ID, empty for the system's default,
    /// or nil for none.
    var onMicrophone: ((String?) -> Void)?
    /// A camera was chosen from the camera's menu, as a microphone is; access to it is granted by then.
    var onCamera: ((String?) -> Void)?
    /// The camera bubble's look was changed from the camera's menu.
    var onCameraStyle: ((CameraStyle) -> Void)?
    var onRecord: (() -> Void)?
    var onCancel: (() -> Void)?

    static let height: CGFloat = 42
    private static let inset: CGFloat = 6
    private static let chip: CGFloat = 30

    private let container: NSView
    private let backing = NSView()
    private let stack = NSStackView()
    private var outputs: [RecordingOutput: BarButton] = [:]
    private var toggles: [Toggle: BarButton] = [:]
    private let recordButton: BarButton
    private let cancelButton: BarButton
    private var output: RecordingOutput = .video
    private var states: [Toggle: Bool] = [:]
    private var microphoneID = ""
    private var cameraID = ""
    private var cameraStyle = CameraStyle()
    /// A window is recorded on its own: what the app shows over the screen can't be in it.
    private let recordsWindow: Bool
    private var hovered: NSButton?

    init(choices: RecordingChoices, recordsWindow: Bool = false) {
        self.recordsWindow = recordsWindow
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView()
            solid.wantsLayer = true
            container = solid
        } else {
            container = NSGlassEffectView()
        }
        recordButton = BarButton(title: String(localized: "Record"), image: NSImage(), target: nil, action: nil)
        cancelButton = BarButton(title: String(localized: "Cancel"), image: NSImage(), target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.borderWidth = 0.5
        layer?.shadowColor = .black
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        addSubview(container)

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        for output in RecordingOutput.allCases {
            stack.addArrangedSubview(makeOutput(output))
        }
        addDivider()
        for toggle in Toggle.allCases {
            stack.addArrangedSubview(makeToggle(toggle))
        }
        addDivider()
        configureRecordButton()
        stack.addArrangedSubview(recordButton)
        configureCancelButton()
        stack.addArrangedSubview(cancelButton)
        stack.setCustomSpacing(4, after: recordButton)

        if let glass = container as? NSGlassEffectView {
            backing.wantsLayer = true
            backing.addSubview(stack)
            glass.contentView = backing
        } else {
            container.addSubview(stack)
        }
        update(choices)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "Recording"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var fittingSize: NSSize {
        stack.fittingSize
    }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        container.frame = bounds
        if let glass = container as? NSGlassEffectView {
            glass.cornerRadius = radius
            backing.frame = glass.bounds
            backing.layer?.cornerRadius = radius
            stack.frame = backing.bounds
        } else {
            container.layer?.cornerRadius = radius
            stack.frame = container.bounds
        }
        layer?.cornerRadius = radius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Shows the choices as they are now.
    func update(_ choices: RecordingChoices) {
        output = choices.output
        microphoneID = choices.microphoneID
        cameraID = choices.cameraID
        cameraStyle = choices.cameraStyle
        for (candidate, button) in outputs {
            let isSelected = candidate == output
            button.state = isSelected ? .on : .off
            // The symbol carries the accent; the label stays in the label color so it reads on any tint.
            button.contentTintColor = isSelected ? .controlAccentColor : .labelColor
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: Theme.Typeface.label(size: 12, weight: isSelected ? .semibold : .medium),
                .foregroundColor: NSColor.labelColor,
            ])
        }
        // A GIF has no sound: the sound chips show off and can't be pressed, and keep their state.
        // Studio draws the keys itself, so a window recorded for it can show them; it has no camera yet.
        let studio = choices.output == .studio
        let keysApply = !recordsWindow || studio
        let cameraApplies = !recordsWindow && !studio
        states = [
            .systemAudio: choices.recordsSystemAudio, .microphone: choices.recordsMicrophone, .clicks: choices.showsClicks,
            .keystrokes: choices.showsKeystrokes && keysApply && keysAllowed,
            .camera: choices.camera && cameraApplies && cameraAllowed(choices),
        ]
        for (toggle, button) in toggles {
            let on = states[toggle] ?? false
            let enabled = switch toggle {
            case .systemAudio, .microphone: choices.output.hasAudio
            case .clicks: true
            case .keystrokes: keysApply
            case .camera: cameraApplies
            }
            // Without access, the chip steps back but can still be pressed: it asks, or says where to turn it on.
            let blocked = (toggle == .keystrokes && !keysAllowed) || (toggle == .camera && !cameraAllowed(choices))
            button.isEnabled = enabled
            button.state = on ? .on : .off
            button.contentTintColor = on ? .controlAccentColor : enabled && !blocked ? .labelColor : .tertiaryLabelColor
            button.toolTip = !enabled
                ? toggle == .keystrokes ? String(localized: "A window is recorded on its own, without keys shown over it")
                : toggle == .camera && studio ? String(localized: "Studio recordings don't show the camera yet")
                : toggle == .camera ? String(localized: "A window is recorded on its own, without the camera over it")
                : String(localized: "GIFs have no sound")
                : blocked
                ? toggle == .keystrokes ? String(localized: "Input Monitoring is off. Turn on OhMyShot in System Settings › Privacy & Security › Input Monitoring.")
                : String(localized: "Camera access is off. Turn on OhMyShot in System Settings › Privacy & Security › Camera.")
                : help(for: toggle)
            button.setAccessibilityValue(on ? String(localized: "On") : String(localized: "Off"))
            button.setAccessibilityHelp(button.toolTip)
        }
        applyAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// Layer colors are fixed values, resolved for this view's appearance and again when it changes;
    /// Increase Contrast doubles the chip fills and firms up the hairline.
    private func applyAppearance() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if container is NSGlassEffectView {
                backing.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            } else {
                container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.borderWidth = contrast ? 1 : 0.5
            layer?.borderColor = contrast
                ? (dark ? CGColor(gray: 1, alpha: 0.5) : CGColor(gray: 0, alpha: 0.35))
                : NSColor.separatorColor.cgColor
            let boost: CGFloat = contrast ? 2 : 1
            let selected = dark ? CGColor(gray: 1, alpha: 0.16 * boost) : CGColor(gray: 0, alpha: 0.08 * boost)
            let hover = dark ? CGColor(gray: 1, alpha: 0.09 * boost) : CGColor(gray: 0, alpha: 0.045 * boost)
            for (candidate, button) in outputs {
                button.layer?.backgroundColor = candidate == output ? selected : button === hovered ? hover : .clear
            }
            for (toggle, button) in toggles {
                button.layer?.backgroundColor = states[toggle] == true ? selected : button === hovered && button.isEnabled ? hover : .clear
            }
            for button in [recordButton, cancelButton] {
                button.layer?.backgroundColor = button === hovered ? hover : .clear
            }
        }
    }

    private func makeOutput(_ output: RecordingOutput) -> BarButton {
        let (symbol, title, help): (String, String, String) = switch output {
        case .video:
            ("video", String(localized: "Video"), String(localized: "Keep the recording as an MP4 movie"))
        case .gif:
            ("photo.stack", String(localized: "GIF"), String(localized: "Keep the recording as an animated GIF, without sound"))
        case .studio:
            ("wand.and.sparkles", String(localized: "Studio"), String(localized: "Record for the Studio window: zooms that follow the pointer, a smooth cursor, and a background"))
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        let button = BarButton(title: title, image: image ?? NSImage(), target: self, action: #selector(outputClicked(_:)))
        configureChip(button)
        button.setButtonType(.onOff)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.toolTip = help
        button.setAccessibilityRole(.radioButton)
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(help)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
        outputs[output] = button
        return button
    }

    private func help(for toggle: Toggle) -> String {
        switch toggle {
        case .systemAudio: String(localized: "Record what the Mac plays")
        case .microphone: String(localized: "Choose a microphone to record")
        case .camera: String(localized: "Show your camera in the recording")
        case .clicks: String(localized: "Show clicks in the recording")
        case .keystrokes: String(localized: "Show the keys you press in the recording")
        }
    }

    private func makeToggle(_ toggle: Toggle) -> BarButton {
        let (symbol, title): (String, String) = switch toggle {
        case .systemAudio: ("speaker.wave.2", String(localized: "Computer Audio"))
        case .microphone: ("mic", String(localized: "Microphone"))
        case .camera: ("web.camera", String(localized: "Camera"))
        case .clicks: ("cursorarrow.click.2", String(localized: "Show Clicks"))
        case .keystrokes: ("keyboard", String(localized: "Show Keystrokes"))
        }
        let help = help(for: toggle)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        let button = BarButton(title: "", image: image ?? NSImage(), target: self, action: #selector(toggled(_:)))
        configureChip(button)
        button.setButtonType(.onOff)
        button.imagePosition = .imageOnly
        button.toolTip = help
        button.setAccessibilityRole(toggle == .microphone || toggle == .camera ? .popUpButton : .checkBox)
        button.setAccessibilityLabel(title)
        button.setAccessibilityHelp(help)
        button.widthAnchor.constraint(equalToConstant: Self.chip).isActive = true
        toggles[toggle] = button
        return button
    }

    private func configureRecordButton() {
        // The one red in the app: what records, as everywhere on the Mac.
        let dot = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium).applying(.init(paletteColors: [.white, .systemRed])))
        recordButton.image = dot
        recordButton.target = self
        recordButton.action = #selector(recordClicked)
        configureChip(recordButton)
        recordButton.imagePosition = .imageLeading
        recordButton.imageHugsTitle = true
        recordButton.attributedTitle = NSAttributedString(string: String(localized: "Record"), attributes: [
            .font: Theme.Typeface.label(size: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        recordButton.toolTip = String(localized: "Start recording (Return)")
        recordButton.setAccessibilityLabel(String(localized: "Record"))
        recordButton.setAccessibilityHelp(String(localized: "Start recording (Return)"))
        recordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
    }

    private func configureCancelButton() {
        cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Cancel"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        configureChip(cancelButton)
        cancelButton.imagePosition = .imageOnly
        cancelButton.contentTintColor = .labelColor
        cancelButton.toolTip = String(localized: "Cancel (Esc)")
        cancelButton.setAccessibilityLabel(String(localized: "Cancel"))
        cancelButton.widthAnchor.constraint(equalToConstant: Self.chip).isActive = true
    }

    private func configureChip(_ button: BarButton) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = Self.chip / 2
        button.contentTintColor = .labelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: Self.chip).isActive = true
        button.onHover = { [weak self, weak button] inside in
            guard let self, let button else { return }
            if inside {
                hovered = button
            } else if hovered === button {
                hovered = nil
            }
            applyAppearance()
        }
    }

    private func addDivider() {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(6, after: last) }
        stack.addArrangedSubview(divider)
        stack.setCustomSpacing(6, after: divider)
    }

    @objc private func outputClicked(_ sender: NSButton) {
        guard let output = outputs.first(where: { $0.value === sender })?.key else { return }
        // A radio choice: pressing the chosen one again keeps it.
        sender.state = output == self.output ? .on : .off
        onOutput?(output)
    }

    /// Whether Input Monitoring lets the keys be seen; asking for it says nothing about the screen.
    private var keysAllowed: Bool {
        CGPreflightListenEventAccess()
    }

    /// Whether the camera may be shown: checked only once the camera is chosen, since asking starts the
    /// system's capture machinery.
    private func cameraAllowed(_ choices: RecordingChoices) -> Bool {
        guard choices.camera else { return true }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .authorized || status == .notDetermined
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let toggle = toggles.first(where: { $0.value === sender })?.key else { return }
        if toggle == .keystrokes, states[.keystrokes] != true, !keysAllowed {
            // Asked here, before anything records, never once recording has begun: the system's prompt the
            // first time, after that a word on where to turn it on.
            sender.state = .off
            if PermissionCenter.hasAsked(.inputMonitoring) {
                NSSound.beep()
                NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                    .announcement: String(localized: "Input Monitoring is off. Turn on OhMyShot in System Settings, Privacy and Security, Input Monitoring."),
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
            } else {
                PermissionCenter.markAsked(.inputMonitoring)
                _ = CGRequestListenEventAccess()
            }
            return
        }
        guard toggle == .microphone || toggle == .camera else { return onToggle?(toggle) ?? () }
        // Microphones and cameras are chosen from a menu; the chip shows the choice once it is made.
        sender.state = states[toggle] == true ? .on : .off
        toggle == .microphone ? showMicrophoneMenu(from: sender) : showCameraMenu(from: sender)
    }

    /// No microphone, or one of the Mac's: the one recorded is checked, the system's default when none was
    /// chosen by name.
    private func showMicrophoneMenu(from button: NSButton) {
        let menu = NSMenu()
        let recording = states[.microphone] == true
        let none = NSMenuItem(title: String(localized: "No Microphone"), action: #selector(microphoneChosen(_:)), keyEquivalent: "")
        none.target = self
        none.state = recording ? .off : .on
        menu.addItem(none)
        menu.addItem(.separator())
        let (devices, defaultID) = Microphones.available()
        if devices.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No microphone found"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let chosen = devices.contains { $0.id == microphoneID } ? microphoneID : defaultID
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(microphoneChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id == defaultID && microphoneID.isEmpty ? "" : device.id
            item.state = recording && device.id == chosen ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, under: button)
    }

    @objc private func microphoneChosen(_ sender: NSMenuItem) {
        onMicrophone?(sender.representedObject as? String)
    }

    /// No camera, or one of the Mac's, then the bubble's shape, size, and whether it is mirrored.
    private func showCameraMenu(from button: NSButton) {
        let menu = NSMenu()
        let showing = states[.camera] == true
        let none = NSMenuItem(title: String(localized: "No Camera"), action: #selector(cameraChosen(_:)), keyEquivalent: "")
        none.target = self
        none.state = showing ? .off : .on
        menu.addItem(none)
        menu.addItem(.separator())
        let (devices, defaultID) = Cameras.available()
        if devices.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No camera found"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let chosen = devices.contains { $0.id == cameraID } ? cameraID : defaultID
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(cameraChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id == defaultID && cameraID.isEmpty ? "" : device.id
            item.state = showing && device.id == chosen ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "Shape")))
        for shape in CameraStyle.Shape.allCases {
            let title = shape == .circle ? String(localized: "Circle") : String(localized: "Rounded Square")
            let item = NSMenuItem(title: title, action: #selector(cameraShapeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shape.rawValue
            item.state = cameraStyle.shape == shape ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.sectionHeader(title: String(localized: "Size")))
        for size in CameraStyle.Size.allCases {
            let title = switch size {
            case .small: String(localized: "Small")
            case .medium: String(localized: "Medium")
            case .large: String(localized: "Large")
            }
            let item = NSMenuItem(title: title, action: #selector(cameraSizeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size.rawValue
            item.state = cameraStyle.size == size ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let mirror = NSMenuItem(title: String(localized: "Mirror"), action: #selector(cameraMirrorToggled(_:)), keyEquivalent: "")
        mirror.target = self
        mirror.state = cameraStyle.mirrored ? .on : .off
        menu.addItem(mirror)
        popUp(menu, under: button)
    }

    @objc private func cameraChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return onCamera?(nil) ?? () }
        // Shown only with access: asked for the first time, refused with a word where to turn it on.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            onCamera?(id)
        case .notDetermined:
            Task {
                guard await AVCaptureDevice.requestAccess(for: .video) else { return }
                onCamera?(id)
            }
        default:
            // Chosen all the same, so the chip steps back and says where access is turned on; no bubble shows.
            NSSound.beep()
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                .announcement: String(localized: "Camera access is off. Turn on OhMyShot in System Settings, Privacy and Security, Camera."),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
            onCamera?(id)
        }
    }

    @objc private func cameraShapeChosen(_ sender: NSMenuItem) {
        guard let shape = (sender.representedObject as? String).flatMap(CameraStyle.Shape.init(rawValue:)) else { return }
        cameraStyle.shape = shape
        onCameraStyle?(cameraStyle)
    }

    @objc private func cameraSizeChosen(_ sender: NSMenuItem) {
        guard let size = (sender.representedObject as? String).flatMap(CameraStyle.Size.init(rawValue:)) else { return }
        cameraStyle.size = size
        onCameraStyle?(cameraStyle)
    }

    @objc private func cameraMirrorToggled(_ sender: NSMenuItem) {
        cameraStyle.mirrored.toggle()
        onCameraStyle?(cameraStyle)
    }

    /// Menus float at the pop-up menu level, under the overlay's panel, which steps just below them while the
    /// menu is open.
    private func popUp(_ menu: NSMenu, under button: NSButton) {
        let window = button.window
        let level = window?.level
        if let window, window.level >= .popUpMenu {
            window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 6 : -6), in: button)
        if let window, let level { window.level = level }
    }

    @objc private func recordClicked() {
        onRecord?()
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}

#if DEBUG
/// The recording bar alone, for rendering checks.
public enum RecordingBarDemo {
    /// A window behind the desktop picture holding the bar with `choices`, with room for its shadow.
    public static func hiddenWindow(choices: RecordingChoices, recordsWindow: Bool = false, dark: Bool) -> NSWindow {
        let bar = RecordingBar(choices: choices, recordsWindow: recordsWindow)
        let size = bar.fittingSize
        let room: CGFloat = 24
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: size.width + room * 2, height: size.height + room * 2),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        if let screen = NSScreen.screens.first {
            window.setFrameOrigin(CGPoint(x: screen.frame.midX - window.frame.width / 2, y: screen.frame.midY - window.frame.height / 2))
        }
        let content = NSView(frame: CGRect(origin: .zero, size: window.frame.size))
        bar.frame = CGRect(x: room, y: room, width: size.width, height: size.height)
        content.addSubview(bar)
        window.contentView = content
        window.orderFront(nil)
        return window
    }
}
#endif
