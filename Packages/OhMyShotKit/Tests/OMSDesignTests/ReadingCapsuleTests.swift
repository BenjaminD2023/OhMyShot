import QuartzCore
import Testing
@testable import OMSDesign

@MainActor
struct ReadingCapsuleTests {
    /// A reading changes with the pointer: new text must land at once, never slide or cross-fade in.
    @Test func changingTheTextAnimatesNothing() throws {
        let capsule = ReadingCapsule()
        let text = try #require(capsule.layer.sublayers?.first { $0 is CATextLayer })
        for key in ["bounds", "position", "cornerRadius", "shadowPath"] {
            #expect(capsule.layer.actions?[key] is NSNull, "capsule \(key)")
        }
        for key in ["string", "bounds", "position", "foregroundColor"] {
            #expect(text.actions?[key] is NSNull, "text \(key)")
        }
        // A surface may still fade the capsule as a whole.
        #expect(capsule.layer.actions?["opacity"] == nil)
    }

    /// A list of lines is as tall as its lines and as wide as its longest, with a one-line reading's corners; past its
    /// widest it wraps. One line is a capsule as before.
    @Test func linesStackWithAReadingsCorners() {
        let one = ReadingCapsule()
        one.text = "Press Escape to cancel."
        let oneHeight = one.layer.bounds.height
        #expect(one.layer.cornerRadius == oneHeight / 2)

        let list = ReadingCapsule()
        list.text = "Press Escape to cancel.\nPress Escape to cancel.\nPress Escape to cancel."
        #expect(list.layer.bounds.height > oneHeight * 2)
        #expect(list.layer.bounds.width == one.layer.bounds.width)
        #expect(list.layer.cornerRadius == oneHeight / 2)

        let wrapped = ReadingCapsule()
        wrapped.maximumTextWidth = 80
        wrapped.text = "Press Escape to cancel."
        #expect(wrapped.layer.bounds.width <= 80 + 22)
        #expect(wrapped.layer.bounds.height > oneHeight)
    }
}
