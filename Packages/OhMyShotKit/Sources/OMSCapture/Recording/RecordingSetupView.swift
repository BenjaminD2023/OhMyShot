import AppKit
import OMSCore
import OMSDesign

/// What the overlay shows once something to record is chosen, before recording starts: the choice framed
/// on the dimmed screen, as in-place annotation frames its selection, with the recording bar under it.
///
/// An area keeps its frame's corners and can still be moved and resized; a window or the whole display is
/// framed as it is. A drag outside the frame chooses a new area. Return records, Escape cancels.
///
/// Flipped: points from the display's top-left corner, as the frame's drawing expects.
final class RecordingSetupView: AreaSetupView<RecordingBar> {
    /// What is chosen changed: the choices on the bar, or the area once an adjustment ends.
    var onChange: ((RecordingTarget, RecordingChoices) -> Void)?
    var onRecord: ((RecordingTarget, RecordingChoices) -> Void)?

    private(set) var target: RecordingTarget
    private(set) var choices: RecordingChoices

    init(display: DisplayInfo, target: RecordingTarget, choices: RecordingChoices) {
        self.target = target
        self.choices = choices
        super.init(display: display, bar: RecordingBar(choices: choices, recordsWindow: { if case .window = target { true } else { false } }()))
        bar.onOutput = { [weak self] output in self?.choose(output) }
        bar.onToggle = { [weak self] toggle in self?.toggle(toggle) }
        bar.onMicrophone = { [weak self] id in self?.chooseMicrophone(id) }
        bar.onCamera = { [weak self] id in self?.chooseCamera(id) }
        bar.onCameraStyle = { [weak self] style in self?.setCameraStyle(style) }
        bar.onRecord = { [weak self] in self?.record() }
        bar.onCancel = { [weak self] in self?.onCancel?() }
        setAccessibilityLabel(String(localized: "Recording area", bundle: .module))
        setAccessibilityHelp(String(localized: "Press Return to start recording, or Escape to cancel.", bundle: .module))
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Says what to do next, and what is chosen to begin with.
    override func begin() {
        onChange?(target, choices)
        VoiceOver.announce(String(localized: "Press Return to start recording, or Escape to cancel.", bundle: .module), from: self)
    }

    /// An area can be moved and resized; a window or the whole display is framed as it is.
    override var adjustableArea: CGRect? {
        if case .area(let rect) = target { rect } else { nil }
    }

    override var frameRect: CGRect {
        switch target {
        case .area(let rect): AreaFrame.local(rect, on: display)
        case .window(let window): AreaFrame.local(window.frame, on: display).intersection(bounds)
        case .display: bounds
        }
    }

    override func areaAdjusted(_ area: CGRect) {
        target = .area(area)
        update()
    }

    override func primaryAction() {
        record()
    }

    override func adjustmentEnded() {
        onChange?(target, choices)
    }

    /// The size the recording will have, in pixels: what the stream records, made even.
    private var pixelReading: String {
        let size: CGSize = switch target {
        case .area(let rect): rect.size
        case .window(let window): window.frame.size
        case .display: display.frame.size
        }
        let scale = display.pixelsPerPoint
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        return "\(width - width % 2) × \(height - height % 2)"
    }

    private func update() {
        chrome.selection = frameRect
        chrome.showsHandles = adjustableArea != nil
        chrome.reading = {
            if case .window(let window) = target, !window.ownerName.isEmpty { return "\(window.ownerName)  ·  \(pixelReading)" }
            return pixelReading
        }()
        placeBar()
        setAccessibilityValue(pixelReading)
    }

    // MARK: Choices

    private func choose(_ output: RecordingOutput) {
        guard output != choices.output else { return }
        choices.output = output
        bar.update(choices)
        placeBar()
        onChange?(target, choices)
    }

    /// A camera by its unique ID (empty for the system's default), or none.
    private func chooseCamera(_ id: String?) {
        choices.camera = id != nil
        if let id { choices.cameraID = id }
        bar.update(choices)
        onChange?(target, choices)
    }

    private func setCameraStyle(_ style: CameraStyle) {
        choices.cameraStyle = style
        bar.update(choices)
        onChange?(target, choices)
    }

    /// A microphone by its unique ID (empty for the system's default), or none.
    private func chooseMicrophone(_ id: String?) {
        choices.microphone = id != nil
        if let id { choices.microphoneID = id }
        bar.update(choices)
        onChange?(target, choices)
    }

    private func toggle(_ toggle: RecordingBar.Toggle) {
        switch toggle {
        case .systemAudio: choices.systemAudio.toggle()
        case .microphone: choices.microphone.toggle()
        case .camera: choices.camera.toggle()
        case .clicks: choices.showsClicks.toggle()
        case .keystrokes: choices.showsKeystrokes.toggle()
        }
        bar.update(choices)
        onChange?(target, choices)
    }

    private func record() {
        // A display chosen as an area that covers it whole is the display.
        if case .area(let rect) = target, rect.insetBy(dx: 0.5, dy: 0.5).contains(display.frame.insetBy(dx: 1, dy: 1)) {
            target = .display
        }
        onRecord?(target, choices)
    }

    #if DEBUG
    /// Presses Record as Return would, for scripted checks.
    func debugRecord() {
        record()
    }

    /// Turns a choice on or off as its chip would, for scripted checks.
    func debugToggle(_ toggle: RecordingBar.Toggle) {
        self.toggle(toggle)
    }

    /// Chooses Video or GIF as its chip would, for scripted checks.
    func debugChoose(_ output: RecordingOutput) {
        choose(output)
    }
    #endif
}
