import OMSCore
import SwiftUI

/// A retention change that would delete captures, waiting for the user to confirm it.
struct RetentionChangeRequest: Identifiable {
    let retention: HistoryRetention
    /// How many captures it would delete now.
    let count: Int

    var id: String { retention.rawValue }
}

extension View {
    /// Asks before a new retention deletes captures. Changes that delete nothing never reach here; see
    /// `retentionSelection`.
    func confirmingRetentionChange(_ request: Binding<RetentionChangeRequest?>, apply: @escaping (HistoryRetention) -> Void) -> some View {
        confirmationDialog(
            Self.retentionTitle(request.wrappedValue),
            isPresented: Binding(get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } }),
            presenting: request.wrappedValue
        ) { change in
            Button(role: .destructive) {
                apply(change.retention)
            } label: {
                Text("Delete ^[\(change.count) Capture](inflect: true)", bundle: .module)
            }
        } message: { change in
            if change.retention == .never {
                Text("From now on, a capture is deleted when its Quick Access card closes, unless you saved it. This can't be undone.", bundle: .module)
            } else {
                Text("Captures older than \(change.retention.title.lowercased()) are deleted now. This can't be undone.", bundle: .module)
            }
        }
    }

    private static func retentionTitle(_ change: RetentionChangeRequest?) -> Text {
        guard let change else { return Text(verbatim: "") }
        return change.retention == .never
            ? Text("Turn off Capture History?", bundle: .module)
            : Text("Keep captures for \(change.retention.title.lowercased())?", bundle: .module)
    }
}

/// A binding for a retention picker: a choice that deletes nothing applies at once; one that would
/// delete captures becomes a request to confirm.
@MainActor
func retentionSelection(
    settings: SettingsStore,
    expiredCount: @escaping (HistoryRetention) -> Int,
    request: Binding<RetentionChangeRequest?>
) -> Binding<HistoryRetention> {
    Binding {
        settings.historyRetention
    } set: { retention in
        guard retention != settings.historyRetention else { return }
        let count = expiredCount(retention)
        if count > 0 {
            request.wrappedValue = RetentionChangeRequest(retention: retention, count: count)
        } else {
            settings.historyRetention = retention
        }
    }
}
