import AppKit
import OMSCore

/// What a scrolling capture shows beside its area while it runs: a card with the picture as it grows (where the
/// view is, what just came into view always in it) and its size, a hint when one helps, and a bar with Done,
/// Auto-scroll, and Cancel.
///
/// The card stands to the right of an area that scrolls down or up and under one that scrolls sideways,
/// wherever the display has room, inside the area's edge when it has none. The panel never takes the
/// keyboard, which stays with the app being scrolled, and like everything of this app it is left out of
/// what is captured.
public final class ScrollingPanel {
    public enum Hint: Equatable {
        /// Nothing has scrolled yet.
        case scrollToBegin
        /// The last views lined up with nothing.
        case scrollBack
        /// The picture is as long as it may be.
        case full
        /// The app is scrolling.
        case autoScrolling
        case autoScrollPaused
        case noScrollTarget
        /// Auto-scroll needs Accessibility, which is off.
        case needsAccessibility
        /// Auto-scroll stopped as the user took over.
        case autoScrollStopped(AutoScroller.TakeOver)

        var isAutoScrollStopped: Bool {
            if case .autoScrollStopped = self { true } else { false }
        }
    }

    public var onDone: (() -> Void)?
    public var onCancel: (() -> Void)?
    /// Auto-scroll was turned on or off from the bar.
    public var onAutoScroll: ((Bool) -> Void)?
    public var onSpeedChanged: ((Double) -> Void)?

    /// The preview's size in points: across the scroll, and the most along it.
    public static let previewAcross: CGFloat = 156
    public static let previewAlong: CGFloat = 560

    private let window: PanelWindow
    private let content = PanelContentView()
    private let card = CardView()
    private let bar = ScrollingControls()
    private let speedControl = ScrollSpeedControl()
    private var area: CGRect = .zero
    private var displayFrame: CGRect = .zero
    private var axis: ScrollStitcher.Axis?
    private var preview: CGImage?
    private var size: (width: Int, height: Int)?
    /// What the hint is made from, most pressing first: the limit, losing track, the app scrolling,
    /// Accessibility off, nothing scrolled yet.
    private var isFull = false
    private var lostInARow = 0
    private var isAutoScrolling = false
    private var hasAutoControls = false
    private var hasNoScrollTarget = false
    private var needsAccessibility = false
    /// How the user took over from Auto-scroll, said for a few seconds.
    private var tookOver: AutoScroller.TakeOver?
    private var tookOverShown: Task<Void, Never>?
    private var lastHint: Hint? = .scrollToBegin
    private var lease: ActiveResources.Lease?

    public init() {
        window = PanelWindow(contentRect: .zero)
        window.contentView = content
        content.addSubview(card)
        content.addSubview(bar)
        content.addSubview(speedControl)
        speedControl.isHidden = true
        speedControl.onChange = { [weak self] speed in self?.onSpeedChanged?(speed) }
        bar.onDone = { [weak self] in self?.onDone?() }
        bar.onCancel = { [weak self] in self?.onCancel?() }
        bar.onAutoScroll = { [weak self] on in self?.onAutoScroll?(on) }
    }

    /// The preview's size in pixels on `display`, for the capture to make it at.
    public static func previewPixels(on display: DisplayInfo) -> (across: Int, along: Int) {
        let scale = display.backingScale
        return (Int((previewAcross * scale).rounded()), Int((min(previewAlong, display.frame.height - 220) * scale).rounded()))
    }

    public var isShowing: Bool { window.isVisible }

    /// Shows the panel beside `area` (global points) on the display whose frame is `displayFrame`. `doneKeys` are
    /// the keys of the shortcut that also ends the capture, when it has one.
    public func show(beside area: CGRect, displayFrame: CGRect, doneKeys: String?) {
        self.area = area
        self.displayFrame = displayFrame
        bar.setDoneKeys(doneKeys)
        window.orderFrontRegardless()
        layout()
        lease = ActiveResources.shared.acquire(.window)
        let announcement = doneKeys.map {
            String(localized: "Scroll what is under the area to capture it. Click Done, or press \($0) again, when you have all of it.", bundle: .module)
        } ?? String(localized: "Scroll what is under the area to capture it. Click Done when you have all of it.", bundle: .module)
        NSAccessibility.post(element: card, notification: .announcementRequested, userInfo: [
            .announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// Shows how the capture is going.
    public func update(_ progress: ScrollingCapture.Progress) {
        if let image = progress.preview { preview = image }
        if progress.axis != nil { axis = progress.axis }
        size = (progress.pictureWidth, progress.pictureHeight)
        isFull = progress.isFull
        lostInARow = progress.lostInARow
        // Scrolling by hand works without Accessibility: the hint about it has done its part.
        if case .scrolled = progress.step { needsAccessibility = false }
        layout()
    }

    /// Shows that the app is scrolling, or no longer is.
    public func setAutoScrolling(_ on: Bool) {
        isAutoScrolling = on
        if on { hasAutoControls = true }
        hasNoScrollTarget = false
        if on { tookOver = nil }
        bar.setAutoScrolling(on)
        layout()
    }

    public func showNoScrollTarget() {
        hasNoScrollTarget = true
        layout()
    }

    /// Says for a few seconds why Auto-scroll stopped: the user took over, as `how` says.
    public func showAutoScrollStopped(_ how: AutoScroller.TakeOver) {
        tookOver = how
        layout()
        tookOverShown?.cancel()
        // Reaching the end is said until something else is: it is what the user needs to know next.
        guard how != .reachedEnd else { return }
        tookOverShown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            tookOver = nil
            layout()
        }
    }

    /// The way Auto-scroll goes, which its chip points.
    public func setAutoScrollDirection(_ direction: AutoScroller.Direction) {
        bar.setDirection(direction)
    }

    /// Says Auto-scroll needs Accessibility, until scrolling by hand shows the capture going on without it.
    public func showNeedsAccessibility() {
        needsAccessibility = true
        bar.setAutoScrolling(false)
        layout()
    }

    public func close() {
        tookOverShown?.cancel()
        window.orderOut(nil)
        preview = nil
        card.picture = nil
        lease = nil
    }

    /// The hint shown now, the most pressing.
    private var hint: Hint? {
        if isFull { return .full }
        if lostInARow >= 2 { return .scrollBack }
        if isAutoScrolling { return .autoScrolling }
        if hasNoScrollTarget { return .noScrollTarget }
        if needsAccessibility { return .needsAccessibility }
        if let tookOver { return .autoScrollStopped(tookOver) }
        if hasAutoControls { return .autoScrollPaused }
        return axis == nil ? .scrollToBegin : nil
    }

    private func announce(_ hint: Hint) {
        NSAccessibility.post(element: card, notification: .announcementRequested, userInfo: [
            .announcement: Self.text(for: hint), .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private static func text(for hint: Hint) -> String {
        switch hint {
        case .scrollToBegin: String(localized: "Scroll to capture", bundle: .module)
        case .scrollBack: String(localized: "The views no longer line up. Let the page settle, or scroll back a little.", bundle: .module)
        case .full: String(localized: "This is as long as a capture can be. Click Done to keep it.", bundle: .module)
        case .autoScrolling: String(localized: "Scrolling…", bundle: .module)
        case .autoScrollPaused: String(localized: "Paused", bundle: .module)
        case .noScrollTarget: String(localized: "Auto-scroll couldn’t start for this window. You can still scroll by hand.", bundle: .module)
        case .needsAccessibility: String(localized: "Auto-scroll needs Accessibility. Turn it on in System Settings › Privacy & Security.", bundle: .module)
        case .autoScrollStopped(.click), .autoScrollStopped(.key), .autoScrollStopped(.scroll): String(localized: "Paused", bundle: .module)
        case .autoScrollStopped(.targetClosed): String(localized: "Auto-scroll stopped: the target app closed.", bundle: .module)
        case .autoScrollStopped(.reachedEnd): String(localized: "Auto-scroll stopped: nothing more came into view. Click Done, or scroll on by hand.", bundle: .module)
        }
    }

    // MARK: Layout

    private func layout() {
        // Progress can come before the panel is shown, while it has no area to stand beside: it waits.
        guard window.isVisible, !area.isEmpty, !displayFrame.isEmpty else { return }
        let hint = self.hint
        // What changed for the worse, Accessibility being off, or Auto-scroll handing back is said once as it shows.
        if hint != lastHint, let hint, hint == .scrollBack || hint == .full || hint == .needsAccessibility || hint.isAutoScrollStopped { announce(hint) }
        lastHint = hint
        let sideways = axis == .horizontal
        // The picture at its own size in points, within the preview's bounds.
        let scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 2
        var picture = preview.map { CGSize(width: CGFloat($0.width) / scale, height: CGFloat($0.height) / scale) }
            ?? CGSize(width: Self.previewAcross, height: Self.previewAcross * 0.6)
        if sideways { picture = CGSize(width: min(picture.width, Self.previewAlong), height: min(picture.height, Self.previewAcross)) }
        card.picture = preview
        card.reading = size.map { "\($0.width) × \($0.height)" } ?? ""
        card.hint = hint.map(Self.text(for:))
        card.controlsHeight = hasAutoControls ? 50 : 0
        let cardSize = card.fittingSize(for: picture)
        let barSize = bar.fittingSize
        let width = max(cardSize.width, barSize.width)
        let height = cardSize.height + 10 + barSize.height
        card.frame = CGRect(x: (width - cardSize.width) / 2, y: barSize.height + 10, width: cardSize.width, height: cardSize.height)
        speedControl.isHidden = !hasAutoControls
        speedControl.frame = CGRect(x: card.frame.minX + 12, y: card.frame.minY + 8, width: cardSize.width - 24, height: 40)
        bar.frame = CGRect(x: (width - barSize.width) / 2, y: 0, width: barSize.width, height: barSize.height).integral
        let frame = Self.place(CGSize(width: width, height: height), beside: area, sideways: sideways, on: displayFrame)
        window.setFrame(frame, display: false)
    }

    /// Where the panel goes: beside the area along the scroll's cross side, on the display, as near as it fits.
    static func place(_ size: CGSize, beside area: CGRect, sideways: Bool, on display: CGRect) -> CGRect {
        var room = display.insetBy(dx: 8, dy: 8)
        // A display too small for its margins: the display itself.
        if room.isNull || room.isEmpty { room = display }
        let gap: CGFloat = 12
        let candidates: [CGRect] = sideways ? [
            CGRect(x: area.minX, y: area.minY - gap - size.height, width: size.width, height: size.height),
            CGRect(x: area.minX, y: area.maxY + gap, width: size.width, height: size.height),
            CGRect(x: area.minX + gap, y: area.minY + gap, width: size.width, height: size.height),
        ] : [
            CGRect(x: area.maxX + gap, y: area.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: area.minX - gap - size.width, y: area.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: area.maxX - gap - size.width, y: area.maxY - gap - size.height, width: size.width, height: size.height),
        ]
        func clamped(_ rect: CGRect) -> CGRect {
            var rect = rect
            rect.origin.x = min(max(rect.minX, room.minX), room.maxX - rect.width)
            rect.origin.y = min(max(rect.minY, room.minY), room.maxY - rect.height)
            return rect
        }
        // The first that fits beside the area without moving onto it; else the last, kept on the display.
        for candidate in candidates.dropLast() {
            let kept = clamped(candidate)
            if room.contains(candidate) || !kept.intersects(area) { return kept.integral }
        }
        return clamped(candidates[candidates.count - 1]).integral
    }

    #if DEBUG
    /// The panel's window, for scripted renders.
    public var debugWindow: NSWindow { window }

    /// Puts the panel behind the desktop picture, for scripted checks that show nothing.
    public func debugHide() {
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
    }
    #endif
}

/// A panel that never takes the keyboard and floats with the area's outline, over menus, on every Space.
private final class PanelWindow: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click through to the buttons: the panel is never key.
private final class PanelContentView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The card: the picture so far, its size in pixels, and a hint.
private final class CardView: NSView {
    var controlsHeight: CGFloat = 0
    var picture: CGImage? {
        didSet {
            image.contents = picture
            needsLayout = true
        }
    }
    var reading = "" {
        didSet {
            readingField.stringValue = reading
            setAccessibilityValue(reading)
            needsLayout = true
        }
    }
    var hint: String? {
        didSet {
            hintField.stringValue = hint ?? ""
            hintField.isHidden = hint == nil
            setAccessibilityHelp(hint)
            needsLayout = true
        }
    }

    private static let inset: CGFloat = 6
    private let image = CALayer()
    private let readingField = NSTextField(labelWithString: "")
    private let hintField = NSTextField(wrappingLabelWithString: "")

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.card
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        layer?.shadowColor = .black
        layer?.shadowOpacity = Theme.Shadow.opacity
        layer?.shadowRadius = Theme.Shadow.radius
        layer?.shadowOffset = CGSize(width: 0, height: -Theme.Shadow.drop)
        image.cornerRadius = Theme.Radius.card - Self.inset
        image.cornerCurve = .continuous
        image.masksToBounds = true
        image.contentsGravity = .resize
        // A new picture up to ten times a second, never crossfaded: overlay layers change without animation.
        image.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(image)
        readingField.font = Theme.Typeface.reading(size: 12)
        readingField.alignment = .center
        readingField.textColor = .labelColor
        hintField.font = Theme.Typeface.label(size: 11, weight: .medium)
        hintField.alignment = .center
        hintField.textColor = .secondaryLabelColor
        hintField.isHidden = true
        addSubview(readingField)
        addSubview(hintField)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Captured so far", bundle: .module))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// The card's size for a picture shown at `picture` points.
    func fittingSize(for picture: CGSize) -> CGSize {
        let width = max(picture.width, 120) + 2 * Self.inset
        hintField.preferredMaxLayoutWidth = width - 2 * Self.inset
        let hintHeight = hint == nil ? 0 : hintField.fittingSize.height + 2
        pictureSize = picture
        return CGSize(width: width, height: picture.height + 2 * Self.inset + 18 + hintHeight + 6 + controlsHeight)
    }

    private var pictureSize: CGSize = .zero

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.backgroundColor = dark ? NSColor.windowBackgroundColor.cgColor : CGColor(gray: 1, alpha: 1)
            layer?.borderWidth = contrast ? 1 : 0.5
            layer?.borderColor = contrast ? (dark ? CGColor(gray: 1, alpha: 0.5) : CGColor(gray: 0, alpha: 0.35)) : NSColor.separatorColor.cgColor
            image.borderWidth = 0.5
            image.borderColor = NSColor.separatorColor.cgColor
        }
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Theme.Radius.card, cornerHeight: Theme.Radius.card, transform: nil)
        // y up: the picture at the top, the reading under it, the hint at the bottom.
        image.frame = CGRect(x: (bounds.width - pictureSize.width) / 2, y: bounds.height - Self.inset - pictureSize.height, width: pictureSize.width, height: pictureSize.height)
        let hintHeight = hintField.isHidden ? 0 : hintField.fittingSize.height
        readingField.frame = CGRect(x: Self.inset, y: image.frame.minY - 20, width: bounds.width - 2 * Self.inset, height: 16)
        hintField.frame = CGRect(x: Self.inset, y: 6 + controlsHeight, width: bounds.width - 2 * Self.inset, height: hintHeight)
        CATransaction.commit()
    }
}

/// A native slider, kept visible while automatic scrolling is paused so speed can be set before resuming.
private final class ScrollSpeedControl: NSView {
    var onChange: ((Double) -> Void)?
    private let label = NSTextField(labelWithString: String(localized: "Speed", bundle: .module))
    private let value = NSTextField(labelWithString: "1×")
    private let slider = NSSlider(value: 1, minValue: 0.25, maxValue: 2, target: nil, action: nil)

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = Theme.Typeface.label(size: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        value.font = Theme.Typeface.reading(size: 11)
        value.alignment = .right
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        slider.setAccessibilityLabel(String(localized: "Automatic scrolling speed", bundle: .module))
        slider.setAccessibilityHelp(String(localized: "From one quarter speed to double speed", bundle: .module))
        addSubview(label)
        addSubview(value)
        addSubview(slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        label.frame = CGRect(x: 0, y: 24, width: bounds.width - 45, height: 15)
        value.frame = CGRect(x: bounds.width - 45, y: 24, width: 45, height: 15)
        slider.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 22)
    }

    @objc private func changed() {
        let speed = slider.doubleValue
        value.stringValue = speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
        onChange?(speed)
    }
}

/// The bar under the card: Done, Auto-scroll/Pause, Cancel.
private final class ScrollingControls: CapsuleBar {
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var onAutoScroll: ((Bool) -> Void)?

    private var done: BarButton?
    private var autoScroll: BarButton?
    private var isAutoScrolling = false
    private var hasStarted = false
    private var direction: AutoScroller.Direction = .down

    override init() {
        super.init()
        let done = addChip(symbol: "checkmark", title: String(localized: "Done", bundle: .module), help: String(localized: "Keep the picture", bundle: .module), target: self, action: #selector(doneClicked))
        setTitle(String(localized: "Done", bundle: .module), of: done, emphasized: true)
        self.done = done
        let autoScroll = addChip(
            symbol: Self.symbol(for: .down), title: String(localized: "Auto", bundle: .module), help: Self.help(for: .down, on: false), target: self, action: #selector(autoScrollClicked)
        )
        // One width for all its titles, so it doesn't jump as they change: the widest's, in whatever language.
        let titles = [String(localized: "Pause", bundle: .module), String(localized: "Resume", bundle: .module), String(localized: "Auto", bundle: .module)]
        let widest = titles.map { title -> CGFloat in
            setTitle(title, of: autoScroll)
            return autoScroll.fittingSize.width
        }.max() ?? 0
        autoScroll.widthAnchor.constraint(equalToConstant: max(80, ceil(widest) + 16)).isActive = true
        autoScroll.setButtonType(.momentaryPushIn)
        autoScroll.setAccessibilityLabel(String(localized: "Auto-scroll", bundle: .module))
        autoScroll.setAccessibilityRole(.button)
        self.autoScroll = autoScroll
        addDivider()
        _ = addChip(symbol: "xmark", title: nil, help: String(localized: "Cancel the scrolling capture", bundle: .module), target: self, action: #selector(cancelClicked))
        setAccessibilityLabel(String(localized: "Scrolling Capture", bundle: .module))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Done's tooltip names the shortcut that also ends the capture.
    func setDoneKeys(_ keys: String?) {
        let help = keys.map { String(localized: "Keep the picture (\($0))", bundle: .module) } ?? String(localized: "Keep the picture", bundle: .module)
        done?.toolTip = help
        done?.setAccessibilityHelp(help)
    }

    func setAutoScrolling(_ on: Bool) {
        isAutoScrolling = on
        if on { hasStarted = true }
        guard let autoScroll else { return }
        setOn(on, autoScroll)
        let title = on ? String(localized: "Pause", bundle: .module) : hasStarted ? String(localized: "Resume", bundle: .module) : String(localized: "Auto", bundle: .module)
        setTitle(title, of: autoScroll)
        autoScroll.setAccessibilityLabel(on ? String(localized: "Pause automatic scrolling", bundle: .module) : hasStarted ? String(localized: "Resume automatic scrolling", bundle: .module) : String(localized: "Auto-scroll", bundle: .module))
        autoScroll.image = NSImage(systemSymbolName: on ? "pause.fill" : Self.symbol(for: direction), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        autoScroll.toolTip = Self.help(for: direction, on: on)
        autoScroll.setAccessibilityHelp(autoScroll.toolTip)
    }

    /// Auto-scroll points the way the capture has been going, which Resume goes on.
    func setDirection(_ direction: AutoScroller.Direction) {
        guard direction != self.direction, let autoScroll else { return }
        self.direction = direction
        if !isAutoScrolling {
            autoScroll.image = NSImage(systemSymbolName: Self.symbol(for: direction), accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        }
        autoScroll.toolTip = Self.help(for: direction, on: isAutoScrolling)
        autoScroll.setAccessibilityHelp(autoScroll.toolTip)
    }

    /// A play triangle pointing the way the app will scroll.
    private static func symbol(for direction: AutoScroller.Direction) -> String {
        switch direction {
        case .down: "arrowtriangle.down.fill"
        case .up: "arrowtriangle.up.fill"
        case .left: "arrowtriangle.left.fill"
        case .right: "arrowtriangle.right.fill"
        }
    }

    private static func help(for direction: AutoScroller.Direction, on: Bool) -> String {
        if on { return String(localized: "Pause automatic scrolling", bundle: .module) }
        return switch direction {
        case .down: String(localized: "Scroll down automatically", bundle: .module)
        case .up: String(localized: "Scroll up automatically", bundle: .module)
        case .left: String(localized: "Scroll left automatically", bundle: .module)
        case .right: String(localized: "Scroll right automatically", bundle: .module)
        }
    }

    @objc private func doneClicked() {
        onDone?()
    }

    @objc private func autoScrollClicked() {
        onAutoScroll?(!isAutoScrolling)
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}
