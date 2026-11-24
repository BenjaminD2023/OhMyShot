import Foundation
import OMSCore
import Testing
@testable import OMSUI

/// Copy Text in Capture History reads a screenshot's text; a recording has none to copy.
@MainActor
struct HistoryCopyTextTests {
    @Test func copyTextReadsScreenshotsOnly() async throws {
        let defaults = try #require(UserDefaults(suiteName: "OMSUITests-\(UUID().uuidString)"))
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryCopyTextTests-\(UUID().uuidString)"))
        var read: [UUID] = []
        var actions = HistoryActions(
            restore: { _ in }, copy: { _ in }, save: { _ in }, open: { _ in }, annotate: { _ in }, reveal: { _ in },
            recognizeText: { _ in }, pin: { _ in }, moveToTrash: { _ in }
        )
        // Overtaken, so nothing shows by the pointer.
        actions.copyText = { item in
            read.append(item.id)
            return .superseded
        }
        let model = HistoryModel(store: store, settings: SettingsStore(defaults: defaults), actions: actions)
        let screenshot = HistoryItem(kind: .screenshot, pixelWidth: 10, pixelHeight: 10, appName: nil, fileName: "0.png")
        let recording = HistoryItem(kind: .recording, pixelWidth: 10, pixelHeight: 10, appName: nil, fileName: "1.mov")
        model.items = [screenshot, recording]
        model.copyText(screenshot)
        model.copyText(recording)
        for _ in 0..<20 { await Task.yield() }
        #expect(read == [screenshot.id])
    }
}
