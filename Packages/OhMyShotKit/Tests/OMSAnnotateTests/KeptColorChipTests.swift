import AppKit
import Foundation
import Testing
@testable import OMSAnnotate

/// The kept-color chips in the style capsule, pressed directly: nothing is shown on screen.
@MainActor
struct KeptColorChipTests {
    private let scratch = ScratchDefaults()

    /// On the 8-bit steps colors are kept at.
    private let kept = RGBA(red: 32.0 / 255, green: 64.0 / 255, blue: 128.0 / 255)

    private func makeCapsule(keeping colors: [RGBA] = []) -> StyleCapsule {
        let saved = SavedColors(defaults: scratch.make())
        for color in colors { saved.add(color) }
        let capsule = StyleCapsule()
        capsule.savedColors = saved
        return capsule
    }

    private func chips(in capsule: StyleCapsule, labeled label: String) -> [CapsuleChip] {
        func walk(_ view: NSView) -> [CapsuleChip] {
            (view as? CapsuleChip).map { [$0] } ?? view.subviews.flatMap(walk)
        }
        return walk(capsule).filter { $0.accessibilityLabel() == label }
    }

    @Test func aColorOfOneIsKeptFromItsPlusChip() throws {
        let capsule = makeCapsule()
        var settings = ToolSettings.defaults(for: .arrow)
        settings.color = RGBA(red: 0.31, green: 0.42, blue: 0.53)
        capsule.show(kind: .arrow, settings: settings, hasSelection: false)
        let plus = try #require(chips(in: capsule, labeled: "Save Color").first)
        #expect(plus.isEnabled)
        plus.performClick(nil)
        #expect(capsule.savedColors.colors == [SavedColors.stored(settings.color)])
    }

    @Test func aFullRowKeepsNoMoreFromADimmedPlusChip() throws {
        let capsule = makeCapsule(keeping: (0..<SavedColors.limit).map { RGBA(red: Double($0 * 16) / 255, green: 0.5, blue: 0.25) })
        var settings = ToolSettings.defaults(for: .arrow)
        settings.color = RGBA(red: 0.31, green: 0.42, blue: 0.53)
        capsule.show(kind: .arrow, settings: settings, hasSelection: false)
        let plus = try #require(chips(in: capsule, labeled: "Save Color").first)
        #expect(!plus.isEnabled && plus.toolTip == "Remove a saved color to make room.")
        plus.performClick(nil)
        #expect(capsule.savedColors.colors.count == SavedColors.limit)
    }

    @Test func aKeptColorIsChosenAgainWithOneClick() throws {
        let capsule = makeCapsule(keeping: [kept])
        var settings = ToolSettings.defaults(for: .arrow)
        capsule.show(kind: .arrow, settings: settings, hasSelection: false)
        var changes: [String] = []
        capsule.onChange = { name, change in
            changes.append(name)
            change(&settings)
        }
        let chip = try #require(chips(in: capsule, labeled: "Saved Color").first)
        chip.performClick(nil)
        #expect(settings.color == kept && changes == ["Color"])
    }

    @Test func aKeptColorIsRemovedFromItsMenuOrWithVoiceOver() throws {
        let capsule = makeCapsule(keeping: [kept, RGBA(red: 0.5, green: 0.25, blue: 0.125)])
        capsule.show(kind: .arrow, settings: ToolSettings.defaults(for: .arrow), hasSelection: false)
        let chip = try #require(chips(in: capsule, labeled: "Saved Color").first)
        let menu = try #require(chip.menu)
        #expect(menu.items.map(\.title) == ["Remove Saved Color"])
        menu.performActionForItem(at: 0)
        #expect(capsule.savedColors.colors == [SavedColors.stored(RGBA(red: 0.5, green: 0.25, blue: 0.125))])

        capsule.show(kind: .arrow, settings: ToolSettings.defaults(for: .arrow), hasSelection: false)
        let again = try #require(chips(in: capsule, labeled: "Saved Color").first)
        let action = try #require(again.accessibilityCustomActions()?.first)
        #expect(action.name == "Remove Saved Color")
        #expect(action.handler?() == true)
        #expect(capsule.savedColors.colors.isEmpty)
    }
}
