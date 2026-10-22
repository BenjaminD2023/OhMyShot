import OMSCore
import SwiftUI

/// Captures to move to the Trash, waiting for the user to confirm it: more than one selected, or every capture the
/// window shows.
struct TrashRequest: Identifiable {
    let id = UUID()
    let items: [HistoryItem]
    /// Every capture in the history, nothing left out by the Show filter or a search.
    let isEverything: Bool
}

extension View {
    /// Asks before captures leave the history. Moving one capture with its button, its menu, or ⌘⌫ never asks, as in
    /// Finder.
    func confirmingTrash(_ request: Binding<TrashRequest?>, apply: @escaping ([HistoryItem]) -> Void) -> some View {
        confirmationDialog(
            Self.trashTitle(request.wrappedValue),
            isPresented: Binding(get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } }),
            presenting: request.wrappedValue
        ) { request in
            Button(role: .destructive) {
                apply(request.items)
            } label: {
                Text("Move to Trash", bundle: .module)
            }
        } message: { _ in
            // The Trash keeps the files, but what made them captures (the record, the marks, the text) goes now.
            Text("They leave Capture History with their marks and text, and putting them back from the Trash doesn't bring them back here. Copies you saved elsewhere are not affected.", bundle: .module)
        }
    }

    private static func trashTitle(_ request: TrashRequest?) -> Text {
        guard let request else { return Text(verbatim: "") }
        return request.isEverything
            ? Text("Move All ^[\(request.items.count) Capture](inflect: true) to the Trash?", bundle: .module)
            : Text("Move ^[\(request.items.count) Capture](inflect: true) to the Trash?", bundle: .module)
    }
}
