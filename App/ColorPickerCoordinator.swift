import AppKit
import OMSCapture
import OMSCore
import OMSUI
import OSLog

/// Pick Color: the frozen screen with the magnifier. A click copies the pixel's color in the chosen
/// notation and says so by the pointer; an Option-click opens the color card instead, with every notation,
/// the contrast against a second color, and Pin. C over a capture's or the ruler's magnifier takes the
/// color the same way.
final class ColorPickerCoordinator {
    private let settings: SettingsStore
    private let overlay: OverlayController
    private let copied = CopiedHUD()
    private let card = ColorCardHUD()
    /// Pins a color; the composition root has the pins.
    var pin: ((ScreenColor) -> Void)?

    init(settings: SettingsStore, overlay: OverlayController) {
        self.settings = settings
        self.overlay = overlay
        card.onContrast = { [weak self] in self?.pickContrast() }
        card.onPin = { [weak self] color in self?.pin?(color) }
    }

    /// Shows the overlay for a color.
    /// - Parameter copiesToClipboard: false for scripted checks, which never touch the clipboard.
    func pickColor(copiesToClipboard: Bool = true) {
        guard !overlay.isActive else { return }
        overlay.colorFormat = settings.colorFormat
        overlay.begin(mode: .area, purpose: .color) { [weak self] outcome in
            guard case .color(let color, let point, _, let modifiers, let keyboard) = outcome else { return }
            self?.deliver(color, at: point, modifiers: modifiers, keyboard: keyboard, copiesToClipboard: copiesToClipboard)
        }
    }

    /// A color taken off the screen, by the picker or by C over a magnifier: copied in the chosen notation
    /// and shown by where it was, or with Option shown on the color card, which copies nothing by itself.
    /// - Parameters:
    ///   - keyboard: a key took it, so the card takes the keyboard too.
    ///   - copiesToClipboard: false for scripted checks, which never touch the clipboard.
    func deliver(_ color: ScreenColor, at point: CGPoint, modifiers: NSEvent.ModifierFlags, keyboard: Bool = false, copiesToClipboard: Bool = true) {
        if modifiers.contains(.option) {
            card.show(color, near: point, format: settings.colorFormat, fromKeyboard: keyboard)
            return
        }
        let text = color.string(in: settings.colorFormat)
        if copiesToClipboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        copied.show(String(localized: "Copied \(text)"), swatch: color.cgColor, near: point)
    }

    /// The card's Contrast…: a second color, for the card to set against its own.
    private func pickContrast() {
        guard !overlay.isActive else {
            card.setPickingContrast(false)
            return
        }
        overlay.colorFormat = settings.colorFormat
        overlay.begin(mode: .area, purpose: .color) { [weak self] outcome in
            guard let self else { return }
            if case .color(let color, _, _, _, _) = outcome {
                card.showContrast(with: color)
            } else {
                card.setPickingContrast(false)
            }
        }
    }

    #if DEBUG
    /// The color card for `color`, against `other` when given, behind the desktop picture: its window, for
    /// a scripted capture. Nothing shows.
    func debugHiddenCard(_ color: ScreenColor, against other: ScreenColor?) -> NSWindow? {
        card.show(color, near: NSScreen.main.map { CGPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) } ?? .zero, format: settings.colorFormat)
        if let other { card.showContrast(with: other) }
        return card.debugHide()
    }

    func debugDismissCard() {
        card.dismiss()
    }
    #endif
}
