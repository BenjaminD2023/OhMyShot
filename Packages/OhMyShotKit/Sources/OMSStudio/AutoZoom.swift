import CoreGraphics
import Foundation

/// Where zooms go before any is placed by hand: in on the clicks and the typing, as a person filming the
/// screen would.
///
/// Clicks and keys less than `gap` apart and close enough to frame together belong to one zoom, which starts `leadIn` before the first and holds
/// `hold` after the last, at least `shortest` long. A single click or key places none: it takes `fewestEvents`.
/// A busy stretch, `busyEvents` clicks and keys or any typing, zooms to the standard scale and a few clicks to
/// the light one; either is cut down to fit what happens in it when that is spread too wide, and spread wider
/// than a gentle zoom can hold, it gets none. Zooms that overlap or end no more than `joinGap` before the next
/// begins are joined when their combined area fits, at the gentler of their scales or the scale that fits both, so the camera stays in and pans instead of zooming out
/// and back in; never across a zoom placed by hand (`around`), which would cost both. Clicks are heard all over the screen and keys wherever the pointer is: only those inside the
/// recording count, or a click on another display would zoom into the recording's nearest edge.
nonisolated public enum AutoZoom {
    public static let gap = 2.0
    /// Zooms with this much or less between them are one zoom.
    public static let joinGap = 3.0
    public static let leadIn = 0.6
    public static let hold = 1.4
    public static let shortest = 1.8
    /// A stretch of one click or one key is not worth a zoom; it takes this many.
    public static let fewestEvents = 2
    /// Clicks and keys in a stretch for it to count as busy, as any key in it does.
    public static let busyEvents = 4
    public static let standardScale = 2.0
    /// What a few clicks, and no typing, zoom to.
    public static let lightScale = 1.5
    /// A zoom gentler than this is not worth the movement.
    public static let gentlestScale = 1.3
    /// Room around what happens, in the recording's points, when fitting it into a zoom.
    public static let margin = 80.0

    typealias Event = (time: Double, x: Double, y: Double, isKey: Bool)

    private struct Bounds {
        var minX: Double
        var maxX: Double
        var minY: Double
        var maxY: Double

        init(_ event: Event) {
            minX = event.x; maxX = event.x
            minY = event.y; maxY = event.y
        }

        func joined(_ other: Bounds) -> Bounds {
            var result = self
            result.minX = min(minX, other.minX); result.maxX = max(maxX, other.maxX)
            result.minY = min(minY, other.minY); result.maxY = max(maxY, other.maxY)
            return result
        }

        func scale(in telemetry: StudioTelemetry) -> Double {
            min(telemetry.width / (maxX - minX + margin * 2), telemetry.height / (maxY - minY + margin * 2))
        }
    }

    /// Every click, and every key at the pointer's place when it was pressed, inside the recording, in order.
    static func events(in telemetry: StudioTelemetry) -> [Event] {
        var events = telemetry.clicks.map { (time: $0.time, x: $0.x, y: $0.y, isKey: false) }
        events += telemetry.keys.filter { !$0.isRepeat }.map { key in
            let place = pointer(at: key.time, in: telemetry.samples)
            return (time: key.time, x: place.x, y: place.y, isKey: true)
        }
        events = events.filter { $0.x >= 0 && $0.x <= telemetry.width && $0.y >= 0 && $0.y <= telemetry.height }
        return events.sorted { $0.time < $1.time }
    }

    /// Whether the recording holds a click or a key to follow at all, whether or not it places a zoom.
    public static func hasEvents(in telemetry: StudioTelemetry) -> Bool {
        !events(in: telemetry).isEmpty
    }

    public static func zooms(for telemetry: StudioTelemetry, duration: Double, around fixed: [StudioProject.Zoom] = []) -> [StudioProject.Zoom] {
        let events = events(in: telemetry).filter { $0.time >= 0 && $0.time <= duration }
        guard !events.isEmpty, duration > 0 else { return [] }

        var groups: [[Event]] = []
        var bounds: [Bounds] = []
        for event in events {
            let area = Bounds(event)
            if let last = groups.last?.last, let previous = bounds.last,
               event.time - last.time < gap, previous.joined(area).scale(in: telemetry) >= gentlestScale {
                groups[groups.count - 1].append(event)
                bounds[bounds.count - 1] = previous.joined(area)
            } else {
                groups.append([event])
                bounds.append(area)
            }
        }
        struct Candidate {
            var zoom: StudioProject.Zoom
            var bounds: Bounds
            var lastEvent: Double
        }
        var candidates: [Candidate] = []
        for (index, group) in groups.enumerated() {
            guard group.count >= fewestEvents else { continue }
            let area = bounds[index]
            let busy = group.count >= busyEvents || group.contains { $0.isKey }
            let scale = min(busy ? standardScale : lightScale, area.scale(in: telemetry))
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
            if let last = candidates.last, start - last.zoom.end <= joinGap,
               last.bounds.joined(area).scale(in: telemetry) >= gentlestScale,
               !fixed.contains(where: { $0.start < start && last.zoom.end < $0.end }) {
                let combined = last.bounds.joined(area)
                candidates[candidates.count - 1].zoom.end = max(last.zoom.end, end)
                candidates[candidates.count - 1].zoom.scale = min(last.zoom.scale, rounded, (combined.scale(in: telemetry) * 10).rounded(.down) / 10)
                candidates[candidates.count - 1].bounds = combined
                candidates[candidates.count - 1].lastEvent = group.last!.time
            } else {
                // Spatially separate actions can have overlapping lead/hold tails. Split those tails
                // between the actions, keeping the timeline ordered and making room to pull back.
                if let last = candidates.last, last.zoom.end > start {
                    let boundary = (last.lastEvent + group.first!.time) / 2
                    candidates[candidates.count - 1].zoom.end = boundary
                    start = max(start, boundary)
                    if boundary - last.zoom.start < 0.3 { candidates.removeLast() }
                }
                guard end - start >= 0.3 else { continue }
                candidates.append(Candidate(
                    zoom: .init(start: start, end: end, scale: rounded, isAutomatic: true), bounds: area, lastEvent: group.last!.time
                ))
            }
        }
        return candidates.map(\.zoom)
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
