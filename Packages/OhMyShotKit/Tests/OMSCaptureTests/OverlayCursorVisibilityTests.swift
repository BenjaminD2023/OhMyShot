import Testing
@testable import OMSCapture

@MainActor
struct OverlayCursorVisibilityTests {
    @Test func movesBeforeTakingInputNeverHideThePointer() {
        var calls: [String] = []
        let cursor = OverlayCursorVisibility(isActive: { true }, hide: { calls.append("hide") }, unhide: { calls.append("unhide") })

        cursor.update(overControls: false)
        cursor.update(overControls: true)
        cursor.end()
        #expect(calls.isEmpty && !cursor.isHidden)
    }

    @Test func controlHandoffsAreBalancedAndRepeatedTrackingIsIdempotent() {
        var calls: [String] = []
        let cursor = OverlayCursorVisibility(isActive: { true }, hide: { calls.append("hide") }, unhide: { calls.append("unhide") })

        cursor.begin(drawsPointer: true, overControls: false)
        cursor.update(overControls: false)
        cursor.update(overControls: true)
        cursor.update(overControls: true)
        #expect(calls == ["hide", "unhide"] && !cursor.isHidden)
        cursor.update(overControls: false)
        cursor.update(overControls: false)
        cursor.end()
        cursor.end()
        #expect(calls == ["hide", "unhide", "hide", "unhide"] && !cursor.isHidden)
    }

    @Test func openingOnControlsAndTextSessionsKeepTheSystemPointer() {
        var calls: [String] = []
        let cursor = OverlayCursorVisibility(isActive: { true }, hide: { calls.append("hide") }, unhide: { calls.append("unhide") })

        cursor.begin(drawsPointer: true, overControls: true)
        #expect(calls.isEmpty)
        cursor.end()
        cursor.begin(drawsPointer: false, overControls: false)
        cursor.update(overControls: true)
        cursor.update(overControls: false)
        cursor.end()
        #expect(calls.isEmpty && !cursor.isHidden)
    }

    @Test func setupOrCancellationEndsOwnershipUntilTheNextInputSession() {
        var calls: [String] = []
        let cursor = OverlayCursorVisibility(isActive: { true }, hide: { calls.append("hide") }, unhide: { calls.append("unhide") })

        cursor.begin(drawsPointer: true, overControls: false)
        cursor.update(overControls: true)
        cursor.end()
        cursor.update(overControls: false)
        cursor.update(overControls: true)
        #expect(calls == ["hide", "unhide"])
        cursor.begin(drawsPointer: true, overControls: false)
        #expect(cursor.isHidden)
        cursor.end()
        #expect(calls == ["hide", "unhide", "hide", "unhide"])
    }

    /// The window server ignores a hide from an app in the background: it waits for the activation the overlay asked
    /// for, is given back while the app is not active, and the views hear each change.
    @Test func theHideWaitsForTheAppToBeActive() {
        var calls: [String] = []
        var active = false
        var heard: [Bool] = []
        let cursor = OverlayCursorVisibility(isActive: { active }, hide: { calls.append("hide") }, unhide: { calls.append("unhide") })
        cursor.onChange = { heard.append($0) }

        cursor.begin(drawsPointer: true, overControls: false)
        cursor.update(overControls: false)
        #expect(calls.isEmpty && !cursor.isHidden)
        active = true
        cursor.activationChanged()
        cursor.activationChanged()
        #expect(calls == ["hide"] && cursor.isHidden)
        active = false
        cursor.activationChanged()
        #expect(calls == ["hide", "unhide"] && !cursor.isHidden)
        active = true
        cursor.activationChanged()
        cursor.end()
        #expect(calls == ["hide", "unhide", "hide", "unhide"] && heard == [true, false, true, false])
    }

    @Test func activationOverControlsOrAfterTheSessionHidesNothing() {
        var calls: [String] = []
        var active = false
        let cursor = OverlayCursorVisibility(isActive: { active }, hide: { calls.append("hide") }, unhide: { calls.append("unhide") })

        cursor.begin(drawsPointer: true, overControls: true)
        active = true
        cursor.activationChanged()
        #expect(calls.isEmpty)
        cursor.update(overControls: false)
        cursor.end()
        cursor.activationChanged()
        #expect(calls == ["hide", "unhide"] && !cursor.isHidden)
    }

    @Test func releasingTheOwnerReturnsOnlyItsOutstandingHide() {
        var calls: [String] = []
        var cursor: OverlayCursorVisibility? = OverlayCursorVisibility(isActive: { true }, hide: { calls.append("hide") }, unhide: { calls.append("unhide") })

        cursor?.begin(drawsPointer: true, overControls: false)
        cursor = nil
        #expect(calls == ["hide", "unhide"])
    }
}
