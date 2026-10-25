import Foundation

/// The visible part of the recording. Editing continues to use recording seconds, regardless of zoom.
nonisolated struct StudioTimelineViewport: Equatable, Sendable {
    let duration: Double
    private(set) var start: Double
    private(set) var span: Double

    init(duration: Double) {
        self.duration = duration.isFinite ? max(duration, 0) : 0
        start = 0
        span = self.duration
    }

    var end: Double { min(start + span, duration) }
    var range: ClosedRange<Double> { start...end }
    var isFit: Bool { span >= duration }
    var canZoomIn: Bool { span > min(duration, 1) + 0.000_001 }
    var maximumStart: Double { max(duration - span, 0) }

    func position(of time: Double, width: Double) -> Double {
        span > 0 ? (time - start) / span * max(width, 0) : 0
    }

    func time(at position: Double, width: Double) -> Double {
        guard width > 0 else { return start }
        return min(max(start + position / width * span, 0), duration)
    }

    func contains(_ lower: Double, _ upper: Double) -> Bool {
        upper >= start && lower <= end
    }

    mutating func fit() {
        start = 0
        span = duration
    }

    /// Keep the playhead at the same place on screen while zooming. An offscreen playhead is centered first.
    mutating func zoom(by factor: Double, around time: Double) {
        guard duration > 0, factor.isFinite, factor > 0 else { return }
        let anchor = min(max(time, 0), duration)
        let fraction = contains(anchor, anchor) && span > 0 ? (anchor - start) / span : 0.5
        span = min(duration, max(min(duration, 1), span / factor))
        start = min(max(anchor - fraction * span, 0), maximumStart)
    }

    mutating func fit(_ selection: ClosedRange<Double>) {
        guard duration > 0 else { return }
        let lower = min(max(selection.lowerBound, 0), duration)
        let upper = min(max(selection.upperBound, lower), duration)
        span = min(duration, max(min(duration, 1), (upper - lower) * 1.3))
        start = min(max((lower + upper - span) / 2, 0), maximumStart)
    }

    mutating func scroll(to time: Double) {
        guard time.isFinite else { return }
        start = min(max(time, 0), maximumStart)
    }

    mutating func reveal(_ time: Double) {
        guard !isFit, time < start || time > end else { return }
        scroll(to: time - span * 0.5)
    }
}

/// A bounded thumbnail grid anchored to recording time, so panning reuses frames instead of decoding again.
nonisolated struct StudioFilmstripRequest: Hashable, Sendable {
    struct Sample: Hashable, Sendable, Identifiable {
        let id: Int64
        let start: Double
        let end: Double
        var time: Double { Double(id) / 600 }
    }

    let samples: [Sample]
    let tolerance: Double

    init(viewport: StudioTimelineViewport, width: Double, aspect: Double) {
        guard viewport.span > 0, width > 0 else {
            samples = []
            tolerance = 0
            return
        }
        let tileWidth = max(40 * max(aspect, 0.25), 40)
        let count = min(max(width / tileWidth, 1), 32)
        let step = max(pow(2, floor(log2(viewport.span / count))), 1.0 / 600)
        let first = max(Int(floor(viewport.start / step)), 0)
        let last = max(first, Int(ceil(viewport.end / step)) - 1)
        samples = (first...min(last, first + 64)).compactMap { index in
            let lower = Double(index) * step
            let upper = min(lower + step, viewport.duration)
            guard upper > lower else { return nil }
            return Sample(id: Int64(((lower + upper) * 0.5 * 600).rounded()), start: lower, end: upper)
        }
        tolerance = step * 0.25
    }
}

/// Count and byte limits both matter: an unusually wide recording must not make the cache unbounded.
nonisolated struct StudioFrameCache<Value> {
    private struct Entry {
        let value: Value
        let cost: Int
        var access: UInt64
    }

    let limit: Int
    let byteLimit: Int
    private var entries: [Int64: Entry] = [:]
    private var access: UInt64 = 0
    private(set) var byteCount = 0
    var count: Int { entries.count }

    init(limit: Int = 96, byteLimit: Int = 24 * 1_024 * 1_024) {
        self.limit = max(limit, 0)
        self.byteLimit = max(byteLimit, 0)
    }

    mutating func value(for key: Int64) -> Value? {
        guard var entry = entries[key] else { return nil }
        access &+= 1
        entry.access = access
        entries[key] = entry
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Int64, cost: Int) {
        if let replaced = entries.removeValue(forKey: key) { byteCount -= replaced.cost }
        guard limit > 0, cost >= 0, cost <= byteLimit else { return }
        access &+= 1
        entries[key] = Entry(value: value, cost: cost, access: access)
        byteCount += cost
        while count > limit || byteCount > byteLimit {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key,
                  let removed = entries.removeValue(forKey: oldest) else { break }
            byteCount -= removed.cost
        }
    }
}
