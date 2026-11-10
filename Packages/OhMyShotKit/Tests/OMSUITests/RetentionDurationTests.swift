import OMSCore
@testable import OMSUI
import Testing

/// A retention inside a sentence is the system's duration in the app's language, not a title lowercased.
struct RetentionDurationTests {
    @Test func everyRetentionButNeverReadsAsADuration() {
        #expect(HistoryRetention.never.duration.isEmpty)
        let durations = [HistoryRetention.oneDay, .threeDays, .oneWeek, .oneMonth].map(\.duration)
        #expect(durations.allSatisfy { !$0.isEmpty })
        #expect(Set(durations).count == durations.count)
        #expect(durations.allSatisfy { $0.contains(where: \.isNumber) })
    }
}
