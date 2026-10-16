import AppKit
import Foundation
import Testing
@testable import OMSAnnotate

/// The rail and the capsule against the smallest the editor's window goes.
@MainActor
struct EditorLayoutTests {
    private let scratch = ScratchDefaults()

    private func makeCapsule() -> StyleCapsule {
        let defaults = scratch.make()
        let saved = SavedColors(defaults: defaults)
        for index in 0..<SavedColors.limit { saved.add(RGBA(red: Double(index * 16) / 255, green: 0.5, blue: 0.25)) }
        let capsule = StyleCapsule()
        capsule.savedColors = saved
        return capsule
    }

    @Test func theRailFitsAboveTheCapsulesBandInTheSmallestWindow() {
        let rail = ToolRail()
        let height = rail.fittingSize.height
        let minimum = AnnotationEditorWindowController.minimumSize
        // The working area is the window under its 52 pt of toolbar. The rail stands 12 pt from the top of
        // it and the capsule's band (12 + 38 + 12) is at the bottom, with 8 to spare between them.
        #expect(12 + height + 8 <= minimum.height - 52 - 62, "rail \(height), window \(minimum.height)")
        // And the top: below the toolbar's own height, as the canvas's insets leave it.
        #expect(rail.fittingSize.width == ToolRail.width)    }

    @Test func theWidestCapsuleFitsBesideTheRailInTheSmallestWindow() {
        let capsule = makeCapsule()
        // What the capsules can carry besides their controls: a reading under way, one that failed, and the
        // most redaction suggestions a two-digit count makes.
        let statuses: [(name: String, finding: Bool, failed: Bool, suggestions: Int)] = [
            ("resting", false, false, 0), ("finding", true, false, 0), ("failed", false, true, 0), ("suggestions", false, false, 99),
        ]
        var widest: (state: String, width: CGFloat) = ("", 0)
        for tool in AnnotationTool.allCases where tool != .select && tool != .background {
            for status in statuses {
                var settings = ToolSettings.defaults(for: tool)
                // A color of one's own, unsaved, with the kept colors full: the dot and the dimmed plus.
                settings.color = RGBA(red: 0.31, green: 0.42, blue: 0.53)
                capsule.show(kind: tool, settings: settings, hasSelection: true, suggestions: status.suggestions, finding: status.finding, failed: status.failed)
                let width = capsule.fittingSize.width
                if width > widest.width { widest = ("\(tool), \(status.name)", width) }
            }
        }
        let minimum = AnnotationEditorWindowController.minimumSize
        // Beside the rail (12 + 42 + 8) and 8 from the right edge.
        #expect(62 + widest.width + 8 <= minimum.width, "\(widest.state) capsule \(widest.width), window \(minimum.width)")
    }

    @Test func keptColorsWidenTheCapsuleByTheirChipsAndAnUnsavedColorShowsASaveChip() {
        let none = StyleCapsule()
        none.savedColors = SavedColors(defaults: scratch.make())
        let full = makeCapsule()
        var settings = ToolSettings.defaults(for: .arrow)
        settings.color = .red
        none.show(kind: .arrow, settings: settings, hasSelection: false)
        full.show(kind: .arrow, settings: settings, hasSelection: false)
        // Eight chips of 24 pt, 2 pt apart.
        #expect(abs(full.fittingSize.width - none.fittingSize.width - 8 * 26) < 1)
        // A color that is none of the inks and not kept gets a chip to keep it.
        settings.color = RGBA(red: 0.31, green: 0.42, blue: 0.53)
        none.show(kind: .arrow, settings: settings, hasSelection: false)
        let withSave = none.fittingSize.width
        none.savedColors.add(settings.color)
        none.show(kind: .arrow, settings: settings, hasSelection: false)
        // Kept, it is a dot among the others in place of the save chip: one chip either way.
        #expect(abs(none.fittingSize.width - withSave) < 1)
    }

    @Test func theMarkerYellowTheHighlightersStartInIsNotOfferedToBeKept() {
        let capsule = StyleCapsule()
        capsule.savedColors = SavedColors(defaults: scratch.make())
        for tool in [AnnotationTool.highlighter, .highlightBox] {
            var settings = ToolSettings.defaults(for: tool)
            #expect(settings.color == .marker)
            capsule.show(kind: tool, settings: settings, hasSelection: false)
            let marker = capsule.fittingSize.width
            settings.color = .red
            capsule.show(kind: tool, settings: settings, hasSelection: false)
            // The marker shows as the custom dot, with no save chip beside it: as wide as with an ink in use.
            #expect(abs(capsule.fittingSize.width - marker) < 1, "\(tool)")
        }
    }
}
