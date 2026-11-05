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
        bar.onCancel = { [weak self] in self?.onCancel?() }
        setAccessibilityLabel(String(localized: "Scrolling capture area", bundle: .module))
        setAccessibilityHelp(Self.instructions)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static let instructions = String(localized: "Press Return to start, then scroll what is under the area. Press Escape to cancel.", bundle: .module)

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

    /// The area's size in pixels, as it will be captured.
    private var pixelReading: String {
        AreaFrame.pixelReading(area.size, pixelsPerPoint: display.pixelsPerPoint)
    }

    private func update() {
        chrome.selection = frameRect
        chrome.showsHandles = true
        chrome.reading = pixelReading
        placeBar()
        setAccessibilityValue(pixelReading)
    }

    private func start(autoScrolls: Bool) {
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

/// The bar under an area chosen for a scrolling capture: Start Capture (Return), Auto-scroll, and Cancel.
final class ScrollingBar: CapsuleBar {
    var onStart: (() -> Void)?
    var onAutoScroll: (() -> Void)?
    var onCancel: (() -> Void)?

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
        _ = addChip(symbol: "xmark", title: nil, help: String(localized: "Cancel (Esc)", bundle: .module), target: self, action: #selector(cancelClicked))
        setAccessibilityLabel(String(localized: "Scrolling Capture", bundle: .module))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

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
