import QuartzCore
import Testing
@testable import OMSCore

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
}
