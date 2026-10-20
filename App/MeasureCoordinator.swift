import AppKit
import OMSCapture
import OMSCore
import OMSUI

/// Measure: the frozen screen with the ruler. ⌘C copies the measurement and Return copies it and closes;
/// Tab switches between points and pixels, T cycles edge tolerance; both are remembered.
/// C takes the color under the crosshair. Clicking a selected box captures its frozen pixels.
final class MeasureCoordinator {
    private let settings: SettingsStore
    private let overlay: OverlayController
    private let colorPicker: ColorPickerCoordinator
    private let captures: CaptureCoordinator
    private let copied = CopiedHUD()

    init(settings: SettingsStore, overlay: OverlayController, colorPicker: ColorPickerCoordinator, captures: CaptureCoordinator) {
        self.settings = settings
        self.overlay = overlay
        self.colorPicker = colorPicker
        self.captures = captures
    }

    /// Shows the overlay with the ruler.
    /// - Parameter copiesToClipboard: false for scripted checks, which never touch the clipboard.
    /// - Parameter allowsCapture: false for drawn-screen checks, which never add captures to History.
    func measure(copiesToClipboard: Bool = true, allowsCapture: Bool = true) {
        guard !overlay.isActive else { return }
        let source = allowsCapture ? NSWorkspace.shared.frontmostApplication : nil
        let appName = source?.localizedName
        let windowTitle: String? = if settings.fileNamePattern.contains(FilenameTemplate.Token.window.placeholder), let source {
            WindowCatalog.frontWindowTitle(ofProcess: source.processIdentifier)
        } else { nil }
        overlay.measureUnit = settings.measureUnit
        overlay.measureTolerance = settings.measureTolerance
        overlay.measureSnapsToContent = settings.measureSnapsToContent
        overlay.colorFormat = settings.colorFormat
        overlay.onMeasureUnitChange = { [weak self] unit in self?.settings.measureUnit = unit }
        overlay.onMeasureToleranceChange = { [weak self] tolerance in self?.settings.measureTolerance = tolerance }
        overlay.onCopyMeasurement = { [weak self] text, point, closing in
            self?.copy(text, toClipboard: copiesToClipboard, closingAt: closing ? point : nil)
        }
        overlay.begin(mode: .area, purpose: .measure) { [weak self] outcome in
            guard let self else { return }
            overlay.onMeasureUnitChange = nil
            overlay.onMeasureToleranceChange = nil
            overlay.onCopyMeasurement = nil
            if case .region(_, _, _, let frozen?) = outcome, allowsCapture {
                captures.deliverMeasuredCapture(frozen, appName: appName, windowTitle: windowTitle, copiesToClipboard: copiesToClipboard)
            }
            if case .color(let color, let point, _, let modifiers, let keyboard) = outcome {
                colorPicker.deliver(color, at: point, modifiers: modifiers, keyboard: keyboard, copiesToClipboard: copiesToClipboard)
            }
        }
    }

    /// Copies the measurement. ⌘C leaves the overlay up, and its reading says "Copied"; Return closes it, and
    /// the copied reading shows by where the crosshair was.
    private func copy(_ text: String, toClipboard: Bool, closingAt point: CGPoint?) {
        if toClipboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
        if let point { copied.show(String(localized: "Copied \(text)"), near: point) }
    }
}
