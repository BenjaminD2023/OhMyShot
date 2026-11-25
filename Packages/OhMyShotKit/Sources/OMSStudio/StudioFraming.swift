import CoreGraphics
import Foundation

/// Where the camera looks while a Studio recording is zoomed, worked out once the whole cursor path is known, as
/// someone cutting the film afterwards would place it rather than someone chasing the pointer live.
///
/// Each stretch the picture is zoomed (from a zoom's start until the picture shows the whole recording again) is
/// framed at the largest scale it reaches. What happens in it, the clicks and the keys at the pointer
/// (`AutoZoom.events`), is cut into shots, each the longest run that fits what the camera shows with
/// `AutoZoom.margin` around it, as automatic zooms are sized to. The camera holds still on a shot, centered on
/// what happens in it, and moves from one shot to the next as a hand reaches for something (minimum jerk, Flash
/// and Hogan 1985), arriving `arriveEarly` before the next shot's first event. A stretch with nothing happening
/// in it is framed on the cursor as the zoom has fully come in. A zoom aimed at a spot (`StudioProject.Zoom.target`)
/// is a shot of its own, from its start to its end, held on that spot at its own scale: what happens in it, the
/// cursor, and a stronger zoom beside it never move the camera off it. Beside one, a zoom following the pointer with
/// nothing happening in it is a shot of the cursor where it has fully come in, not left on the aimed zoom's spot.
///
/// While a zoom is fully in and the cursor shows, the cursor is kept `margin` inside what the camera shows:
/// wherever it would come nearer the edge, the camera moves by the least that keeps it there, that move widened
/// to the largest within `reach` either way and then averaged over `reach` (three averages of a third each),
/// which at every frame moves the camera at least as far as that frame needs, so it starts moving before the
/// cursor gets there and settles after it. `hardMargin` is kept at every frame all the same, for a cursor that
/// crosses back and forth faster than that.
///
/// The camera zooms about one point: what it looks at is held as the point of the recording that stays put as
/// the picture scales (the pivot), so a zoom coming in or going out scales about it and never slides sideways,
/// held on what it is fully in on first and last; and as the pivot lies inside the recording, what the camera
/// shows never passes the recording's edges.
nonisolated enum StudioFraming {
    /// How far inside what the camera shows the cursor is kept, as a share of what it shows across or down.
    static let margin = 0.1
    /// The least the cursor is ever kept inside, whatever it does.
    static let hardMargin = 0.06
    /// How long before the cursor needs the camera to move it starts, and how long after it settles.
    static let reach = 0.3
    /// How long before the first event of the next shot the camera has arrived on it.
    static let arriveEarly = 0.15
    /// The quickest move from one shot to the next.
    static let quickestMove = 0.25
    /// A cursor fainter than this isn't followed: hidden while typing or resting, it is not where to look.
    static let shownOpacity = 0.05

    private typealias Point = (x: Double, y: Double)

    /// What happens close enough together to frame at once.
    private struct Shot {
        var first: Double
        var last: Double
        var minX: Double
        var maxX: Double
        var minY: Double
        var maxY: Double

        init(_ event: AutoZoom.Event) {
            self.init(first: event.time, last: event.time, x: event.x, y: event.y)
        }

        init(first: Double, last: Double, x: Double, y: Double) {
            self.first = first; self.last = last
            minX = x; maxX = x
            minY = y; maxY = y
        }
    }

    /// A move of the camera from one shot to the next, in the recording's seconds.
    private struct Move {
        var from: Double
        var to: Double
    }

    /// Sets where the camera looks in each of `frames`, sampled `rate` times a second with their zoom, cursor, and
    /// opacity set. `steady` says of each whether a zoom is fully in then; `events` are in order. `crop` is an
    /// optional normalized `0...1` crop rectangle (top-left origin) restricting unzoomed centers and zoomed views
    /// strictly inside the cropped region.
    static func place(
        _ frames: inout [StudioTrack.Frame], steady: [Bool], zooms: [StudioProject.Zoom], events: [AutoZoom.Event],
        width: Double, height: Double, crop: CGRect? = nil, rate: Double, checkCancellation: () throws -> Void
    ) rethrows {
        let normalizedCrop = StudioProject.normalizedCrop(crop)
        let activeCrop = normalizedCrop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let cropRect = CGRect(
            x: Double(activeCrop.minX) * width,
            y: Double(activeCrop.minY) * height,
            width: Double(activeCrop.width) * width,
            height: Double(activeCrop.height) * height
        )
        var index = 0
        while index < frames.count {
            guard frames[index].zoom > 1 else {
                frames[index].centerX = Double(cropRect.midX)
                frames[index].centerY = Double(cropRect.midY)
                index += 1
                continue
            }
            var end = index
            while end + 1 < frames.count, frames[end + 1].zoom > 1 { end += 1 }
            try checkCancellation()
            frame(
                &frames, index...end, steady: steady, zooms: zooms, events: events,
                width: width, height: height, cropRect: cropRect, isCropped: normalizedCrop != nil, rate: rate
            )
            index = end + 1
        }
    }

    /// Frames one zoomed stretch strictly inside `cropRect` (in recording points).
    private static func frame(
        _ frames: inout [StudioTrack.Frame], _ range: ClosedRange<Int>, steady: [Bool], zooms: [StudioProject.Zoom],
        events: [AutoZoom.Event], width: Double, height: Double, cropRect: CGRect, isCropped: Bool, rate: Double
    ) {
        let minX = Double(cropRect.minX), maxX = Double(cropRect.maxX), cropW = Double(cropRect.width)
        let minY = Double(cropRect.minY), maxY = Double(cropRect.maxY), cropH = Double(cropRect.height)
        let start = Double(range.lowerBound) / rate, end = Double(range.upperBound) / rate
        let scale = max(
            zooms.lazy.filter { $0.start <= end && $0.end >= start }.map(\.scale).max() ?? 1,
            frames[range].lazy.map(\.zoom).max() ?? 1
        )
        // Half of what the camera shows at that scale, and the centers that keep it inside the cropped recording.
        let half = (x: cropW / scale / 2, y: cropH / scale / 2)
        func inside(_ point: Point) -> Point {
            (min(max(point.x, minX + half.x), maxX - half.x), min(max(point.y, minY + half.y), maxY - half.y))
        }

        // The zooms aimed at a spot, each a shot held there from its start to its end, and the frames they hold.
        let aimed = zooms.filter { $0.target != nil && $0.start <= end && $0.end >= start }.sorted { $0.start < $1.start }
        func isAimed(_ time: Double) -> Bool { aimed.contains { time >= $0.start && time <= $0.end } }
        let held = range.map { isAimed(Double($0) / rate) }

        // The shots, and where the camera holds on each: what happens outside the aimed zooms, cut into shots
        // between them, and the aimed zooms in their places.
        var shots: [Shot] = []
        var run: [AutoZoom.Event] = []
        var nextAimed = 0
        // An aimed zoom's spot, kept inside the cropped recording at the zoom's own scale, as the center at the
        // stretch's scale that gives the same pivot, so its spot is in the middle at its own scale beside a stronger zoom too.
        func aimedShot(_ zoom: StudioProject.Zoom) -> Shot {
            let fallbackX = width > 0 ? Double(cropRect.midX) / width : 0.5
            let fallbackY = height > 0 ? Double(cropRect.midY) / height : 0.5
            let target = zoom.target ?? .init(x: fallbackX, y: fallbackY)
            func center(_ spot: Double, origin: Double, length: Double, fullLength: Double) -> Double {
                guard zoom.scale > 1 else { return origin + length / 2 }
                let half = length / zoom.scale / 2
                let shown = min(max(spot * fullLength, origin + half), origin + length - half)
                let localShown = shown - origin
                let pivot = (localShown * zoom.scale - length / 2) / (zoom.scale - 1)
                return origin + (pivot * (scale - 1) + length / 2) / scale
            }
            return Shot(
                first: zoom.start, last: zoom.end,
                x: center(target.x, origin: minX, length: cropW, fullLength: width),
                y: center(target.y, origin: minY, length: cropH, fullLength: height)
            )
        }
        for event in events[eventRange(events, from: start, to: end)]
            where !isAimed(event.time) && (!isCropped || (event.x >= minX && event.x <= maxX && event.y >= minY && event.y <= maxY)) {
            while nextAimed < aimed.count, aimed[nextAimed].start <= event.time {
                shots += Self.shots(run[...], half: half)
                run = []
                shots.append(aimedShot(aimed[nextAimed]))
                nextAimed += 1
            }
            run.append(event)
        }
        shots += Self.shots(run[...], half: half)
        shots += aimed[nextAimed...].map(aimedShot)
        if !aimed.isEmpty {
            for zoom in zooms where zoom.target == nil && zoom.scale > 1 && zoom.start <= end && zoom.end >= start
                && !events[eventRange(events, from: zoom.start, to: zoom.end)].contains(where: { !isAimed($0.time) }) {
                let lower = max(range.lowerBound, Int((zoom.start * rate).rounded(.up)))
                let upper = min(range.upperBound, Int((zoom.end * rate).rounded(.down)))
                guard lower <= upper, let settled = (lower...upper).first(where: { steady[$0] && !held[$0 - range.lowerBound] }) else { continue }
                let time = Double(settled) / rate
                let shot = Shot(first: time, last: time, x: frames[settled].cursorX, y: frames[settled].cursorY)
                shots.insert(shot, at: shots.firstIndex { $0.first > time } ?? shots.endIndex)
            }
        }
        var holds = shots.map { inside((($0.minX + $0.maxX) / 2, ($0.minY + $0.maxY) / 2)) }
        if holds.isEmpty {
            let settled = range.first { steady[$0] } ?? (range.lowerBound + range.upperBound) / 2
            holds = [inside((frames[settled].cursorX, frames[settled].cursorY))]
        }
        var moves: [Move] = []
        for next in shots.indices.dropFirst() {
            let across: Double = abs(holds[next].x - holds[next - 1].x) / (2 * half.x)
            let down: Double = abs(holds[next].y - holds[next - 1].y) / (2 * half.y)
            let distance = max(across, down)
            let length = min(max(0.4 + 0.25 * distance, 0.4), 0.9)
            let arrive = shots[next].first - arriveEarly
            var leave = max(arrive - length, shots[next - 1].last)
            leave = max(leave, moves.last?.to ?? -.infinity)
            moves.append(Move(from: leave, to: max(arrive, leave + quickestMove)))
        }

        // Where the camera would look from the shots alone, and how far the cursor needs it moved each way.
        let count = range.count
        var base = [Point](repeating: holds[0], count: count)
        var move = 0
        for offset in 0..<count {
            let time = Double(range.lowerBound + offset) / rate
            while move < moves.count, time >= moves[move].to { move += 1 }
            if move < moves.count, time > moves[move].from {
                let t = (time - moves[move].from) / (moves[move].to - moves[move].from)
                let eased = t * t * t * (10 - 15 * t + 6 * t * t)
                let a = holds[move], b = holds[move + 1]
                base[offset] = (a.x + (b.x - a.x) * eased, a.y + (b.y - a.y) * eased)
            } else {
                base[offset] = holds[move]
            }
        }
        let room = (x: half.x * (1 - 2 * margin), y: half.y * (1 - 2 * margin))
        var right = [Double](repeating: 0, count: count), left = right, down = right, up = right
        var followed = false
        for offset in 0..<count where !held[offset] && follows(frames[range.lowerBound + offset], steady: steady[range.lowerBound + offset]) {
            let cursor = frames[range.lowerBound + offset]
            right[offset] = max(0, cursor.cursorX - (base[offset].x + room.x))
            left[offset] = max(0, (base[offset].x - room.x) - cursor.cursorX)
            down[offset] = max(0, cursor.cursorY - (base[offset].y + room.y))
            up[offset] = max(0, (base[offset].y - room.y) - cursor.cursorY)
            followed = true
        }
        let window = Int((reach * rate).rounded())
        if followed {
            right = spread(right, over: window); left = spread(left, over: window)
            down = spread(down, over: window); up = spread(up, over: window)
        }

        // Where the camera looks: the shots, moved for the cursor, never letting it nearer the edge than
        // `hardMargin`, inside the recording; held where a zoom is aimed.
        let hard = (x: half.x * (1 - 2 * hardMargin), y: half.y * (1 - 2 * hardMargin))
        var centers = base
        for offset in 0..<count {
            let index = range.lowerBound + offset
            guard !held[offset] else {
                centers[offset] = inside(base[offset])
                continue
            }
            var center = (x: base[offset].x + right[offset] - left[offset], y: base[offset].y + down[offset] - up[offset])
            if followed, follows(frames[index], steady: steady[index]) {
                center.x = min(max(center.x, frames[index].cursorX - hard.x), frames[index].cursorX + hard.x)
                center.y = min(max(center.y, frames[index].cursorY - hard.y), frames[index].cursorY + hard.y)
            }
            centers[offset] = inside(center)
        }
        // Coming in and going out, what the zoom is fully in on first and last: each scales about one point, never
        // moving with a cursor it was making room for.
        if let first = range.first(where: { steady[$0] }), let last = range.reversed().first(where: { steady[$0] }) {
            let firstOffset = first - range.lowerBound, lastOffset = last - range.lowerBound
            for offset in 0..<firstOffset { centers[offset] = centers[firstOffset] }
            for offset in (lastOffset + 1)..<count { centers[offset] = centers[lastOffset] }
        }
        // Scaled about the pivot that gives each at the stretch's scale, staying strictly within the crop rectangle.
        for offset in 0..<count {
            let index = range.lowerBound + offset
            let zoom = frames[index].zoom
            frames[index].centerX = minX + scaled(centers[offset].x - minX, length: cropW, scale: scale, zoom: zoom)
            frames[index].centerY = minY + scaled(centers[offset].y - minY, length: cropH, scale: scale, zoom: zoom)
        }

        // An aimed zoom fully in looks at its spot at the scale it is at, inside the cropped recording. Coming in,
        // going out, and from it to the zoom beside it, the camera zooms about the one point that takes it from where
        // it looked to where it looks next, so a spot held by both ends is held all the way; from one aimed zoom to
        // the next at the same scale, which no zoom takes it between, it pans over `quickestMove` across the handover.
        guard !aimed.isEmpty else { return }
        var settled = range.map { steady[$0] }
        for (before, after) in zip(aimed, aimed.dropFirst()) where abs(before.end - after.start) < 1e-6 && before.target != after.target {
            for offset in 0..<count where abs(Double(range.lowerBound + offset) / rate - before.end) <= quickestMove / 2 { settled[offset] = false }
        }
        for offset in 0..<count where held[offset] && settled[offset] {
            let index = range.lowerBound + offset
            let time = Double(index) / rate
            guard let target = aimed.last(where: { time >= $0.start && time <= $0.end })?.target else { continue }
            let zoom = frames[index].zoom
            let halfX = cropW / zoom / 2, halfY = cropH / zoom / 2
            frames[index].centerX = min(max(target.x * width, minX + halfX), maxX - halfX)
            frames[index].centerY = min(max(target.y * height, minY + halfY), maxY - halfY)
        }
        var first = 0
        while first < count {
            guard !settled[first] else {
                first += 1
                continue
            }
            var last = first
            while last + 1 < count, !settled[last + 1] { last += 1 }
            let before = first > 0 ? first - 1 : nil, after = last + 1 < count ? last + 1 : nil
            if before.map({ held[$0] }) == true || after.map({ held[$0] }) == true {
                let a = before.map { frames[range.lowerBound + $0] }, b = after.map { frames[range.lowerBound + $0] }
                let from = (x: a?.centerX ?? Double(cropRect.midX), y: a?.centerY ?? Double(cropRect.midY), level: a?.zoom ?? 1)
                let to = (x: b?.centerX ?? Double(cropRect.midX), y: b?.centerY ?? Double(cropRect.midY), level: b?.zoom ?? 1)
                let lower = Double(before ?? first - 1), upper = Double(after ?? last + 1)
                // Kept inside the cropped recording at the zoom it is at, which two zooms overlapping can dip below both ends.
                for offset in first...last {
                    let index = range.lowerBound + offset
                    let share = (Double(offset) - lower) / (upper - lower)
                    let zoom = frames[index].zoom
                    let x = through((from.x, from.level), (to.x, to.level), zoom: zoom, share: share)
                    let y = through((from.y, from.level), (to.y, to.level), zoom: zoom, share: share)
                    let halfX = cropW / zoom / 2, halfY = cropH / zoom / 2
                    frames[index].centerX = min(max(x, minX + halfX), maxX - halfX)
                    frames[index].centerY = min(max(y, minY + halfY), maxY - halfY)
                }
            }
            first = last + 1
        }
    }

    /// Where the camera looks at `zoom` along one side, zooming about one point from looking at `from.look` at
    /// `from.level` to `to.look` at `to.level`: the point q drawn at the same place at every zoom, the camera
    /// looking at q − k / zoom, which is each end at its level. Between two looks at one level, which no zoom
    /// takes it between, it pans `share` of the way in time, easing in and out as a hand reaches (minimum jerk).
    static func through(_ from: (look: Double, level: Double), _ to: (look: Double, level: Double), zoom: Double, share: Double) -> Double {
        let span = 1 / to.level - 1 / from.level
        guard abs(span) > 1e-9 else {
            let eased = share * share * share * (10 - 15 * share + 6 * share * share)
            return from.look + (to.look - from.look) * eased
        }
        let k = (from.look - to.look) / span
        return from.look + k / from.level - k / zoom
    }

    /// Whether the camera keeps the cursor in view at `frame`: a zoom is fully in and the cursor shows.
    private static func follows(_ frame: StudioTrack.Frame, steady: Bool) -> Bool {
        steady && frame.cursorOpacity >= shownOpacity
    }

    /// Where the camera looks at `zoom` along one side `length` long, framing `center` at `scale`: the pivot
    /// p = (center · scale − length / 2) / (scale − 1) is drawn at the same place at every zoom, the camera
    /// looking at p + (length / 2 − p) / zoom, which is `center` at `scale` and the middle unzoomed.
    static func scaled(_ center: Double, length: Double, scale: Double, zoom: Double) -> Double {
        guard scale > 1 else { return length / 2 }
        let pivot = (center * scale - length / 2) / (scale - 1)
        return pivot + (length / 2 - pivot) / zoom
    }

    /// The runs of `events` that each fit what the camera shows, `half` either way of its middle, with
    /// `AutoZoom.margin` around them.
    private static func shots(_ events: ArraySlice<AutoZoom.Event>, half: Point) -> [Shot] {
        var shots: [Shot] = []
        for event in events {
            if var shot = shots.last {
                shot.minX = min(shot.minX, event.x); shot.maxX = max(shot.maxX, event.x)
                shot.minY = min(shot.minY, event.y); shot.maxY = max(shot.maxY, event.y)
                if shot.maxX - shot.minX + AutoZoom.margin * 2 <= half.x * 2 + 1e-9, shot.maxY - shot.minY + AutoZoom.margin * 2 <= half.y * 2 + 1e-9 {
                    shot.last = event.time
                    shots[shots.count - 1] = shot
                    continue
                }
            }
            shots.append(Shot(event))
        }
        return shots
    }

    /// The indices of the events from `start` to `end`.
    private static func eventRange(_ events: [AutoZoom.Event], from start: Double, to end: Double) -> Range<Int> {
        func firstIndex(after time: Double, inclusive: Bool) -> Int {
            var low = 0, high = events.count
            while low < high {
                let middle = (low + high) / 2
                if inclusive ? events[middle].time < time : events[middle].time <= time { low = middle + 1 } else { high = middle }
            }
            return low
        }
        let lower = firstIndex(after: start, inclusive: true)
        return lower..<max(lower, firstIndex(after: end, inclusive: false))
    }

    /// `values` widened to the largest within `window` either way, then averaged three times over a third of
    /// `window` either way: never less than a value at its own place, as each average is of values that all
    /// reached it, and smooth. Near the ends each average takes what there is.
    static func spread(_ values: [Double], over window: Int) -> [Double] {
        guard values.contains(where: { $0 > 0 }) else { return values }
        var widened = values
        // The largest within reach, from a queue of places whose values only fall.
        var queue: [Int] = []
        var head = 0, next = 0
        for index in values.indices {
            while next < values.count, next <= index + window {
                while queue.count > head, values[queue[queue.count - 1]] <= values[next] { queue.removeLast() }
                queue.append(next)
                next += 1
            }
            while queue[head] < index - window { head += 1 }
            widened[index] = values[queue[head]]
        }
        let third = max(1, window / 3)
        var result = widened
        var sums = [Double](repeating: 0, count: values.count + 1)
        for _ in 0..<3 {
            for index in result.indices { sums[index + 1] = sums[index] + result[index] }
            for index in result.indices {
                let low = max(0, index - third), high = min(result.count - 1, index + third)
                result[index] = (sums[high + 1] - sums[low]) / Double(high - low + 1)
            }
        }
        return result
    }
}
