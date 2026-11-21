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
    /// A drag counts as its press, its release, and where the pointer was this often in between.
    public static let dragStep = 0.2

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

    /// Every click, and every typing key inside the recording, in order. A drag (`Click.isDrag`) is its press,
    /// its release, and the pointer every `dragStep` in between; when `skipWideDrags` is set, a drag whose whole
    /// path is too wide to frame is left out so automatic zooms don't split it in two. Shortcuts are ignored, and
    /// typing that continues a recent click stays anchored to that click even if the pointer moves out of the way.
    static func events(in telemetry: StudioTelemetry, skipWideDrags: Bool = false) -> [Event] {
        func contains(_ event: Event) -> Bool {
            event.x >= 0 && event.x <= telemetry.width && event.y >= 0 && event.y <= telemetry.height
        }
        var clicks: [Event] = []
        for click in telemetry.clicks {
            let press: Event = (time: click.time, x: click.x, y: click.y, isKey: false)
            guard click.isDrag, let release = click.releaseTime, let releaseX = click.releaseX, let releaseY = click.releaseY else {
                clicks.append(press)
                continue
            }
            var path = Bounds(press)
            var along: [Event] = []
            var step = 1.0
            while click.time + step * dragStep < release {
                let time = click.time + step * dragStep
                let place = pointer(at: time, in: telemetry.samples)
                along.append((time: time, x: place.x, y: place.y, isKey: false))
                step += 1
            }
            along.append((time: release, x: releaseX, y: releaseY, isKey: false))
            for event in along { path = path.joined(Bounds(event)) }
            if !skipWideDrags || path.scale(in: telemetry) >= gentlestScale {
                clicks.append(press)
                clicks += along
            }
        }
        clicks = clicks.filter(contains).sorted { $0.time < $1.time }
        let typingKeys = telemetry.keys.filter { !$0.isRepeat && $0.isTyping }.sorted { $0.time < $1.time }
        var events: [Event] = []
        events.reserveCapacity(clicks.count + typingKeys.count)
        var clickIndex = 0
        var anchor: (time: Double, x: Double, y: Double)?
        for key in typingKeys {
            while clickIndex < clicks.count, clicks[clickIndex].time <= key.time {
                let click = clicks[clickIndex]
                events.append(click)
                anchor = (time: click.time, x: click.x, y: click.y)
                clickIndex += 1
            }
            if let current = anchor, key.time - current.time < gap {
                events.append((time: key.time, x: current.x, y: current.y, isKey: true))
                anchor = (time: key.time, x: current.x, y: current.y)
            } else {
                let place = pointer(at: key.time, in: telemetry.samples)
                events.append((time: key.time, x: place.x, y: place.y, isKey: true))
                anchor = nil
            }
        }
        if clickIndex < clicks.count { events += clicks[clickIndex...] }
        return events.filter(contains)
    }

    /// Whether the recording holds a click or a key to follow at all, whether or not it places a zoom.
    public static func hasEvents(in telemetry: StudioTelemetry) -> Bool {
        !events(in: telemetry).isEmpty
    }

    public static func zooms(for telemetry: StudioTelemetry, duration: Double, around fixed: [StudioProject.Zoom] = []) -> [StudioProject.Zoom] {
        guard duration > 0 else { return [] }
        let allEvents = events(in: telemetry, skipWideDrags: true).filter { $0.time >= 0 && $0.time <= duration }
        guard !allEvents.isEmpty else { return [] }

        // Split the timeline by hand-placed zooms first so each free stretch is grouped and joined on its own,
        // without a short hand-placed zoom canceling neighboring automatic zooms.
        let spans = freeSpans(in: duration, around: fixed)
        var result: [StudioProject.Zoom] = []
        for span in spans {
            let spanEvents = allEvents.filter { event in
                event.time >= span.start && event.time <= span.end
                    && !fixed.contains { $0.start <= event.time && event.time <= $0.end }
            }
            guard !spanEvents.isEmpty else { continue }
            result += zooms(in: spanEvents, telemetry: telemetry, spanStart: span.start, spanEnd: span.end)
        }
        return result
    }

    /// Free intervals of `0...duration` left uncovered by `fixed` zooms.
    private static func freeSpans(in duration: Double, around fixed: [StudioProject.Zoom]) -> [(start: Double, end: Double)] {
        let clamped = fixed
            .map { (start: max(0, min(duration, $0.start)), end: max(0, min(duration, $0.end))) }
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }
        var spans: [(start: Double, end: Double)] = []
        var cursor = 0.0
        for zoom in clamped {
            if zoom.start > cursor { spans.append((cursor, zoom.start)) }
            cursor = max(cursor, zoom.end)
        }
        if cursor < duration { spans.append((cursor, duration)) }
        return spans
    }

    private static func zooms(
        in events: [Event], telemetry: StudioTelemetry, spanStart: Double, spanEnd: Double
    ) -> [StudioProject.Zoom] {
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
            // Keys without a nearby click have no known location on screen: only a group anchored by a click zooms.
            guard group.count >= fewestEvents, group.contains(where: { !$0.isKey }) else { continue }
            let area = bounds[index]
            let busy = group.count >= busyEvents || group.contains { $0.isKey }
            let scale = min(busy ? standardScale : lightScale, area.scale(in: telemetry))
            guard scale >= gentlestScale else { continue }
            var start = max(spanStart, (group.first?.time ?? spanStart) - leadIn)
            var end = min(spanEnd, (group.last?.time ?? spanEnd) + hold)
            if end - start < shortest {
                end = min(spanEnd, start + shortest)
                start = max(spanStart, end - shortest)
            }
            guard end > start else { continue }
            // Tenths, so a zoom's scale reads as a round number in the inspector.
            let rounded = (scale * 10).rounded(.down) / 10
            if let last = candidates.last, start - last.zoom.end <= joinGap,
               last.bounds.joined(area).scale(in: telemetry) >= gentlestScale {
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
                    if boundary - last.zoom.start < StudioProject.shortestZoom { candidates.removeLast() }
                }
                guard end - start >= StudioProject.shortestZoom else { continue }
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
