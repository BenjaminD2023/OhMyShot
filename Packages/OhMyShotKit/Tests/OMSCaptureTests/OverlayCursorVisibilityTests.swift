import Testing
@testable import OMSCapture

@MainActor
struct OverlayCursorVisibilityTests {
    @Test func movesBeforeTakingInputNeverHideThePointer() {
        var calls: [String] = []
        let cursor = OverlayCursorVisibility(hide: { calls.append("hide") }, unhide: { calls.append("unhide") }, keepHidden: {})

        cursor.update(overControls: false)
        cursor.update(overControls: true)
        cursor.end()
        #expect(calls.isEmpty && !cursor.isHidden)
    }

    @Test func controlHandoffsAreBalancedAndRepeatedTrackingIsIdempotent() {
        var calls: [String] = []
        let cursor = OverlayCursorVisibility(hide: { calls.append("hide") }, unhide: { calls.append("unhide") }, keepHidden: {})

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
        let cursor = OverlayCursorVisibility(hide: { calls.append("hide") }, unhide: { calls.append("unhide") }, keepHidden: {})

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
        let cursor = OverlayCursorVisibility(hide: { calls.append("hide") }, unhide: { calls.append("unhide") }, keepHidden: {})

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

    /// An app in front may keep the pointer shown over the hide: the blank cursor goes back on every move while hidden,
    /// and never over controls, after the session, or in a text session.
    @Test func everyMoveWhileHiddenPutsTheBlankCursorBack() {
        var calls: [String] = []
        let cursor = OverlayCursorVisibility(
            hide: { calls.append("hide") }, unhide: { calls.append("unhide") }, keepHidden: { calls.append("blank") }
        )

        cursor.begin(drawsPointer: true, overControls: false)
        cursor.update(overControls: false)
        cursor.update(overControls: true)
        cursor.update(overControls: true)
        cursor.update(overControls: false)
        #expect(calls == ["hide", "blank", "blank", "unhide", "hide", "blank"])
        cursor.end()
        cursor.update(overControls: false)
        cursor.begin(drawsPointer: false, overControls: false)
        cursor.update(overControls: false)
        #expect(calls == ["hide", "blank", "blank", "unhide", "hide", "blank", "unhide"])
    }

    @Test func releasingTheOwnerReturnsOnlyItsOutstandingHide() {
        var calls: [String] = []
        var cursor: OverlayCursorVisibility? = OverlayCursorVisibility(hide: { calls.append("hide") }, unhide: { calls.append("unhide") }, keepHidden: {})

        cursor?.begin(drawsPointer: true, overControls: false)
        cursor = nil
        #expect(calls == ["hide", "unhide"])
    }
}
