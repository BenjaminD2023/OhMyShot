import AppKit
import SwiftUI

/// What the Image Size sheet shows and changes: the size asked for, measured against the canvas as it is now.
@MainActor
@Observable
final class ImageSizeModel {
    var sizing: ImageSizing
    /// Whether a picture can be this size; false past what can be drawn and kept.
    private(set) var allowed = true
    /// Whether the active text field currently holds a valid positive number.
    private(set) var hasValidInput = true
    var widthText: String
    var heightText: String
    var scaleText: String
    @ObservationIgnored private let document: AnnotationDocument

    init(document: AnnotationDocument) {
        self.document = document
        let initial = ImageSizing(current: document.canvas.standardized.size)
        sizing = initial
        widthText = "\(initial.width)"
        heightText = "\(initial.height)"
        scaleText = ImageSizing.formatPercent(initial.percent)
    }

    /// Whether the capture is Retina (2× or higher), where 50% scales down to 1×.
    var isRetina: Bool { document.scale >= 2 }

    /// The size can be asked for: it is a valid change, and a picture can have it.
    var canResize: Bool { sizing.changesSize && allowed && hasValidInput }

    func setWidth(_ value: Int) {
        sizing.setWidth(value)
        hasValidInput = true
        refresh()
        syncAllText()
    }

    func setHeight(_ value: Int) {
        sizing.setHeight(value)
        hasValidInput = true
        refresh()
        syncAllText()
    }

    func setPercent(_ value: Double) {
        sizing.setPercent(value)
        hasValidInput = true
        refresh()
        syncAllText()
    }

    func setKeepsProportions(_ value: Bool) {
        sizing.keepsProportions = value
        // Turned on, the height follows the width it is set against.
        if value { sizing.setWidth(sizing.width) }
        hasValidInput = true
        refresh()
        syncAllText()
    }

    /// Parses Width as the user types, updating Height, Scale, and `canResize` live.
    func updateWidthText(_ text: String) {
        widthText = text
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), value > 0 else {
            hasValidInput = false
            allowed = true
            return
        }
        sizing.setWidth(value)
        hasValidInput = true
        allowed = value <= AnnotationDocument.maxPictureSide && document.allowsCanvas(of: sizing.size)
        heightText = "\(sizing.height)"
        scaleText = ImageSizing.formatPercent(sizing.percent)
    }

    /// Parses Height as the user types, updating Width, Scale, and `canResize` live.
    func updateHeightText(_ text: String) {
        heightText = text
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), value > 0 else {
            hasValidInput = false
            allowed = true
            return
        }
        sizing.setHeight(value)
        hasValidInput = true
        allowed = value <= AnnotationDocument.maxPictureSide && document.allowsCanvas(of: sizing.size)
        widthText = "\(sizing.width)"
        scaleText = ImageSizing.formatPercent(sizing.percent)
    }

    /// Parses Scale percentage as the user types, updating Width, Height, and `canResize` live.
    func updateScaleText(_ text: String) {
        scaleText = text
        guard let value = Self.parsePositiveDecimal(text) else {
            hasValidInput = false
            allowed = true
            return
        }
        sizing.setPercent(value)
        hasValidInput = true
        let factor = value / 100
        let rawWidth = Double(sizing.current.width) * factor
        let rawHeight = Double(sizing.current.height) * factor
        allowed = rawWidth <= Double(AnnotationDocument.maxPictureSide)
            && rawHeight <= Double(AnnotationDocument.maxPictureSide)
            && document.allowsCanvas(of: sizing.size)
        widthText = "\(sizing.width)"
        heightText = "\(sizing.height)"
    }

    private func syncAllText() {
        widthText = "\(sizing.width)"
        heightText = "\(sizing.height)"
        scaleText = ImageSizing.formatPercent(sizing.percent)
    }

    private func refresh() {
        allowed = document.allowsCanvas(of: sizing.size)
    }

    private static func parsePositiveDecimal(_ text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") { trimmed.removeLast() }
        trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let value = Double(trimmed), value.isFinite, value > 0 { return value }
        if let decimal = Locale.current.decimalSeparator, decimal != "." {
            let normalized = trimmed.replacingOccurrences(of: decimal, with: ".")
            if let value = Double(normalized), value.isFinite, value > 0 { return value }
        }
        return nil
    }
}

/// Image Size…: a sheet on the editor with quick scale presets, width and height in pixels, or a percent of the size now.
struct ImageSizeView: View {
    @Bindable var model: ImageSizeModel
    var resize: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent {
                        HStack(spacing: 6) {
                            presetChip(model.isRetina ? String(localized: "50% (1×)", bundle: .module) : "50%", percent: 50)
                            presetChip("75%", percent: 75)
                            presetChip("200%", percent: 200)
                        }
                    } label: {
                        Text("Presets", bundle: .module)
                    }
                    field(
                        Text("Width", bundle: .module),
                        unit: Text("px", bundle: .module),
                        text: Binding(get: { model.widthText }, set: { model.updateWidthText($0) })
                    )
                    field(
                        Text("Height", bundle: .module),
                        unit: Text("px", bundle: .module),
                        text: Binding(get: { model.heightText }, set: { model.updateHeightText($0) })
                    )
                    field(
                        Text("Scale", bundle: .module),
                        unit: Text("%", bundle: .module),
                        text: Binding(get: { model.scaleText }, set: { model.updateScaleText($0) })
                    )
                    Toggle(isOn: Binding(get: { model.sizing.keepsProportions }, set: { model.setKeepsProportions($0) })) {
                        Text("Keep proportions", bundle: .module)
                    }
                } footer: {
                    Group {
                        if !model.allowed {
                            Text("A picture can’t be this large.", bundle: .module)
                                .foregroundStyle(.red)
                        } else if !model.hasValidInput {
                            Text("Enter a positive number.", bundle: .module)
                        } else {
                            Text("Now \(Int(model.sizing.current.width)) × \(Int(model.sizing.current.height)) px. The marks scale with the picture.", bundle: .module)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .onSubmit { if model.canResize { resize() } }
            HStack {
                Spacer()
                Button(role: .cancel, action: cancel) {
                    Text("Cancel", bundle: .module)
                }
                .keyboardShortcut(.cancelAction)
                Button(action: resize) {
                    Text("Resize", bundle: .module)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canResize)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func presetChip(_ title: String, percent: Double) -> some View {
        let selected = model.hasValidInput && abs(model.sizing.percent - percent) < 0.01
        return Button {
            model.setPercent(percent)
        } label: {
            Text(verbatim: title)
                .monospacedDigit()
                .fontWeight(selected ? .semibold : .regular)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func field(_ name: Text, unit: Text, text: Binding<String>) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(text: text) {
                    name
                }
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 86)
                unit
                    .foregroundStyle(.secondary)
            }
        } label: {
            name
        }
    }
}
