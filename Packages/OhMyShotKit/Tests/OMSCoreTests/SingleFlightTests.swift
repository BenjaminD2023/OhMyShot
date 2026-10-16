import Foundation
import Testing
@testable import OMSCore

/// A capture is saved once however many ways ask for it at the same time.
@MainActor
struct SingleFlightTests {
    /// Work that waits until the test lets it finish, and counts the times it was started.
    @MainActor
    private final class Gate {
        var started = 0
        private var waiting: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func work(returning value: Int) async -> Int {
            started += 1
            if !isOpen { await withCheckedContinuation { waiting = $0 } }
            return value
        }

        func open() {
            isOpen = true
            waiting?.resume()
            waiting = nil
        }
    }

    @Test func aSecondRequestWhileTheWorkGoesWaitsForItAndHasItsAnswer() async {
        let flight = SingleFlight<String, Int>()
        let gate = Gate()
        var asked = 0
        // Each request is counted and made in one step on the main actor, so once all three are counted each has either
        // started the work or joined it.
        let first = Task { asked += 1; return await flight.run("card") { await gate.work(returning: 1) } }
        let second = Task { asked += 1; return await flight.run("card") { await gate.work(returning: 2) } }
        let third = Task { asked += 1; return await flight.run("card") { await gate.work(returning: 3) } }
        while asked < 3 || gate.started == 0 { await Task.yield() }
        #expect(flight.isRunning("card"))
        gate.open()
        let answers = await [first.value, second.value, third.value]
        #expect(answers == [1, 1, 1])
        #expect(gate.started == 1)
        #expect(!flight.isRunning("card"))
    }

    @Test func workForOtherKeysGoesOnAlongside() async {
        let flight = SingleFlight<String, Int>()
        let gate = Gate()
        let one = Task { await flight.run("one") { await gate.work(returning: 1) } }
        while gate.started == 0 { await Task.yield() }
        // Another key is not held up by the first's work.
        let other = await flight.run("two") { 2 }
        #expect(other == 2 && flight.isRunning("one"))
        gate.open()
        #expect(await one.value == 1)
    }

    @Test func aRequestAfterTheWorkIsDoneRunsItAgain() async {
        let flight = SingleFlight<String, Int>()
        var runs = 0
        let first = await flight.run("card") { runs += 1; return runs }
        let second = await flight.run("card") { runs += 1; return runs }
        #expect(first == 1 && second == 2)
    }
}
