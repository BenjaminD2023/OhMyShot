import Foundation
import Testing
@testable import OMSAnnotate

@MainActor
struct SavedColorsTests {
    private let scratch = ScratchDefaults()

    private func makeDefaults() -> UserDefaults {
        scratch.make()
    }

    /// A color already on the 8-bit steps colors are kept at, so it compares equal to what was kept.
    private func color(_ index: Int) -> RGBA {
        RGBA(red: Double(index * 16) / 255, green: 128.0 / 255, blue: 64.0 / 255)
    }

    @Test func aColorIsKeptOnceAndWithoutItsTransparency() {
        let saved = SavedColors(defaults: makeDefaults())
        #expect(saved.add(RGBA(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)))
        #expect(saved.colors == [RGBA(red: 0.2, green: 0.4, blue: 0.6)])
        // The same color again, from a color panel that reports it a hair differently.
        #expect(!saved.add(RGBA(red: 0.2000001, green: 0.4, blue: 0.6)))
        #expect(saved.contains(RGBA(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.3)))
        #expect(saved.colors.count == 1)
    }

    @Test func atMostEightAreKeptAndARemovedOneMakesRoom() {
        let saved = SavedColors(defaults: makeDefaults())
        for index in 0..<SavedColors.limit { #expect(saved.add(color(index))) }
        #expect(SavedColors.limit == 8 && saved.isFull)
        #expect(!saved.add(color(9)))
        #expect(saved.colors.count == 8 && !saved.contains(color(9)))
        saved.remove(color(3))
        #expect(!saved.isFull && !saved.contains(color(3)))
        #expect(saved.add(color(9)))
        // In the order they were saved, the new one last.
        #expect(saved.colors.last == color(9) && saved.colors.first == color(0))
    }

    @Test func removingAColorThatIsNotKeptDoesNothing() {
        let saved = SavedColors(defaults: makeDefaults())
        saved.add(color(1))
        saved.remove(color(2))
        #expect(saved.colors == [color(1)])
    }

    @Test func theColorsComeBackInTheNextEditor() {
        let defaults = makeDefaults()
        let first = SavedColors(defaults: defaults)
        first.add(color(1))
        first.add(color(2))
        first.remove(color(1))
        let next = SavedColors(defaults: defaults)
        #expect(next.colors == [color(2)])
    }

    @Test func storedPaletteIsTrimmedToTheLimitWithoutRepeats() throws {
        let defaults = makeDefaults()
        let crowded = (0..<12).map { color($0 % 10) }
        defaults.set(try JSONEncoder().encode(crowded), forKey: "annotation.savedColors")
        let saved = SavedColors(defaults: defaults)
        #expect(saved.colors.count == 8)
        #expect(Set(saved.colors).count == 8)
        // Unreadable data is an empty palette, not a failure.
        defaults.set(Data("nope".utf8), forKey: "annotation.savedColors")
        #expect(SavedColors(defaults: defaults).colors.isEmpty)
    }

    @Test func everyEditorIsToldWhenTheColorsChange() {
        nonisolated final class Count: @unchecked Sendable {
            var value = 0
        }
        let saved = SavedColors(defaults: makeDefaults())
        let heard = Count()
        let observer = NotificationCenter.default.addObserver(forName: SavedColors.didChange, object: saved, queue: nil) { _ in heard.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        saved.add(color(1))
        saved.add(color(1))
        saved.remove(color(1))
        saved.remove(color(1))
        #expect(heard.value == 2)
    }
}
