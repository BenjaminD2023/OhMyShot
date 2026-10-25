import Foundation
import SwiftUI

/// Commit on Return or focus change, so partially typed times never move an edit unexpectedly.
struct StudioTimeRangeFields: View {
    let start: Double
    let end: Double
    /// Returns the effective range after the document applies its limits, so clamped input reads correctly.
    let change: (Double, Bool) -> ClosedRange<Double>
    @State private var startText = ""
    @State private var endText = ""
    @State private var invalid = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case start, end }

    var body: some View {
        VStack(spacing: 6) {
            LabeledContent {
                TextField(text: $startText) { Text("Start time", bundle: .module) }
                    .labelsHidden()
                    .focused($focused, equals: .start)
                    .onSubmit { commit(.start); focused = nil }
                    .accessibilityLabel(Text("Start time", bundle: .module))
                    .accessibilityIdentifier("studio-start-time")
            } label: { Text("Start", bundle: .module) }
            LabeledContent {
                TextField(text: $endText) { Text("End time", bundle: .module) }
                    .labelsHidden()
                    .focused($focused, equals: .end)
                    .onSubmit { commit(.end); focused = nil }
                    .accessibilityLabel(Text("End time", bundle: .module))
                    .accessibilityIdentifier("studio-end-time")
            } label: { Text("End", bundle: .module) }
            LabeledContent {
                Text(verbatim: StudioTimeInput.format(max(0, end - start)))
                    .foregroundStyle(.secondary)
            } label: { Text("Duration", bundle: .module) }
            if invalid {
                Text("Enter a time such as 0:12.500.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .textFieldStyle(.roundedBorder)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
        .onAppear { refresh() }
        .onChange(of: start) { _, _ in refresh() }
        .onChange(of: end) { _, _ in refresh() }
        .onChange(of: focused) { before, _ in
            if let before { commit(before) }
        }
    }

    private func refresh() {
        startText = StudioTimeInput.format(start)
        endText = StudioTimeInput.format(end)
    }

    private func commit(_ field: Field) {
        guard let time = StudioTimeInput.parse(field == .start ? startText : endText) else {
            invalid = true
            return
        }
        invalid = false
        if time != (field == .start ? start : end) {
            let effective = change(time, field == .start)
            startText = StudioTimeInput.format(effective.lowerBound)
            endText = StudioTimeInput.format(effective.upperBound)
        } else {
            refresh()
        }
    }
}

nonisolated enum StudioTimeInput {
    static func parse(_ text: String) -> Double? {
        let pieces = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return nil }
        var result = 0.0
        for (index, piece) in pieces.enumerated() {
            guard let value = Double(piece), value.isFinite, value >= 0 else { return nil }
            if index > 0 && value >= 60 { return nil }
            if index < pieces.count - 1 && value.rounded(.down) != value { return nil }
            result = result * 60 + value
        }
        return result.isFinite ? result : nil
    }

    static func format(_ time: Double) -> String {
        guard time.isFinite, time >= 0, time < Double(Int.max / 1_000) else { return "0:00.000" }
        let milliseconds = Int((time * 1_000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let seconds = milliseconds / 1_000 % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds % 1_000)
            : String(format: "%d:%02d.%03d", minutes, seconds, milliseconds % 1_000)
    }
}
