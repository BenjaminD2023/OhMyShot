import Foundation
import Testing
@testable import OMSCore

/// A shortcut's capture is held from the moment it is kept until the shortcut has its file, and let go then, whether
/// the shortcut read the file, failed, or was cancelled: with Keep Captures at Never and no card it is all that keeps
/// the capture, and nothing may keep it afterwards.
@MainActor
struct ShortcutCaptureHoldsTests {
    private struct ReadFailed: Error {}

    @Test func aKeptCaptureIsHeldUntilItsFileIsReadThenLetGo() async {
        var released = [UUID]()
        let holds = ShortcutCaptureHolds { released.append($0) }
        let capture = UUID()
        let file = await holds.holding { hold in
            hold(capture)
            // What would let it go now (no card, Keep Captures at Never) finds it held, and leaves it.
            #expect(holds.heldIDs == [capture])
            #expect(released.isEmpty)
            return "read"
        }
        #expect(file == "read")
        #expect(holds.heldIDs.isEmpty)
        #expect(released == [capture])
    }

    @Test func aFailedReadLetsTheCaptureGo() async {
        var released = [UUID]()
        let holds = ShortcutCaptureHolds { released.append($0) }
        let capture = UUID()
        await #expect(throws: ReadFailed.self) {
            try await holds.holding { hold in
                hold(capture)
                throw ReadFailed()
            }
        }
        #expect(holds.heldIDs.isEmpty)
        #expect(released == [capture])
    }

    @Test func aCancelledShortcutLetsTheCaptureGo() async {
        var released = [UUID]()
        let holds = ShortcutCaptureHolds { released.append($0) }
        let capture = UUID()
        let shortcut = Task { @MainActor in
            try await holds.holding { hold in
                hold(capture)
                try await Task.sleep(for: .seconds(60))
            }
        }
        while holds.heldIDs.isEmpty { await Task.yield() }
        shortcut.cancel()
        _ = await shortcut.result
        #expect(holds.heldIDs.isEmpty)
        #expect(released == [capture])
    }

    /// The capture waits on the overlay, which a stopped shortcut doesn't end: the area chosen after the shortcut was
    /// stopped is still kept, held, and let go once the shortcut's work returns.
    @Test func aShortcutStoppedWhileChoosingLetsTheCaptureGoOnceItIsKept() async {
        @MainActor final class Overlay {
            var chosen: CheckedContinuation<Void, Never>?
        }
        var released = [UUID]()
        let holds = ShortcutCaptureHolds { released.append($0) }
        let capture = UUID(), overlay = Overlay()
        let shortcut = Task { @MainActor in
            await holds.holding { hold -> String? in
                await withCheckedContinuation { overlay.chosen = $0 }
                hold(capture)
                #expect(holds.heldIDs == [capture])
                return Task.isCancelled ? nil : "read"
            }
        }
        while overlay.chosen == nil { await Task.yield() }
        shortcut.cancel()
        #expect(released.isEmpty)
        overlay.chosen?.resume()
        #expect(await shortcut.value == nil)
        #expect(holds.heldIDs.isEmpty)
        #expect(released == [capture])
    }

    @Test func aPinnedCaptureIsLeftAsAPinWithoutAShortcutLeavesIt() async {
        var released = [UUID]()
        let holds = ShortcutCaptureHolds { released.append($0) }
        let capture = UUID()
        let file = await holds.holding(lettingGo: false) { hold in
            hold(capture)
            #expect(holds.heldIDs == [capture])
            return "read"
        }
        #expect(file == "read")
        #expect(holds.heldIDs.isEmpty)
        #expect(released.isEmpty)
    }

    @Test func aShortcutThatKeptNothingLetsNothingGo() async {
        var released = [UUID]()
        let holds = ShortcutCaptureHolds { released.append($0) }
        let file: String? = await holds.holding { _ in nil }
        #expect(file == nil)
        #expect(released.isEmpty)
    }

    @Test func aHoldAfterTheShortcutEndedHoldsNothing() async {
        var released = [UUID]()
        let holds = ShortcutCaptureHolds { released.append($0) }
        var late: ((UUID) -> Void)?
        await holds.holding { hold in late = hold }
        late?(UUID())
        #expect(holds.heldIDs.isEmpty)
        #expect(released.isEmpty)
    }
}
