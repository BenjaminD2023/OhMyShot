import AppKit
import AVFoundation
import CoreMedia
import OMSCore
import OMSDesign
import QuartzCore

/// Ephemeral microphone input-level monitor used while the recording setup bar is visible and a
/// microphone is enabled with granted permission. Zero activity when stopped or ungranted.
protocol MicrophoneLevelMonitoring: AnyObject {
    func start(deviceID: String, onLevel: @escaping (CGFloat) -> Void)
    func stop()
}

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
    /// The camera's menu moved the bubble to a corner, or filled what is recorded with the camera, or went back.
    var onCameraCommand: ((CameraBubbleCommand) -> Void)?
    /// Whether the camera fills what is recorded, for Fill the Recording's checkmark.
    var cameraFills: () -> Bool = { false }
    var onRecord: (() -> Void)?
    var onCancel: (() -> Void)?
    /// The all-windows selector requires an explicit selection before Record can run.
    var canRecord = true {
        didSet { recordButton.isEnabled = canRecord }
    }

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
    private(set) var recordsWindow: Bool
    private let compact: Bool
    private var optionsButton: BarButton?
    private var hovered: NSButton?
    /// The name of the microphone or camera a chip that is on records, by its ID (empty for the system's default).
    private let deviceName: (Toggle, String) -> String?
    /// The names looked up so far, so each device is looked up once.
    private var deviceNames: [String: String] = [:]
    /// Subtle live input-level indicator tucked along the bottom of the Microphone chip while armed.
    private let micMeterTrack = CALayer()
    private let micMeterFill = CALayer()
    private var levelMonitor: (any MicrophoneLevelMonitoring)?
    private var monitoredMicrophoneID: String?
    private var levelMonitoringStopped = false
    /// Current normalized microphone input level (0...1) shown in the setup bar, for tests.
    private(set) var microphoneInputLevel: CGFloat = 0
    /// Whether the live microphone input-level monitor is currently running, for tests.
    var isMonitoringMicrophoneLevel: Bool { levelMonitor != nil }
    /// Injectable hooks for deterministic unit testing of microphone permission & live monitoring.
    var microphoneAuthorizationStatus: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    var requestMicrophoneAccess: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    var makeLevelMonitor: () -> any MicrophoneLevelMonitoring = { LiveMicrophoneLevelMonitor() }

    /// `deviceName` names the microphone or camera a chip records; by default the device itself is asked, once access
    /// to it is granted (asking starts the system's capture machinery, and only for that one device).
    init(choices: RecordingChoices, recordsWindow: Bool = false, compact: Bool = false, deviceName: @escaping (Toggle, String) -> String? = RecordingBar.lookUpDevice) {
        self.recordsWindow = recordsWindow
        self.compact = compact
        self.deviceName = deviceName
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let solid = NSView()
            solid.wantsLayer = true
            container = solid
        } else {
            container = NSGlassEffectView()
        }
        recordButton = BarButton(title: String(localized: "Record", bundle: .module), image: NSImage(), target: nil, action: nil)
        cancelButton = BarButton(title: String(localized: "Cancel", bundle: .module), image: NSImage(), target: nil, action: nil)
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
        // Built with room, so no chip's size breaks before the bar is first placed (`rearrange`).
        stack.makeRoom()
        if !compact {
            for output in RecordingOutput.allCases { stack.addArrangedSubview(makeOutput(output)) }
            addDivider()
        }
        for toggle in Toggle.allCases {
            let button = makeToggle(toggle)
            if !compact || toggle == .systemAudio || toggle == .microphone { stack.addArrangedSubview(button) }
        }
        if compact {
            let button = BarButton(title: String(localized: "Options", bundle: .module), image: NSImage(), target: self, action: #selector(showOptions(_:)))
            configureChip(button)
            button.horizontalPadding = 10
            button.imagePosition = .noImage
            button.font = Theme.Typeface.label(size: 12)
            button.toolTip = String(localized: "Recording options", bundle: .module)
            button.setAccessibilityRole(.popUpButton)
            optionsButton = button
            stack.addArrangedSubview(button)
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
        setAccessibilityLabel(String(localized: "Recording", bundle: .module))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        tearDownMicrophoneMonitor()
    }

    override var fittingSize: NSSize {
        stack.fittingSize
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            tearDownMicrophoneMonitor()
        } else {
            syncMicrophoneMonitoring()
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        tearDownMicrophoneMonitor()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        syncMicrophoneMonitoring()
    }

    /// Stops any active microphone level monitor immediately (called before recording begins or when the bar closes).
    func stopLevelMonitoring() {
        levelMonitoringStopped = true
        tearDownMicrophoneMonitor()
    }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        container.frame = bounds
        if let glass = container as? NSGlassEffectView {
            glass.cornerRadius = radius
            backing.frame = glass.bounds
            backing.layer?.cornerRadius = radius
            stack.place(in: backing.bounds)
        } else {
            container.layer?.cornerRadius = radius
            stack.place(in: container.bounds)
        }
        layer?.cornerRadius = radius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Shows the choices as they are now, updating whether a standalone window is targeted when given.
    func update(_ choices: RecordingChoices, recordsWindow: Bool? = nil) {
        if let recordsWindow { self.recordsWindow = recordsWindow }
        output = choices.output
        microphoneID = choices.microphoneID
        cameraID = choices.cameraID
        cameraStyle = choices.cameraStyle
        optionsButton?.title = switch choices.output {
        case .video: String(localized: "Options", bundle: .module)
        case .gif: String(localized: "GIF", bundle: .module)
        case .studio: String(localized: "Studio", bundle: .module)
        }
        optionsButton?.setAccessibilityLabel(String(localized: "Recording options", bundle: .module))
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
        // Studio draws the keys and composites the camera itself, so a window recorded for it can show both.
        let studio = choices.output == .studio
        let keysApply = !self.recordsWindow || studio
        let cameraApplies = !self.recordsWindow || studio
        states = [
            .systemAudio: choices.recordsSystemAudio, .clicks: choices.showsClicks,
            .keystrokes: choices.showsKeystrokes && keysApply && keysAllowed,
            .camera: choices.camera && cameraApplies && cameraAllowed(choices),
            .microphone: choices.recordsMicrophone && microphoneAllowed(choices),
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
                || (toggle == .microphone && !microphoneAllowed(choices))
            button.isEnabled = enabled
            button.state = on ? .on : .off
            button.contentTintColor = on ? .controlAccentColor : enabled && !blocked ? .labelColor : .tertiaryLabelColor
            // A microphone or camera on is named, in the tooltip and to VoiceOver, as a pop-up button names its choice.
            let device = on && (toggle == .microphone || toggle == .camera) ? name(of: toggle, id: toggle == .microphone ? microphoneID : cameraID) : nil
            button.toolTip = !enabled
                ? toggle == .keystrokes ? String(localized: "A window is recorded on its own, without keys shown over it", bundle: .module)
                : toggle == .camera ? String(localized: "A window is recorded on its own, without the camera over it", bundle: .module)
                : String(localized: "GIFs have no sound", bundle: .module)
                : blocked
                ? toggle == .keystrokes ? String(localized: "Input Monitoring is off. Turn on OhMyShot in System Settings › Privacy & Security › Input Monitoring.", bundle: .module)
                : toggle == .microphone ? String(localized: "Microphone access is off, so the recording would have no microphone sound. Turn on OhMyShot in System Settings › Privacy & Security › Microphone.", bundle: .module)
                : String(localized: "Camera access is off. Turn on OhMyShot in System Settings › Privacy & Security › Camera.", bundle: .module)
                : device.map { toggle == .microphone ? String(localized: "Microphone: \($0)", bundle: .module) : String(localized: "Camera: \($0)", bundle: .module) }
                ?? help(for: toggle, studio: studio)
            let value = switch toggle {
            case .microphone: on ? device ?? String(localized: "On", bundle: .module) : String(localized: "No Microphone", bundle: .module)
            case .camera: on ? device ?? String(localized: "On", bundle: .module) : String(localized: "No Camera", bundle: .module)
            default: on ? String(localized: "On", bundle: .module) : String(localized: "Off", bundle: .module)
            }
            button.setAccessibilityValue(value)
            button.setAccessibilityHelp(button.toolTip)
        }
        applyAppearance()
        syncMicrophoneMonitoring()
    }

    /// The device a chip records, looked up the first time it is asked for.
    private func name(of toggle: Toggle, id: String) -> String? {
        let key = "\(toggle)-\(id)"
        if let known = deviceNames[key] { return known }
        let found = deviceName(toggle, id)
        deviceNames[key] = found
        return found
    }

    /// The microphone or camera itself, named once access to it is granted: before that, asking would be for nothing.
    nonisolated static func lookUpDevice(_ toggle: Toggle, id: String) -> String? {
        switch toggle {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? Microphones.name(of: id) : nil
        case .camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized ? Cameras.name(of: id) : nil
        default: nil
        }
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
            let dark = effectiveAppearance.isDark
            layer?.borderWidth = contrast ? 1 : 0.5
            layer?.borderColor = contrast
                ? (dark ? CGColor(gray: 1, alpha: 0.5) : CGColor(gray: 0, alpha: 0.35))
                : NSColor.separatorColor.cgColor
            let (selected, hover) = CapsuleBar.chipFills(dark: dark, increasedContrast: contrast)
            for (candidate, button) in outputs {
                button.layer?.backgroundColor = candidate == output ? selected : button === hovered ? hover : .clear
            }
            for (toggle, button) in toggles {
                button.layer?.backgroundColor = states[toggle] == true ? selected : button === hovered && button.isEnabled ? hover : .clear
            }
            for button in [recordButton, cancelButton] + [optionsButton].compactMap({ $0 }) {
                button.layer?.backgroundColor = button === hovered ? hover : .clear
            }
            micMeterTrack.backgroundColor = NSColor.labelColor.withAlphaComponent(contrast ? 0.3 : 0.16).cgColor
            micMeterFill.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }

    private func makeOutput(_ output: RecordingOutput) -> BarButton {
        let (symbol, title, help): (String, String, String) = switch output {
        case .video:
            ("video", String(localized: "Video", bundle: .module), String(localized: "Keep the recording as an MP4 movie", bundle: .module))
        case .gif:
            ("photo.stack", String(localized: "GIF", bundle: .module), String(localized: "Keep the recording as an animated GIF, without sound", bundle: .module))
        case .studio:
            ("wand.and.sparkles", String(localized: "Studio", bundle: .module), String(localized: "Record for the Studio window: zooms that follow the pointer, a smooth cursor, and a background", bundle: .module))
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

    private func help(for toggle: Toggle, studio: Bool = false) -> String {
        switch toggle {
        case .systemAudio: String(localized: "Record what the Mac plays", bundle: .module)
        case .microphone: String(localized: "Choose a microphone to record", bundle: .module)
        case .camera: String(localized: "Show your camera in the recording", bundle: .module)
        case .clicks:
            studio
                ? String(localized: "Record clicks for Studio — you can toggle or adjust them after recording", bundle: .module)
                : String(localized: "Show clicks in the recording", bundle: .module)
        case .keystrokes:
            studio
                ? String(localized: "Record keystrokes for Studio — you can toggle or adjust them after recording", bundle: .module)
                : String(localized: "Show the keys you press in the recording", bundle: .module)
        }
    }

    private func makeToggle(_ toggle: Toggle) -> BarButton {
        let (symbol, title): (String, String) = switch toggle {
        case .systemAudio: ("speaker.wave.2", String(localized: "Computer Audio", bundle: .module))
        case .microphone: ("mic", String(localized: "Microphone", bundle: .module))
        case .camera: ("web.camera", String(localized: "Camera", bundle: .module))
        case .clicks: ("cursorarrow.click.2", String(localized: "Show Clicks", bundle: .module))
        case .keystrokes: ("keyboard", String(localized: "Show Keystrokes", bundle: .module))
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
        if toggle == .microphone {
            configureMicrophoneMeter(on: button)
        }
        toggles[toggle] = button
        return button
    }

    private static let micMeterWidth: CGFloat = 14
    private static let micMeterHeight: CGFloat = 2.5

    private func configureMicrophoneMeter(on button: BarButton) {
        let noAnim: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
        micMeterTrack.frame = CGRect(
            x: (Self.chip - Self.micMeterWidth) / 2,
            y: 3,
            width: Self.micMeterWidth,
            height: Self.micMeterHeight
        )
        micMeterTrack.cornerRadius = Self.micMeterHeight / 2
        micMeterTrack.masksToBounds = true
        micMeterTrack.actions = noAnim
        micMeterTrack.isHidden = true

        micMeterFill.frame = CGRect(x: 0, y: 0, width: 0, height: Self.micMeterHeight)
        micMeterFill.cornerRadius = Self.micMeterHeight / 2
        micMeterFill.actions = noAnim
        micMeterTrack.addSublayer(micMeterFill)
        button.layer?.addSublayer(micMeterTrack)
    }

    private func syncMicrophoneMonitoring() {
        let shouldMonitor = !levelMonitoringStopped
            && window != nil
            && !isHiddenOrHasHiddenAncestor
            && states[.microphone] == true
            && microphoneAuthorizationStatus() == .authorized
        guard shouldMonitor else {
            tearDownMicrophoneMonitor()
            return
        }
        if levelMonitor != nil, monitoredMicrophoneID == microphoneID {
            return
        }
        tearDownMicrophoneMonitor()
        let monitor = makeLevelMonitor()
        levelMonitor = monitor
        monitoredMicrophoneID = microphoneID
        setMicrophoneInputLevel(0, visible: true)
        monitor.start(deviceID: microphoneID) { [weak self] level in
            guard let self, self.levelMonitor != nil else { return }
            self.setMicrophoneInputLevel(level, visible: true)
        }
    }

    private func tearDownMicrophoneMonitor() {
        levelMonitor?.stop()
        levelMonitor = nil
        monitoredMicrophoneID = nil
        setMicrophoneInputLevel(0, visible: false)
    }

    private func setMicrophoneInputLevel(_ level: CGFloat, visible: Bool) {
        let clamped = min(max(level, 0), 1)
        microphoneInputLevel = clamped
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        micMeterTrack.isHidden = !visible
        let fillWidth: CGFloat = clamped > 0.02
            ? max(Self.micMeterHeight, (Self.micMeterWidth * clamped).rounded(.toNearestOrAwayFromZero))
            : 0
        micMeterFill.frame = CGRect(x: 0, y: 0, width: fillWidth, height: Self.micMeterHeight)
        CATransaction.commit()
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
        recordButton.attributedTitle = NSAttributedString(string: String(localized: "Record", bundle: .module), attributes: [
            .font: Theme.Typeface.label(size: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        recordButton.toolTip = String(localized: "Start recording (Return)", bundle: .module)
        recordButton.setAccessibilityLabel(String(localized: "Record", bundle: .module))
        recordButton.setAccessibilityHelp(String(localized: "Start recording (Return)", bundle: .module))
        recordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
    }

    private func configureCancelButton() {
        cancelButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Cancel", bundle: .module))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        configureChip(cancelButton)
        cancelButton.imagePosition = .imageOnly
        cancelButton.contentTintColor = .labelColor
        cancelButton.toolTip = String(localized: "Cancel (Esc)", bundle: .module)
        cancelButton.setAccessibilityLabel(String(localized: "Cancel", bundle: .module))
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

    @objc private func showOptions(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: String(localized: "Format", bundle: .module)))
        for (index, output) in RecordingOutput.allCases.enumerated() {
            let title = switch output {
            case .video: String(localized: "Video", bundle: .module)
            case .gif: String(localized: "GIF", bundle: .module)
            case .studio: String(localized: "Studio", bundle: .module)
            }
            let item = NSMenuItem(title: title, action: #selector(optionFormat(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = output == self.output ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for toggle in [Toggle.clicks, .keystrokes] {
            guard let button = toggles[toggle], button.isEnabled else { continue }
            let item = NSMenuItem(title: button.accessibilityLabel() ?? "", action: #selector(optionToggle(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Toggle.allCases.firstIndex(of: toggle) ?? 0
            item.state = button.state
            menu.addItem(item)
        }
        menu.popUp(under: sender)
    }

    @objc private func optionFormat(_ item: NSMenuItem) {
        guard RecordingOutput.allCases.indices.contains(item.tag) else { return }
        onOutput?(RecordingOutput.allCases[item.tag])
    }

    @objc private func optionToggle(_ item: NSMenuItem) {
        guard Toggle.allCases.indices.contains(item.tag), let button = toggles[Toggle.allCases[item.tag]] else { return }
        toggled(button)
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

    /// Whether the microphone chosen can be recorded: access not refused. Asked immediately when a microphone
    /// is chosen on the setup bar, or when recording starts (`RecordingCoordinator`).
    private func microphoneAllowed(_ choices: RecordingChoices) -> Bool {
        guard choices.recordsMicrophone else { return true }
        let status = microphoneAuthorizationStatus()
        return status == .authorized || status == .notDetermined
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
                VoiceOver.announce(String(localized: "Input Monitoring is off. Turn on OhMyShot in System Settings, Privacy and Security, Input Monitoring.", bundle: .module), from: self)
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
        let none = NSMenuItem(title: String(localized: "No Microphone", bundle: .module), action: #selector(microphoneChosen(_:)), keyEquivalent: "")
        none.target = self
        none.state = recording ? .off : .on
        menu.addItem(none)
        menu.addItem(.separator())
        let (devices, defaultID) = Microphones.available()
        if devices.isEmpty {
            if microphoneAuthorizationStatus() == .notDetermined {
                let fallback = NSMenuItem(title: String(localized: "Default Microphone", bundle: .module), action: #selector(microphoneChosen(_:)), keyEquivalent: "")
                fallback.target = self
                fallback.representedObject = ""
                fallback.state = recording ? .on : .off
                menu.addItem(fallback)
            } else {
                let empty = NSMenuItem(title: String(localized: "No microphone found", bundle: .module), action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
        }
        let chosen = devices.contains { $0.id == microphoneID } ? microphoneID : defaultID
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(microphoneChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id == defaultID && microphoneID.isEmpty ? "" : device.id
            item.state = recording && device.id == chosen ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(under: button)
    }

    @objc private func microphoneChosen(_ sender: NSMenuItem) {
        chooseMicrophone(sender.representedObject as? String)
    }

    /// Selects microphone `id` (empty for system default, nil for none). When microphone access has not
    /// been determined yet, requests it immediately before enabling so the live input-level indicator can start.
    func chooseMicrophone(_ id: String?) {
        guard let id else {
            onMicrophone?(nil)
            return
        }
        switch microphoneAuthorizationStatus() {
        case .authorized:
            onMicrophone?(id)
        case .notDetermined:
            let request = requestMicrophoneAccess
            Task { [weak self] in
                guard await request(), let self else { return }
                self.deviceNames = self.deviceNames.filter { !$0.key.hasPrefix("\(Toggle.microphone)-") }
                self.onMicrophone?(id)
            }
        default:
            NSSound.beep()
            VoiceOver.announce(
                String(localized: "Microphone access is off, so the recording would have no microphone sound. Turn on OhMyShot in System Settings, Privacy and Security, Microphone.", bundle: .module),
                from: self
            )
            onMicrophone?(id)
        }
    }

    /// No camera, or one of the Mac's, then the bubble's shape, size, where it is while it shows, and whether it is
    /// mirrored.
    private func showCameraMenu(from button: NSButton) {
        let menu = NSMenu()
        let showing = states[.camera] == true
        let none = NSMenuItem(title: String(localized: "No Camera", bundle: .module), action: #selector(cameraChosen(_:)), keyEquivalent: "")
        none.target = self
        none.state = showing ? .off : .on
        menu.addItem(none)
        menu.addItem(.separator())
        let (devices, defaultID) = Cameras.available()
        if devices.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No camera found", bundle: .module), action: nil, keyEquivalent: "")
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
        menu.addItem(.sectionHeader(title: String(localized: "Shape", bundle: .module)))
        for shape in CameraStyle.Shape.allCases {
            let title = shape == .circle ? String(localized: "Circle", bundle: .module) : String(localized: "Rounded Square", bundle: .module)
            let item = NSMenuItem(title: title, action: #selector(cameraShapeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = shape.rawValue
            item.state = cameraStyle.shape == shape ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.sectionHeader(title: String(localized: "Size", bundle: .module)))
        for size in CameraStyle.Size.allCases {
            let title = switch size {
            case .small: String(localized: "Small", bundle: .module)
            case .medium: String(localized: "Medium", bundle: .module)
            case .large: String(localized: "Large", bundle: .module)
            }
            let item = NSMenuItem(title: title, action: #selector(cameraSizeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size.rawValue
            item.state = cameraStyle.size == size ? .on : .off
            menu.addItem(item)
        }
        if showing {
            // Where the bubble is, as dragging it and double-clicking it say with the pointer.
            menu.addItem(.sectionHeader(title: String(localized: "Position", bundle: .module)))
            for corner in CameraBubbleCommand.Corner.allCases {
                let title = switch corner {
                case .topLeft: String(localized: "Top Left", bundle: .module)
                case .topRight: String(localized: "Top Right", bundle: .module)
                case .bottomLeft: String(localized: "Bottom Left", bundle: .module)
                case .bottomRight: String(localized: "Bottom Right", bundle: .module)
                }
                let item = NSMenuItem(title: title, action: #selector(cameraCornerChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = corner.rawValue
                menu.addItem(item)
            }
            let fill = NSMenuItem(title: String(localized: "Fill the Recording", bundle: .module), action: #selector(cameraFillToggled(_:)), keyEquivalent: "")
            fill.target = self
            fill.state = cameraFills() ? .on : .off
            menu.addItem(fill)
        }
        menu.addItem(.separator())
        let mirror = NSMenuItem(title: String(localized: "Mirror", bundle: .module), action: #selector(cameraMirrorToggled(_:)), keyEquivalent: "")
        mirror.target = self
        mirror.state = cameraStyle.mirrored ? .on : .off
        menu.addItem(mirror)
        menu.popUp(under: button)
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
            VoiceOver.announce(String(localized: "Camera access is off. Turn on OhMyShot in System Settings, Privacy and Security, Camera.", bundle: .module), from: self)
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

    @objc private func cameraCornerChosen(_ sender: NSMenuItem) {
        guard let corner = (sender.representedObject as? String).flatMap(CameraBubbleCommand.Corner.init(rawValue:)) else { return }
        onCameraCommand?(.move(corner))
    }

    @objc private func cameraFillToggled(_ sender: NSMenuItem) {
        onCameraCommand?(.toggleFill)
    }

    @objc private func cameraMirrorToggled(_ sender: NSMenuItem) {
        cameraStyle.mirrored.toggle()
        onCameraStyle?(cameraStyle)
    }

    @objc private func recordClicked() {
        onRecord?()
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}

/// Ephemeral `AVCaptureSession` audio-level reader active only while the recording setup bar is visible with
/// an authorized microphone selected. Runs off the main thread and releases its capture lease on `stop()`.
private final class LiveMicrophoneLevelMonitor: MicrophoneLevelMonitoring {
    private var lease: ActiveResources.Lease?
    private var runner: SessionRunner?
    private var onLevel: ((CGFloat) -> Void)?
    private var isRunning = false

    isolated deinit {
        stop()
    }

    func start(deviceID: String, onLevel: @escaping (CGFloat) -> Void) {
        stop()
        isRunning = true
        self.onLevel = onLevel
        lease = ActiveResources.shared.acquire(.captureStream)
        let runner = SessionRunner(deviceID: deviceID) { [weak self] level in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.onLevel?(level)
            }
        }
        self.runner = runner
        runner.start()
    }

    func stop() {
        isRunning = false
        onLevel = nil
        runner?.stop()
        runner = nil
        lease?.end()
        lease = nil
    }
}

private nonisolated final class SessionRunner: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ohmyshot.mic-level", qos: .utility)
    private let deviceID: String
    private let onLevel: @Sendable (CGFloat) -> Void
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var stopped = false
    private var lastReportTime: CFTimeInterval = 0
    private var lastQuantized = -1

    init(deviceID: String, onLevel: @escaping @Sendable (CGFloat) -> Void) {
        self.deviceID = deviceID
        self.onLevel = onLevel
    }

    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            guard let device = (deviceID.isEmpty ? nil : AVCaptureDevice(uniqueID: deviceID))
                ?? AVCaptureDevice.default(for: .audio),
                let input = try? AVCaptureDeviceInput(device: device) else { return }
            let session = AVCaptureSession()
            let output = AVCaptureAudioDataOutput()
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            output.setSampleBufferDelegate(self, queue: queue)
            guard !stopped else {
                output.setSampleBufferDelegate(nil, queue: nil)
                return
            }
            self.session = session
            self.output = output
            session.startRunning()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            output?.setSampleBufferDelegate(nil, queue: nil)
            session?.stopRunning()
            session = nil
            output = nil
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopped else { return }
        let now = CACurrentMediaTime()
        guard now - lastReportTime >= 0.05 else { return }
        let power = connection.audioChannels.map(\.averagePowerLevel).max() ?? -160
        let normalized = CGFloat(max(0, min(1, (power + 50) / 44)))
        let quantized = Int((normalized * 20).rounded())
        guard quantized != lastQuantized else { return }
        lastReportTime = now
        lastQuantized = quantized
        onLevel(CGFloat(quantized) / 20)
    }
}

#if DEBUG
/// The recording bar alone, for rendering checks.
public enum RecordingBarDemo {
    /// A window behind the desktop picture holding the bar with `choices`, with room for its shadow.
    public static func hiddenWindow(choices: RecordingChoices, recordsWindow: Bool = false, dark: Bool) -> NSWindow {
        let bar = RecordingBar(choices: choices, recordsWindow: recordsWindow)
        bar.stopLevelMonitoring()
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
