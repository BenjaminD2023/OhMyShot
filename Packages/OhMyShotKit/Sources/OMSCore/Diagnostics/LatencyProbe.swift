import OSLog

/// Times one occurrence of a latency-critical path, such as hotkey to overlay.
///
/// The duration is logged as a persisted notice (`latency <name> <ms> ms`) for `Scripts/latency.sh`,
/// because signposts reach the log store only while a tool is recording. The signpost interval is
/// still emitted for Instruments.
public struct LatencyProbe {
    private let name: StaticString
    private let start = ContinuousClock.now
    private let state: OSSignpostIntervalState

    public init(_ name: StaticString) {
        self.name = name
        state = Log.signposter.beginInterval(name)
    }

    /// Ends the measurement and returns the elapsed time in milliseconds.
    @discardableResult
    public func end() -> Double {
        let elapsed = ContinuousClock.now - start
        Log.signposter.endInterval(name, state)
        let milliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
        Log.performance.notice("latency \(String(describing: name), privacy: .public) \(milliseconds, format: .fixed(precision: 2), privacy: .public) ms")
        return milliseconds
    }
}
