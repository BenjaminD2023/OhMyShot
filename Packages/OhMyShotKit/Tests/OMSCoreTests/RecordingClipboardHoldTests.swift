import Foundation
import Testing
@testable import OMSCore

@MainActor
struct RecordingClipboardHoldTests {
    @Test func timedRetentionOnlyChecksOnDemand() {
        var reads = 0, count = 1
        let hold = RecordingClipboardHold(changeCount: { reads += 1; return count }, released: { _ in })
        let id = UUID()
        for retention in HistoryRetention.allCases where retention != .never {
            hold.copied(id, retention: retention)
            #expect(hold.watch == nil)
            #expect(hold.heldID == id)
            let before = reads
            hold.poll()
            #expect(reads == before)
            count += 1
            #expect(hold.heldID == nil)
        }
    }

    @Test func switchingPoliciesStartsAndStopsOneWatchForTheCurrentRecording() {
        var count = 1, released = [UUID]()
        let hold = RecordingClipboardHold(changeCount: { count }, released: { released.append($0) })
        hold.updatePolling(for: .never)
        #expect(hold.watch == nil)
        let first = UUID(), second = UUID()
        hold.copied(first, retention: .oneWeek)
        hold.updatePolling(for: .never)
        let watch = hold.watch
        #expect(watch != nil)
        hold.poll()
        #expect(hold.heldID == first)
        count += 1
        hold.copied(second, retention: .never)
        #expect(hold.watch == watch)
        #expect(released == [first])
        hold.updatePolling(for: .oneMonth)
        #expect(hold.watch == nil)
        #expect(watch?.isCancelled == true)
        #expect(hold.heldID == second)
        hold.updatePolling(for: .never)
        count += 1
        hold.poll()
        #expect(hold.watch == nil)
        #expect(hold.heldID == nil)
        #expect(released == [first, second])
    }
}
