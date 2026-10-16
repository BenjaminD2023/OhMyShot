import AppKit
import SwiftUI

/// What the Image Size sheet shows and changes: the size asked for, measured against the canvas as it is now.
@MainActor
@Observable
final class ImageSizeModel {
    var sizing: ImageSizing
    /// Whether a picture can be this size; false past what can be drawn and kept.
    private(set) var allowed = true
    @ObservationIgnored private let document: AnnotationDocument

    init(document: AnnotationDocument) {
        self.document = document
        sizing = ImageSizing(current: document.canvas.standardized.size)
    }

    /// The size can be asked for: it is a change, and a picture can have it.
    var canResize: Bool { sizing.changesSize && allowed }

    func setWidth(_ value: Int) {
        sizing.setWidth(value)
        refresh()
    }

    func setHeight(_ value: Int) {
        sizing.setHeight(value)
        refresh()
    }

    func setPercent(_ value: Double) {
        sizing.setPercent(value)
        refresh()
    }

    func setKeepsProportions(_ value: Bool) {
        sizing.keepsProportions = value
        // Turned on, the height follows the width it is set against.
        if value { sizing.setWidth(sizing.width) }
        refresh()
    }

    private func refresh() {
        allowed = document.allowsCanvas(of: sizing.size)
    }
}

/// Image Size…: a sheet on the editor with the width and height in pixels, or a percent of the size now.
struct ImageSizeView: View {
    @Bindable var model: ImageSizeModel
    var resize: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    field(Text("Width", bundle: .module), unit: Text("px", bundle: .module), value: Binding(get: { model.sizing.width }, set: { model.setWidth($0) }))
                    field(Text("Height", bundle: .module), unit: Text("px", bundle: .module), value: Binding(get: { model.sizing.height }, set: { model.setHeight($0) }))
                    LabeledContent {
                        HStack(spacing: 6) {
                            TextField(value: Binding(get: { model.sizing.percent }, set: { model.setPercent($0) }), format: .number.precision(.fractionLength(0...2)).grouping(.never)) {
                                Text("Scale", bundle: .module)
                            }
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 86)
                            Text("%", bundle: .module)
                                .foregroundStyle(.secondary)
                        }
                    } label: {
                        Text("Scale", bundle: .module)
                    }
                    Toggle(isOn: Binding(get: { model.sizing.keepsProportions }, set: { model.setKeepsProportions($0) })) {
                        Text("Keep proportions", bundle: .module)
                    }
                } footer: {
                    Group {
                        if model.allowed {
                            Text("Now \(Int(model.sizing.current.width)) × \(Int(model.sizing.current.height)) px. The marks scale with the picture.", bundle: .module)
                        } else {
                            Text("A picture can’t be this large.", bundle: .module)
                                .foregroundStyle(.red)
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
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ name: Text, unit: Text, value: Binding<Int>) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField(value: value, format: .number.grouping(.never)) {
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
