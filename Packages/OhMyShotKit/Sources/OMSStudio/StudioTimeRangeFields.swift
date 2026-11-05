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
                Text("Enter a time such as 0:12.50.", bundle: .module)
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
        let text = field == .start ? startText : endText
        // Text left as shown moves nothing, though it shows the time to the hundredth only.
        if text == StudioTimeInput.format(field == .start ? start : end) {
            invalid = false
            return
        }
        guard let time = StudioTimeInput.parse(text) else {
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

    /// A time as the inspector's fields show it, to the nearest hundredth: 0:12.35, 1:02:09.40.
    static func format(_ time: Double) -> String {
        clock(time, rounding: .toNearestOrAwayFromZero)
    }

    /// A time in Studio's one clock, to the hundredth of a second, `rounding` the way its place asks (the
    /// transport never shows a time not yet reached): 0:12.35, 1:02:09.40.
    static func clock(_ time: Double, rounding: FloatingPointRoundingRule) -> String {
        guard time.isFinite, time >= 0, time < Double(Int.max / 100) else { return "0:00.00" }
        let hundredths = Int((time * 100).rounded(rounding))
        let hours = hundredths / 360_000
        let minutes = hundredths / 6_000 % 60
        let seconds = hundredths / 100 % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d.%02d", hours, minutes, seconds, hundredths % 100)
            : String(format: "%d:%02d.%02d", minutes, seconds, hundredths % 100)
    }

    /// A tick's label on the ruler: the clock without the zeros a round step leaves at its end (0:01, 0:00.5).
    static func tick(_ time: Double) -> String {
        var text = clock(time, rounding: .toNearestOrAwayFromZero)
        while text.hasSuffix("0"), text.contains(".") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
