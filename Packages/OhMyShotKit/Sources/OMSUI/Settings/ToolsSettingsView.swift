import Foundation
import OMSCore
import SwiftUI

/// Settings › Tools: Pick Color, Measure, and pins.
struct ToolsSettingsView: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        SettingsPane {
            SettingsRow(String(localized: "Copy colors as", bundle: .module), help: [
                HelpTopic(String(localized: "Copy colors as", bundle: .module), Text("For Pick Color, and C while capturing or measuring.", bundle: .module)),
                HelpTopic(String(localized: "Measure in", bundle: .module), Text("Tab switches between them while measuring.", bundle: .module)),
                HelpTopic(String(localized: "Snap selections to content", bundle: .module), Text("Fits a measurement box to the content inside it when you release the pointer. Turn off to keep the box as drawn, or hold Command while releasing to skip snapping once.", bundle: .module)),
                HelpTopic(String(localized: "Edge tolerance", bundle: .module), Text("Lower tolerance finds finer boundaries. Higher tolerance ignores small color changes. This affects ruler lines and selection snapping. While measuring, T cycles the presets and +/− adjusts them; the choice is remembered here.", bundle: .module)),
            ]) {
                Picker(selection: $settings.colorFormat) {
                    ForEach(ColorFormat.allCases, id: \.self) { format in
                        Text(verbatim: format.title).tag(format)
                    }
                } label: {
                    Text("Copy colors as", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(String(localized: "Measure in", bundle: .module)) {
                Picker(selection: $settings.measureUnit) {
                    Text("Points", bundle: .module).tag(MeasureUnit.points)
                    Text("Pixels", bundle: .module).tag(MeasureUnit.pixels)
                } label: {
                    Text("Measure in", bundle: .module)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow(String(localized: "Measurement snapping", bundle: .module)) {
                Toggle(isOn: $settings.measureSnapsToContent) {
                    Text("Snap selections to content", bundle: .module)
                }
            }
            SettingsRow(String(localized: "Edge tolerance", bundle: .module)) {
                Picker(selection: $settings.measureTolerance) {
                    ForEach(MeasureTolerance.allCases, id: \.self) { tolerance in
                        Text(verbatim: tolerance.title).tag(tolerance)
                    }
                } label: {
                    Text("Edge tolerance", bundle: .module)
                }
                .labelsHidden()
                .fixedSize()
            }

            SettingsDivider()

            SettingsRow(String(localized: "Pins", bundle: .module), help: [
                HelpTopic(String(localized: "Border", bundle: .module), Text("A hairline, so a white picture still reads against a white window.", bundle: .module)),
            ]) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Corners", bundle: .module)
                            .fixedSize()
                        // Rounded here rather than with `step:`, which hangs a row of tick marks under the
                        // slider and lifts it off the label's line.
                        Slider(
                            value: Binding(get: { settings.pinCornerRadius }, set: { settings.pinCornerRadius = $0.rounded() }),
                            in: SettingsStore.pinCornerRadii
                        ) {
                            Text("Corners", bundle: .module)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        Text("\(Int(settings.pinCornerRadius)) pt", bundle: .module)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .leading)
                    }
                    HStack(spacing: 14) {
                        Toggle(isOn: $settings.pinShadow) {
                            Text("Shadow", bundle: .module)
                        }
                        Toggle(isOn: $settings.pinBorder) {
                            Text("Border", bundle: .module)
                        }
                    }
                    Toggle(isOn: $settings.pinsAppearInCaptures) {
                        Text("Show in screenshots", bundle: .module)
                    }
                }
            }
        }
    }
}
