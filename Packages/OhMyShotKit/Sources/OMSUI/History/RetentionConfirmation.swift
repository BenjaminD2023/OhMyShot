import Foundation
import Observation
import OMSCore
import SwiftUI

public typealias RetentionPreview = @MainActor (HistoryRetention) async -> RetentionPreviewCounts?

/// A retention change that would delete captures, waiting for the user to confirm it.
struct RetentionChangeRequest: Identifiable {
    let id = UUID()
    let retention: HistoryRetention
    /// How many captures it would delete now.
    let count: Int
    /// How many of them are favorites, which only turning History off deletes.
    let favorites: Int
}

@MainActor
@Observable
final class RetentionSelection: HistoryRetentionProposal {
    private let settings: SettingsStore
    private let preview: RetentionPreview
    private(set) var counting: HistoryRetention?
    private(set) var request: RetentionChangeRequest?
    @ObservationIgnored private(set) var scan: Task<Void, Never>?

    init(settings: SettingsStore, preview: @escaping RetentionPreview) {
        self.settings = settings
        self.preview = preview
    }

    isolated deinit { scan?.cancel() }

    var binding: Binding<HistoryRetention> {
        Binding(get: { self.settings.retentionProposal?.counting ?? self.settings.historyRetention }, set: { self.select($0) })
    }

    func select(_ retention: HistoryRetention, previewOnly: Bool = false) {
        guard previewOnly || retention != settings.historyRetention else {
            settings.replaceRetentionProposal(with: nil)
            return
        }
        settings.replaceRetentionProposal(with: self)
        counting = retention
        scan = Task { [weak self, preview] in
            guard !Task.isCancelled else { return }
            let counts = await preview(retention)
            guard let self, !Task.isCancelled else { return }
            scan = nil
            counting = nil
            guard let counts else { return }
            if counts.count > 0 || previewOnly {
                request = RetentionChangeRequest(retention: retention, count: counts.count, favorites: counts.favorites)
            } else {
                settings.historyRetention = retention
            }
        }
    }

    func confirm(_ change: RetentionChangeRequest) {
        guard request?.id == change.id else { return }
        settings.historyRetention = change.retention
    }

    func dismiss(_ change: RetentionChangeRequest) {
        guard request?.id == change.id else { return }
        cancel()
    }

    func cancel() {
        scan?.cancel()
        scan = nil
        counting = nil
        request = nil
    }
}

extension View {
    /// Asks before a new retention deletes captures. Changes that delete nothing never reach here.
    func confirmingRetentionChange(_ selection: RetentionSelection) -> some View {
        let request = selection.request
        return confirmationDialog(
            Self.retentionTitle(request),
            isPresented: Binding(get: { selection.request != nil }, set: { presented in
                if !presented, let request { selection.dismiss(request) }
            }),
            presenting: request
        ) { change in
            Button(role: .destructive) {
                selection.confirm(change)
            } label: {
                Text("Delete ^[\(change.count) Capture](inflect: true)", bundle: .module)
            }
        } message: { change in
            if change.retention == .never, change.favorites > 0 {
                Text("From now on, a capture is deleted when its Quick Access card closes, unless you saved it. Your \(change.favorites) favorites are deleted too. This can’t be undone.", bundle: .module)
            } else if change.retention == .never {
                Text("From now on, a capture is deleted when its Quick Access card closes, unless you saved it. This can’t be undone.", bundle: .module)
            } else {
                Text("Captures older than \(change.retention.duration) are deleted now. This can’t be undone.", bundle: .module)
            }
        }
    }

    private static func retentionTitle(_ change: RetentionChangeRequest?) -> Text {
        guard let change else { return Text(verbatim: "") }
        return change.retention == .never
            ? Text("Turn off Capture History?", bundle: .module)
            : Text("Keep captures for \(change.retention.duration)?", bundle: .module)
    }
}

extension HistoryRetention {
    var title: String {
        switch self {
        case .never: String(localized: "Never", bundle: .module)
        case .oneDay: String(localized: "1 Day", bundle: .module)
        case .threeDays: String(localized: "3 Days", bundle: .module)
        case .oneWeek: String(localized: "1 Week", bundle: .module)
        case .oneMonth: String(localized: "1 Month", bundle: .module)
        }
    }

    /// The retention as it reads inside a sentence, in the system's own words for the language: "1 day", "3 jours",
    /// "1周"… Never a title lowercased, which only some languages write that way. Empty for `never`.
    var duration: String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        let parts = switch self {
        case .never: DateComponents()
        case .oneDay: DateComponents(day: 1)
        case .threeDays: DateComponents(day: 3)
        case .oneWeek: DateComponents(weekOfMonth: 1)
        case .oneMonth: DateComponents(month: 1)
        }
        formatter.allowedUnits = [.day, .weekOfMonth, .month]
        return self == .never ? "" : formatter.string(from: parts) ?? title
    }
}
