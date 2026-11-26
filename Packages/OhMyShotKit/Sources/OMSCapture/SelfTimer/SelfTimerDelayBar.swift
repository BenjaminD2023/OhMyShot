import AppKit
import CoreGraphics
import OMSDesign

/// Temporary Self-Timer delay switcher floating just above the overlay's capture mode bar:
/// a leading timer icon and compact preset chips (`2s`, `3s`, `5s`, `10s`, `15s`, plus any
/// custom Settings value) that adjust the delay for the current capture only.
final class SelfTimerDelayBar: CapsuleBar {
    static let defaultDelays = [2, 3, 5, 10, 15]

    var onSelect: ((Int) -> Void)?

    private(set) var selectedDelay: Int = 5
    private(set) var availableDelays: [Int] = SelfTimerDelayBar.defaultDelays

    private let iconView = NSImageView()
    private var slotButtons: [BarButton] = []

    override init() {
        super.init()
        iconView.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageAlignment = .alignCenter
        iconView.imageScaling = .scaleNone
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 24).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: Self.chip).isActive = true
        iconView.setAccessibilityElement(false)
        addView(iconView)
        setSpacing(2, after: iconView)

        // Pre-allocate slots for all default presets plus at most one custom Settings delay so
        // CapsuleBar tracks every chip cleanly across reused overlay sessions.
        slotButtons = (0..<(Self.defaultDelays.count + 1)).map { _ in
            addChip(symbol: nil, title: "", help: "", target: self, action: #selector(chipClicked(_:)))
        }
        setAccessibilityLabel(String(localized: "Self-Timer delay", bundle: .module))
        configure(selected: Self.defaultDelays[2])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The system arrow over the delay bar, matching `AllInOneBar`.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    // Swallow clicks on the non-interactive timer icon and inter-chip gaps so they never begin
    // an area drag on the overlay behind the bar.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    /// Configures the bar for a new Self-Timer session starting at `selected` seconds.
    /// Inserts `selected` into the sorted preset list if it is a custom Settings value.
    func configure(selected: Int) {
        let target = max(selected, 1)
        var delays = Self.defaultDelays
        if !delays.contains(target) {
            delays.append(target)
            delays.sort()
        }
        availableDelays = delays
        selectedDelay = target

        let update = {
            for (index, button) in self.slotButtons.enumerated() {
                if index < delays.count {
                    let seconds = delays[index]
                    let isSelected = seconds == target
                    let shortLabel = String(localized: "\(seconds)s", bundle: .module)
                    let accessibleLabel = String(localized: "\(seconds) seconds", bundle: .module)
                    let help = String(localized: "Capture after \(seconds) seconds (this capture only)", bundle: .module)
                    button.isHidden = false
                    button.tag = seconds
                    self.setTitle(shortLabel, of: button, emphasized: isSelected)
                    button.setAccessibilityLabel(accessibleLabel)
                    button.toolTip = help
                    button.setAccessibilityHelp(help)
                    self.setOn(isSelected, button)
                } else {
                    self.setOn(false, button)
                    button.isHidden = true
                    button.tag = 0
                }
            }
        }
        if let stack = slotButtons.first?.superview as? NSStackView {
            stack.rearrange(in: .zero, update)
        } else {
            update()
        }
        needsLayout = true
    }

    /// Highlights `seconds` within the current session's presets without removing an initially
    /// configured custom delay chip; falls back to `configure(selected:)` if not present.
    func select(_ seconds: Int) {
        let target = max(seconds, 1)
        guard availableDelays.contains(target) else {
            configure(selected: target)
            return
        }
        selectedDelay = target
        for (index, seconds) in availableDelays.enumerated() where index < slotButtons.count {
            let button = slotButtons[index]
            let isSelected = seconds == target
            let shortLabel = String(localized: "\(seconds)s", bundle: .module)
            let accessibleLabel = String(localized: "\(seconds) seconds", bundle: .module)
            setTitle(shortLabel, of: button, emphasized: isSelected)
            button.setAccessibilityLabel(accessibleLabel)
            setOn(isSelected, button)
        }
    }

    /// Cycles to the next delay preset in ascending order (wrapping around), updates selection,
    /// and returns the newly selected delay in seconds.
    @discardableResult
    func cycleNext() -> Int {
        guard !availableDelays.isEmpty else { return selectedDelay }
        let currentIndex = availableDelays.firstIndex(of: selectedDelay) ?? -1
        let next = availableDelays[(currentIndex + 1) % availableDelays.count]
        select(next)
        return next
    }

    /// Returns the delay in seconds for zero-based preset index `index`, or nil if out of range.
    func delay(atPresetIndex index: Int) -> Int? {
        guard availableDelays.indices.contains(index) else { return nil }
        return availableDelays[index]
    }

    /// Visible chip buttons in display order, for tests.
    var visibleChips: [BarButton] {
        slotButtons.filter { !$0.isHidden }
    }

    @objc private func chipClicked(_ sender: NSButton) {
        let seconds = sender.tag
        guard seconds > 0 else { return }
        select(seconds)
        onSelect?(seconds)
    }
}
