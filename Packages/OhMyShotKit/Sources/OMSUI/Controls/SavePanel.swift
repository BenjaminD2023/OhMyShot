import AppKit
import OMSCore
import UniformTypeIdentifiers

/// The system's Save panel for a capture, shown from the run loop.
public enum SavePanel {
    /// Asks where to save a copy. The first of `types` is the file's default type; a name typed with another of them
    /// is kept, so a screenshot saved as HEIC can be saved as `.png` by naming it so.
    /// - Parameters:
    ///   - name: the file's name, without its extension.
    ///   - directory: where the panel opens.
    /// - Returns: the place chosen, or nil when the person cancelled.
    public static func ask(name: String, types: [UTType], directory: URL) async -> URL? {
        await onRunLoop { run(name: name, types: types, directory: directory) }
    }

    /// Asks where to save a screenshot and how: the panel holds the format, the quality, and what is done to the
    /// picture, starting from `output` (Settings'). A name typed with another format's extension saves in that format.
    /// - Returns: the place chosen and how to write the picture there, or nil when the person cancelled.
    public static func askForPicture(name: String, output: ScreenshotOutput, directory: URL) async -> (url: URL, output: ScreenshotOutput)? {
        await onRunLoop { runForPicture(name: name, output: output, directory: directory) }
    }

    /// From the run loop, as a menu's action would run it: inside a task a modal panel would hold every other task on
    /// the main actor until it closed.
    private static func onRunLoop<T: Sendable>(_ body: @escaping @MainActor () -> T) async -> T {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform {
                MainActor.assumeIsolated { continuation.resume(returning: body()) }
            }
        }
    }

    private static func run(name: String, types: [UTType], directory: URL) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = defaultFileName(name: name, type: types.first)
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func runForPicture(name: String, output: ScreenshotOutput, directory: URL) -> (url: URL, output: ScreenshotOutput)? {
        let panel = NSSavePanel()
        let options = PictureSaveOptions(output: output)
        panel.allowedContentTypes = pictureTypes(preferring: output.format)
        panel.nameFieldStringValue = defaultFileName(name: name, type: output.format.type)
        panel.directoryURL = directory
        panel.canCreateDirectories = true
        // A format picked in the panel renames the file to match, and is the type the panel adds when none is typed.
        options.formatChanged = { [weak panel] format in
            guard let panel else { return }
            panel.allowedContentTypes = pictureTypes(preferring: format)
            panel.nameFieldStringValue = renamed(panel.nameFieldStringValue, to: format)
        }
        let accessory = PictureSaveOptionsView(options: options)
        accessory.setFrameSize(accessory.fittingSize)
        panel.accessoryView = accessory
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, chosenOutput(for: url, options: options.output))
    }

    /// The name the panel starts with: `name` and the extension of `type`. A screenshot's is the one every other way of
    /// saving it uses ("jpg", where the system's preferred extension for JPEG is "jpeg"); another kind of file takes
    /// the system's.
    nonisolated static func defaultFileName(name: String, type: UTType?) -> String {
        let format = ImageExporter.Format.allCases.first { $0.type == type }
        guard let fileExtension = format?.fileExtension ?? type?.preferredFilenameExtension else { return name }
        return "\(name).\(fileExtension)"
    }

    /// A name in the panel given `format`'s extension in place of a picture format's it has: "Shot.png" becomes
    /// "Shot.jpg". A name with no such extension (the person hid extensions, or typed a dot of their own) gains one.
    nonisolated static func renamed(_ name: String, to format: ImageExporter.Format) -> String {
        let stem = ImageExporter.Format(fileExtension: (name as NSString).pathExtension) == nil ? name : (name as NSString).deletingPathExtension
        return "\(stem).\(format.fileExtension)"
    }

    /// How a screenshot saved at `url` is written: as the panel's options say, in the format its name says if it says
    /// one (a name typed as `.jpg` while PNG was picked).
    nonisolated static func chosenOutput(for url: URL, options: ScreenshotOutput) -> ScreenshotOutput {
        options.with(format: ImageExporter.Format(fileExtension: url.pathExtension) ?? options.format)
    }

    /// The types a screenshot may be saved as, the format Settings choose first.
    public static func pictureTypes(preferring format: ImageExporter.Format) -> [UTType] {
        [format.type] + ImageExporter.Format.allCases.filter { $0 != format }.map(\.type)
    }
}

/// What the Save panel's options hold while it is up.
@MainActor
final class PictureSaveOptions {
    var output: ScreenshotOutput {
        didSet { if output.format != oldValue.format { formatChanged?(output.format) } }
    }

    var formatChanged: ((ImageExporter.Format) -> Void)?

    init(output: ScreenshotOutput) {
        self.output = output
    }
}

/// The Save panel's options for a screenshot: its format and quality, and what is done to the picture. The same
/// choices as Settings › Screenshots, for this file alone. AppKit controls, not SwiftUI: a SwiftUI picker in the
/// panel's accessory did not take a choice while the panel ran modally.
final class PictureSaveOptionsView: NSView {
    private let options: PictureSaveOptions
    private let format = NSPopUpButton()
    private let qualityLabel = NSTextField(labelWithString: String(localized: "Quality", bundle: .module))
    private let quality = NSSlider(value: ScreenshotOutput.standardQuality, minValue: ScreenshotOutput.qualities.lowerBound,
                                   maxValue: ScreenshotOutput.qualities.upperBound, target: nil, action: nil)
    private let qualityValue = NSTextField(labelWithString: "")
    private let lossless = NSTextField(labelWithString: String(localized: "Lossless", bundle: .module))
    private let retina = NSButton(checkboxWithTitle: String(localized: "Save Retina screenshots at 1×", bundle: .module), target: nil, action: nil)
    private let srgb = NSButton(checkboxWithTitle: String(localized: "Convert to sRGB", bundle: .module), target: nil, action: nil)
    private let border = NSButton(checkboxWithTitle: String(localized: "Add a 1 px border", bundle: .module), target: nil, action: nil)

    init(options: PictureSaveOptions) {
        self.options = options
        super.init(frame: .zero)

        for item in ImageExporter.Format.allCases {
            format.addItem(withTitle: item.title)
            format.lastItem?.representedObject = item.rawValue
        }
        format.setAccessibilityLabel(String(localized: "Format", bundle: .module))
        format.target = self
        format.action = #selector(formatChosen)
        quality.target = self
        quality.action = #selector(qualityMoved)
        quality.setAccessibilityLabel(String(localized: "Quality", bundle: .module))
        quality.widthAnchor.constraint(equalToConstant: 110).isActive = true
        qualityValue.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        qualityValue.alignment = .right
        qualityValue.widthAnchor.constraint(equalToConstant: 40).isActive = true
        for label in [qualityValue, lossless] { label.textColor = .secondaryLabelColor }
        for box in [retina, srgb, border] {
            box.target = self
            box.action = #selector(toggled)
        }

        // The slider's row and "Lossless" share a place, one hidden, so the panel keeps its size as the format changes.
        let slider = NSStackView(views: [qualityLabel, quality, qualityValue])
        slider.spacing = 8
        let place = NSView()
        for view in [slider, lossless] {
            view.translatesAutoresizingMaskIntoConstraints = false
            place.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: place.leadingAnchor),
                view.centerYAnchor.constraint(equalTo: place.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            place.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            place.heightAnchor.constraint(equalTo: slider.heightAnchor),
        ])
        let formatRow = NSStackView(views: [format, place])
        formatRow.spacing = 8
        let boxes = NSStackView(views: [retina, srgb, border])
        boxes.orientation = .vertical
        boxes.alignment = .leading
        boxes.spacing = 6

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Format:", bundle: .module)), formatRow],
            [NSTextField(labelWithString: String(localized: "Picture:", bundle: .module)), boxes],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 1).yPlacement = .top
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        show()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The controls as the options stand.
    private func show() {
        let output = options.output
        format.selectItem(at: ImageExporter.Format.allCases.firstIndex(of: output.format) ?? 0)
        quality.doubleValue = output.quality
        qualityValue.stringValue = output.quality.formatted(.percent.precision(.fractionLength(0)))
        quality.setAccessibilityValueDescription(qualityValue.stringValue)
        for view in [qualityLabel, quality, qualityValue] { view.isHidden = !output.isLossy }
        lossless.isHidden = output.isLossy
        retina.state = output.retinaAtOneX ? .on : .off
        srgb.state = output.convertsToSRGB ? .on : .off
        border.state = output.addsBorder ? .on : .off
    }

    @objc private func formatChosen() {
        let chosen = (format.selectedItem?.representedObject as? String).flatMap(ImageExporter.Format.init(rawValue:))
        if let chosen { options.output.format = chosen }
        show()
    }

    /// In steps of 5 percent, as Settings' slider.
    @objc private func qualityMoved() {
        options.output.quality = (quality.doubleValue * 20).rounded() / 20
        show()
    }

    @objc private func toggled() {
        options.output.retinaAtOneX = retina.state == .on
        options.output.convertsToSRGB = srgb.state == .on
        options.output.addsBorder = border.state == .on
        show()
    }
}
