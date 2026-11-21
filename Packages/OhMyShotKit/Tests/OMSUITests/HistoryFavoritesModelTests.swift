import AppKit
import Foundation
import OMSCore
import SwiftUI
import Testing
@testable import OMSUI

/// Favorites in Capture History's window: adding and taking out, the Favorites filter, and History off.
@MainActor
struct HistoryFavoritesModelTests {
    private func model(retention: HistoryRetention = .oneWeek, count: Int) throws -> (HistoryModel, [HistoryItem]) {
        let defaults = try #require(UserDefaults(suiteName: "OMSUITests-\(UUID().uuidString)"))
        let settings = SettingsStore(defaults: defaults)
        settings.historyRetention = retention
        let store = HistoryStore(directory: FileManager.default.temporaryDirectory.appending(path: "HistoryFavoritesModelTests-\(UUID().uuidString)"))
        let actions = HistoryActions(
            restore: { _ in }, copy: { _ in }, save: { _ in }, open: { _ in }, annotate: { _ in }, reveal: { _ in },
            recognizeText: { _ in }, pin: { _ in }, moveToTrash: { _ in }
        )
        let model = HistoryModel(store: store, settings: settings, actions: actions, expiredCount: { _ in 0 })
        let items = try (0..<count).map { _ in
            try store.add(data: Data([1]), fileExtension: "png", kind: .screenshot, pixelWidth: 1, pixelHeight: 1, appName: nil)
        }
        model.items = items
        return (model, items)
    }

    /// As in Photos: added unless every one is a favorite already, then taken out.
    @Test func theStarGoesOnUnlessEveryCaptureHasItThenComesOff() throws {
        let (model, items) = try model(count: 3)
        model.toggleFavorite([items[0]])
        let first = model.items.filter { $0.isFavorite }.map(\.id)
        #expect(first == [items[0].id])
        model.toggleFavorite(model.items)
        let all = model.items.allSatisfy { $0.isFavorite }, written = model.store.items().allSatisfy { $0.isFavorite }
        #expect(all && written)
        model.toggleFavorite(model.items)
        let none = !model.items.contains { $0.isFavorite }
        #expect(none)
    }

    @Test func theFavoritesFilterShowsOnlyFavorites() throws {
        let (model, items) = try model(count: 3)
        model.toggleFavorite([items[1]])
        model.filter = .favorites
        #expect(model.visibleItems.map(\.id) == [items[1].id])
        #expect(!model.showsEverything)
    }

    /// With History off nothing can be kept, so nothing is starred.
    @Test func historyOffStarsNothing() throws {
        let (model, items) = try model(retention: .never, count: 1)
        #expect(!model.canFavorite)
        model.toggleFavorite(items)
        #expect(!model.items[0].isFavorite)
        #expect(model.store.item(id: items[0].id)?.isFavorite == false)
    }

    /// Turning History off deletes the favorites with the rest, and the confirmation it asks for knows how many.
    @Test func turningHistoryOffCountsTheFavoritesItDeletes() throws {
        let defaults = try #require(UserDefaults(suiteName: "OMSUITests-\(UUID().uuidString)"))
        let settings = SettingsStore(defaults: defaults)
        settings.historyRetention = .oneWeek
        let asked = Asked()
        let retention = retentionSelection(
            settings: settings, expiredCount: { $0 == .never ? 5 : 0 }, expiredFavoriteCount: { $0 == .never ? 2 : 0 },
            request: Binding(get: { asked.request }, set: { asked.request = $0 })
        )
        retention.wrappedValue = .never
        #expect(asked.request?.count == 5)
        #expect(asked.request?.favorites == 2)
        #expect(settings.historyRetention == .oneWeek)
    }

    /// Starring changes neither the picture nor its text: the card keeps its thumbnail.
    @Test func starringKeepsTheThumbnail() throws {
        let (model, items) = try model(count: 1)
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        model.thumbnails[items[0].id] = context.makeImage()
        model.toggleFavorite(items)
        #expect(model.thumbnails[items[0].id] != nil)
    }

    /// Move All to Trash takes favorites with the rest, and its question counts them.
    @Test func theTrashQuestionCountsTheFavorites() throws {
        let (model, items) = try model(count: 3)
        model.toggleFavorite(Array(items.prefix(2)))
        let request = TrashRequest(items: model.items, isEverything: true)
        #expect(request.items.count == 3)
        #expect(request.favoriteCount == 2)
    }
}

@MainActor
private final class Asked {
    var request: RetentionChangeRequest?
}
