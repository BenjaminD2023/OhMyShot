import AppKit
import OMSCapture
import OMSCore
import OMSUI

/// Measure: the frozen screen with the ruler. ⌘C copies the measurement and Return copies it and closes;
/// Tab switches between points and pixels, which is remembered; C takes the color under the crosshair.
final class MeasureCoordinator {
    private let settings: SettingsStore
    private let overlay: OverlayController
    private let colorPicker: ColorPickerCoordinator
    private let copied = CopiedHUD()

    init(settings: SettingsStore, overlay: OverlayController, colorPicker: ColorPickerCoordinator) {
        self.settings = settings
        self.overlay = overlay
        self.colorPicker = colorPicker
    }

    /// Shows the overlay with the ruler.
    /// - Parameter copiesToClipboard: false for scripted checks, which never touch the clipboard.
    func measure(copiesToClipboard: Bool = true) {
        guard !overlay.isActive else { return }
        overlay.measureUnit = settings.measureUnit
        overlay.colorFormat = settings.colorFormat
        overlay.onMeasureUnitChange = { [weak self] unit in self?.settings.measureUnit = unit }
        overlay.onCopyMeasurement = { [weak self] text in self?.copy(text, toClipboard: copiesToClipboard) }
        overlay.begin(mode: .area, purpose: .measure) { [weak self] outcome in
            guard let self else { return }
            overlay.onMeasureUnitChange = nil
            overlay.onCopyMeasurement = nil
            if case .color(let color, let point, _, let modifiers) = outcome {
                colorPicker.deliver(color, at: point, modifiers: modifiers, copiesToClipboard: copiesToClipboard)
            }
        }
    }

    private func copy(_ text: String, toClipboard: Bool) {
        if toClipboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        copied.show(String(localized: "Copied \(text)"), near: NSEvent.mouseLocation)
    }
}
