import Foundation
import OMSCore
import SwiftUI
import Testing
@testable import OMSUI

@MainActor
struct RetentionSelectionTests {
    private func withSettings(_ run: (SettingsStore) async throws -> Void) async throws {
        let suite = "RetentionSelectionTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.historyRetention = .oneWeek
        try await run(settings)
    }

    @Test func onlyTheNewestWindowCanPresentOrApplyItsChoice() async throws {
        try await withSettings { settings in
            let delayed = SuspendedPreview()
            let first = RetentionSelection(settings: settings, preview: delayed.read)
            let second = RetentionSelection(settings: settings) { _ in RetentionPreviewCounts(count: 3, favorites: 2) }
            first.binding.wrappedValue = .oneDay
            let oldScan = try #require(first.scan)
            await delayed.waitForStart()
            #expect(second.binding.wrappedValue == .oneDay)
            second.binding.wrappedValue = .never
            await second.scan?.value
            let newest = try #require(second.request)
            #expect(oldScan.isCancelled && first.request == nil)
            delayed.finish(expired: 0)
            await oldScan.value
            first.cancel()
            #expect(second.request?.id == newest.id)
            #expect(settings.historyRetention == .oneWeek)
            second.confirm(newest)
            #expect(settings.historyRetention == .never)
            #expect(second.request == nil)
        }
    }

    enum Interruption: CaseIterable { case chooseCurrent, close, changeSettingAndRestore }

    @Test(arguments: Interruption.allCases, [0, 2])
    func abandonedScansCannotPublishOrApply(_ interruption: Interruption, expired: Int) async throws {
        try await withSettings { settings in
            let delayed = SuspendedPreview()
            let pending = RetentionSelection(settings: settings, preview: delayed.read)
            let other = RetentionSelection(settings: settings) { _ in
                Issue.record("Returning to the current setting must not start another scan")
                return nil
            }
            pending.binding.wrappedValue = .never
            let scan = try #require(pending.scan)
            await delayed.waitForStart()
            switch interruption {
            case .chooseCurrent: other.binding.wrappedValue = .oneWeek
            case .close: pending.cancel()
            case .changeSettingAndRestore:
                settings.historyRetention = .oneMonth
                settings.historyRetention = .oneWeek
            }
            #expect(scan.isCancelled)
            delayed.finish(expired: expired)
            await scan.value
            #expect(pending.request == nil && other.request == nil)
            #expect(pending.binding.wrappedValue == .oneWeek)
            #expect(settings.historyRetention == .oneWeek)
        }
    }

    @Test func oldDialogActionsCannotConfirmOrDismissANewRequestForTheSameRetention() async throws {
        try await withSettings { settings in
            let selection = RetentionSelection(settings: settings) { _ in RetentionPreviewCounts(count: 4, favorites: 1) }
            selection.binding.wrappedValue = .never
            await selection.scan?.value
            let old = try #require(selection.request)
            selection.binding.wrappedValue = .never
            await selection.scan?.value
            let current = try #require(selection.request)
            #expect(current.id != old.id)
            selection.dismiss(old)
            selection.confirm(old)
            #expect(settings.historyRetention == .oneWeek && selection.request?.id == current.id)
            selection.dismiss(current)
            selection.confirm(current)
            #expect(settings.historyRetention == .oneWeek && selection.request == nil)
        }
    }

    @Test func aSettingWriteWithdrawsAPresentedDestructiveConfirmation() async throws {
        try await withSettings { settings in
            let selection = RetentionSelection(settings: settings) { _ in RetentionPreviewCounts(count: 2, favorites: 1) }
            selection.binding.wrappedValue = .never
            await selection.scan?.value
            let old = try #require(selection.request)
            settings.historyRetention = .oneMonth
            #expect(selection.request == nil)
            selection.confirm(old)
            #expect(settings.historyRetention == .oneMonth)
        }
    }

    @Test func onlyASuccessfulZeroAppliesWithoutConfirmation() async throws {
        try await withSettings { settings in
            let selection = RetentionSelection(settings: settings) { retention in
                retention == .oneMonth ? RetentionPreviewCounts(count: 0, favorites: 0) : nil
            }
            selection.binding.wrappedValue = .never
            await selection.scan?.value
            #expect(settings.historyRetention == .oneWeek && selection.request == nil)
            selection.select(.oneMonth, previewOnly: true)
            await selection.scan?.value
            #expect(settings.historyRetention == .oneWeek && selection.request?.count == 0)
            selection.cancel()
            selection.binding.wrappedValue = .oneMonth
            await selection.scan?.value
            #expect(settings.historyRetention == .oneMonth && selection.request == nil)
        }
    }

    private final class SuspendedPreview {
        private var started: CheckedContinuation<Void, Never>?
        private var result: CheckedContinuation<RetentionPreviewCounts?, Never>?

        func read(_ retention: HistoryRetention) async -> RetentionPreviewCounts? {
            await withCheckedContinuation { continuation in
                result = continuation
                started?.resume()
                started = nil
            }
        }

        func waitForStart() async {
            if result != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func finish(expired: Int) {
            result?.resume(returning: RetentionPreviewCounts(count: expired, favorites: 0))
            result = nil
        }
    }
}
