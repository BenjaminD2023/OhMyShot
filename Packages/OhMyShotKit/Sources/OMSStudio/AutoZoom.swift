import CoreGraphics
import Foundation

/// Where zooms go before any is placed by hand: in on the clicks and the typing, as a person filming the
/// screen would.
///
/// Clicks and keys less than `gap` apart belong to one zoom, which starts `leadIn` before the first and holds
/// `hold` after the last, at least `shortest` long. Its scale is the standard one unless what happens in it is
/// spread too wide to fit; spread wider than a gentle zoom can hold, it gets none. Zooms that meet are joined.
/// Clicks are heard all over the screen and keys wherever the pointer is: only those inside the recording
/// count, or a click on another display would zoom into the recording's nearest edge.
nonisolated public enum AutoZoom {
    public static let gap = 2.0
    public static let leadIn = 0.6
    public static let hold = 1.4
    public static let shortest = 1.8
    public static let standardScale = 2.0
    /// A zoom gentler than this is not worth the movement.
    public static let gentlestScale = 1.3
    /// Room around what happens, in the recording's points, when fitting it into a zoom.
    public static let margin = 80.0

    public static func zooms(for telemetry: StudioTelemetry, duration: Double) -> [StudioProject.Zoom] {
        // Every click, and every key at the pointer's place when it was pressed.
        var events = telemetry.clicks.map { (time: $0.time, x: $0.x, y: $0.y) }
        events += telemetry.keys.filter { !$0.isRepeat }.map { key in
            let place = pointer(at: key.time, in: telemetry.samples)
            return (time: key.time, x: place.x, y: place.y)
        }
        events = events.filter { $0.x >= 0 && $0.x <= telemetry.width && $0.y >= 0 && $0.y <= telemetry.height }
        events.sort { $0.time < $1.time }
        guard !events.isEmpty, duration > 0 else { return [] }

        var groups: [[(time: Double, x: Double, y: Double)]] = []
        for event in events {
            if let last = groups.last?.last, event.time - last.time < gap {
                groups[groups.count - 1].append(event)
            } else {
                groups.append([event])
            }
        }
        var zooms: [StudioProject.Zoom] = []
        for group in groups {
            let xs = group.map(\.x), ys = group.map(\.y)
            let spreadWidth = (xs.max() ?? 0) - (xs.min() ?? 0) + margin * 2
            let spreadHeight = (ys.max() ?? 0) - (ys.min() ?? 0) + margin * 2
            let scale = min(standardScale, telemetry.width / spreadWidth, telemetry.height / spreadHeight)
            guard scale >= gentlestScale else { continue }
            var start = max(0, (group.first?.time ?? 0) - leadIn)
            var end = min(duration, (group.last?.time ?? 0) + hold)
            if end - start < shortest {
                end = min(duration, start + shortest)
                start = max(0, end - shortest)
            }
            guard end > start else { continue }
            // Tenths, so a zoom's scale reads as a round number in the inspector.
            let rounded = (scale * 10).rounded(.down) / 10
            if let last = zooms.last, start <= last.end {
                zooms[zooms.count - 1].end = max(last.end, end)
                zooms[zooms.count - 1].scale = min(last.scale, rounded)
            } else {
                zooms.append(.init(start: start, end: end, scale: rounded, isAutomatic: true))
            }
        }
        return zooms
    }

    /// Where the pointer was at `time`: the last reading at or before it, else the first.
    public static func pointer(at time: Double, in samples: [StudioTelemetry.Sample]) -> (x: Double, y: Double) {
        guard let first = samples.first else { return (0, 0) }
        var low = 0, high = samples.count - 1
        guard time >= first.time else { return (first.x, first.y) }
        while low < high {
            let middle = (low + high + 1) / 2
            if samples[middle].time <= time { low = middle } else { high = middle - 1 }
        }
        return (samples[low].x, samples[low].y)
    }
}
