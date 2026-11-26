import AppKit
import OMSCore
import OMSDesign

/// What the overlay shows once an area is chosen for a scrolling capture, before it starts: the area framed on
/// the dimmed screen, as a recording's is, with its corners and edges to adjust it and the scrolling bar under
/// it. A drag outside the frame chooses a new area. Return starts, Escape cancels, and a double click inside
/// the frame starts as well.
///
/// Flipped: points from the display's top-left corner, as the frame's drawing expects.
final class ScrollingSetupView: AreaSetupView<ScrollingBar> {
    /// Start was chosen: the area in global points, and whether the app scrolls it.
    var onStart: ((CGRect, Bool) -> Void)?

    /// The area in global points.
    private(set) var area: CGRect

    init(display: DisplayInfo, area: CGRect) {
        self.area = area
        super.init(display: display, bar: ScrollingBar())
        bar.onStart = { [weak self] in self?.start(autoScrolls: false) }
        bar.onAutoScroll = { [weak self] in self?.start(autoScrolls: true) }
        bar.onSize = { [weak self] width, height in self?.type(width: width, height: height) }
        bar.onDoneTyping = { [weak self] in
            guard let self else { return }
            window?.makeFirstResponder(self)
        }
        bar.onCancel = { [weak self] in self?.onCancel?() }
        setAccessibilityLabel(String(localized: "Scrolling capture area", bundle: .module))
        setAccessibilityHelp(Self.instructions)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static let instructions = String(localized: "Press Return to start, then scroll what is under the area. The arrow keys move the area; with Option they resize it. Tab goes to its width and height in pixels. Press Escape to cancel.", bundle: .module)

    /// Says what to do next.
    override func begin() {
        VoiceOver.announce(Self.instructions, from: self)
    }

    override var adjustableArea: CGRect? { area }

    override func areaAdjusted(_ area: CGRect) {
        self.area = area
        update()
    }

    override func primaryAction() {
        start(autoScrolls: false)
    }

    override func cursor(overBarAt point: CGPoint) -> NSCursor {
        bar.sizeFieldFrames.contains { convert($0, from: bar).insetBy(dx: -6, dy: -4).contains(point) } ? .iBeam : .arrow
    }

    override func keyDown(with event: NSEvent) {
        if answersKeyList(event) { return }
        if event.keyCode == 48, !(window?.firstResponder is NSText) {
            bar.focusWidth()
            return
        }
        super.keyDown(with: event)
    }

    /// The area's size in pixels, as it will be captured.
    private var pixelSize: CGSize {
        let scale = display.pixelsPerPoint
        return CGSize(width: (area.width * scale).rounded(), height: (area.height * scale).rounded())
    }

    private var pixelReading: String {
        AreaFrame.pixelReading(area.size, pixelsPerPoint: display.pixelsPerPoint)
    }

    /// What the bar's size fields show, for tests.
    var barSizeSummary: String { bar.shownText }

    private func update() {
        chrome.selection = frameRect
        chrome.showsHandles = true
        bar.show(pixelSize: pixelSize)
        placeBar()
        setAccessibilityValue(pixelReading)
    }

    override func placeBar() {
        super.placeBar()
        chrome.reading = bar.isHidden ? pixelReading : ""
    }

    private func type(width: Int?, height: Int?) {
        let scale = display.pixelsPerPoint
        var size = area.size
        if let width { size.width = CGFloat(width) / scale }
        if let height { size.height = CGFloat(height) / scale }
        size.width = max(size.width, AreaFrame.smallest)
        size.height = max(size.height, AreaFrame.smallest)
        let sized = AreaFrame.sized(AreaFrame.local(area, on: display), to: size, in: bounds)
        if setArea(sized) { NSAccessibility.post(element: self, notification: .valueChanged) }
    }

    private func start(autoScrolls: Bool) {
        if window?.firstResponder is NSText { window?.makeFirstResponder(self) }
        onStart?(area, autoScrolls)
    }

    #if DEBUG
    /// Presses Start or Auto-scroll as their chips would, for scripted checks.
    func debugStart(autoScrolls: Bool) {
        start(autoScrolls: autoScrolls)
    }
    #endif
}

#if DEBUG
/// Scrolling capture's controls on their own, for scripted renders.
public enum ScrollingRenders {
    /// The bar under a chosen area, alone in a window behind the desktop picture.
    public static func hiddenBarWindow(dark: Bool) -> NSWindow {
        let bar = ScrollingBar()
        bar.show(pixelSize: CGSize(width: 1200, height: 800))
        let size = bar.fittingSize
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: size.width + 40, height: size.height + 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.backgroundColor = dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if let screen = NSScreen.screens.first { window.setFrameOrigin(CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY)) }
        bar.frame = CGRect(x: 20, y: 20, width: size.width, height: size.height)
        window.contentView?.addSubview(bar)
        window.orderFront(nil)
        return window
    }
}
#endif

/// The bar under an area chosen for a scrolling capture: Start Capture (Return), Auto-scroll, pixel size fields, and Cancel.
final class ScrollingBar: CapsuleBar {
    var onStart: (() -> Void)?
    var onAutoScroll: (() -> Void)?
    var onSize: ((Int?, Int?) -> Void)?
    var onDoneTyping: (() -> Void)?
    var onCancel: (() -> Void)?
    private let sizeFields = AreaSizeFields()

    override init() {
        super.init()
        let start = addChip(
            symbol: "arrow.up.and.down.text.horizontal", title: String(localized: "Start Capture", bundle: .module),
            help: String(localized: "Start, then scroll what is under the area (Return)", bundle: .module), target: self, action: #selector(startClicked)
        )
        setTitle(String(localized: "Start Capture", bundle: .module), of: start, emphasized: true)
        _ = addChip(
            symbol: "arrow.down.circle", title: String(localized: "Auto-scroll", bundle: .module),
            help: String(localized: "Start scrolling automatically; adjust the speed in the capture panel", bundle: .module), target: self, action: #selector(autoScrollClicked)
        )
        addDivider()
        addView(sizeFields)
        sizeFields.onSize = { [weak self] width, height in self?.onSize?(width, height) }
        sizeFields.onDone = { [weak self] in self?.onDoneTyping?() }
        addDivider()
        _ = addChip(symbol: "xmark", title: nil, help: String(localized: "Cancel (Esc)", bundle: .module), target: self, action: #selector(cancelClicked))
        setAccessibilityLabel(String(localized: "Scrolling Capture", bundle: .module))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(pixelSize: CGSize) {
        sizeFields.show(pixelSize)
    }

    func focusWidth() {
        sizeFields.focusWidth()
    }

    var sizeFieldFrames: [CGRect] { sizeFields.fieldFrames.map { sizeFields.convert($0, to: self) } }

    var shownText: String { sizeFields.shownText }

    @objc private func startClicked() {
        onStart?()
    }

    @objc private func autoScrollClicked() {
        onAutoScroll?()
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}
