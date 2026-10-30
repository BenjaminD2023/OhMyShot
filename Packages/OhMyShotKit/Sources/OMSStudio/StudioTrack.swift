import CoreGraphics
import Foundation

/// The camera and the cursor at every moment of a Studio recording, worked out once from the telemetry and
/// the project: how much the picture is zoomed and where it looks, where the cursor is drawn, which one, and
/// how visible it is. Sampled `rate` times a second in the recording's own time; the compositor reads between
/// samples, so playback, scrubbing, and export all draw the same movie.
///
/// The cursor follows the pointer through a critically damped spring (none at smoothing 0) that loosens as the
/// pointer slows and tightens as it speeds up, so a shaky hand draws a calm line and a quick flick keeps up;
/// over the last `clickApproach` before a click it closes on the pointer, so it presses where the pointer did
/// and the click's ring lands under its tip, and the click starts it afresh there. It fades when the pointer
/// rests and, as the system hides it, while typing, until the pointer moves or clicks.
/// Each zoom eases in and out evenly in scale, and the camera is placed by `StudioFraming` once the whole cursor
/// path is known: still on what happens, moving ahead of the cursor only to keep it in view, zooming about one
/// point, never past the recording's edges.
nonisolated public struct StudioTrack: Sendable {
    public struct Frame: Equatable, Sendable {
        /// 1 shows the whole recording.
        public var zoom: Double
        /// Where the camera looks, in the recording's points from its top-left corner, kept so what it shows
        /// stays inside the recording.
        public var centerX: Double
        public var centerY: Double
        /// The cursor's hot spot, in the recording's points.
        public var cursorX: Double
        public var cursorY: Double
        public var cursor: Int
        public var cursorOpacity: Double
    }

    public let rate: Double
    public let frames: [Frame]
    /// The recording's size in points.
    public let width: Double
    public let height: Double
    /// Exact event positions between the regular samples. Seeking to a click must land on its hotspot,
    /// even when the event falls between two 120 Hz frames or several clicks share a frame interval.
    private let clickAnchors: [StudioTelemetry.Click]

    /// How long a zoom takes to ease in or out, at most.
    public static let transition = 0.5
    /// How long the pointer rests before an idle cursor fades.
    public static let idleDelay = 1.6
    /// How long before a click the cursor gives up its smoothing.
    public static let clickApproach = 0.15
    /// The quickest the cursor's spring ever follows: its time constant at the lowest smoothing, and the one a
    /// fast pointer is followed with at any smoothing.
    static let cursorQuickest = 0.02
    /// The pointer speed, in points a second, at which the cursor's spring has come halfway from its time
    /// constant at rest down to `cursorQuickest`. The time constant falls as 1 / (1 + speed / reference), the
    /// shape the One Euro filter gives it (Casiez, Roussel and Vogel, CHI 2012: a low-pass filter whose cutoff
    /// rises with the speed it measures), held above `cursorQuickest`. At 700 a slow drift of tens of points a
    /// second keeps nearly all its smoothing and a flick of 2500 is followed with about a quarter of it, which
    /// leaves the flick trailing 0.4 times as far as the fixed spring did and the drift's jitter within 1.2 times
    /// the fixed spring's; a lower speed lets more of the jitter through, a higher one lets the flick trail farther.
    static let referenceSpeed = 700.0
    /// How long the pointer's velocity is averaged over before its speed is read: the time constant of a
    /// first-order low-pass, 0.16 s, which is the one hertz One Euro filters its derivative at. The velocity is
    /// averaged, not the speed, so jitter that changes direction every reading cancels instead of reading as
    /// speed, and a flick still reaches nine tenths of its speed in 0.4 s.
    static let speedWindow = 0.16
    /// How long the cursor takes to fade when the pointer rests, when typing hides it, and to come back.
    static let idleFade = 0.3
    static let typingFade = 0.15
    static let returnFade = 0.12

    public init(telemetry: StudioTelemetry, project: StudioProject, duration: Double, rate: Double = 120) {
        self.init(telemetry: telemetry, project: project, duration: duration, rate: rate, checkCancellation: {})
    }

    /// The same deterministic track, built off the caller's actor and interruptible during a long recording.
    @concurrent
    public static func make(telemetry: StudioTelemetry, project: StudioProject, duration: Double, rate: Double = 120) async throws -> StudioTrack {
        try StudioTrack(telemetry: telemetry, project: project, duration: duration, rate: rate, checkCancellation: { try Task.checkCancellation() })
    }

    init(
        telemetry: StudioTelemetry, project: StudioProject, duration: Double, rate: Double,
        checkCancellation: () throws -> Void
    ) rethrows {
        try checkCancellation()
        self.rate = rate
        width = telemetry.width
        height = telemetry.height
        let count = max(1, Int((duration * rate).rounded(.up)) + 1)
        let step = 1 / rate
        let clicks = telemetry.clicks.sorted { $0.time < $1.time }
        clickAnchors = clicks
        let samples = Self.anchoredSamples(telemetry.samples, clicks: clicks)
        let zooms = project.zooms.sorted { $0.start < $1.start }
        var zoomIndex = 0
        var activeZooms: [StudioProject.Zoom] = []

        // The cursor's spring: a time constant at rest from 0.02 s (barely smoothed) to 0.15 s, shorter the
        // faster the pointer goes, by its velocity averaged over `speedWindow`.
        let smoothing = min(max(project.cursor.smoothing, 0), 1)
        let smoothed = smoothing > 0
        let restTime = Self.cursorQuickest + 0.13 * smoothing
        let speedBlend = 1 - exp(-step / Self.speedWindow)

        var frames: [Frame] = []
        frames.reserveCapacity(count)
        // Whether a zoom is fully in at each frame, for the framing.
        var steady: [Bool] = []
        steady.reserveCapacity(count)
        var index = 0
        var lastMove = -Double.infinity
        var lastRaw: (x: Double, y: Double)?
        var activityPosition: (x: Double, y: Double)?
        var cursor = Self.pointer(at: 0, in: samples, index: &index)
        var cursorVelocity = (x: 0.0, y: 0.0)
        var pointerVelocity = (x: 0.0, y: 0.0)
        var opacity = 1.0
        var clickIndex = 0
        // Typing, shortcuts left out: ⌘S doesn't hide the cursor, as it doesn't on screen.
        let typing = project.cursor.hidesWhileTyping ? telemetry.keys.filter(\.isTyping).map(\.time).sorted() : []
        var typingIndex = 0
        var lastTyped = -Double.infinity

        for frameIndex in 0..<count {
            if frameIndex.isMultiple(of: 512) { try checkCancellation() }
            let time = Double(frameIndex) * step
            let raw = Self.pointer(at: time, in: samples, index: &index)
            // Measure displacement since the last confirmed activity, not since the previous interpolated
            // frame: slow motion accumulates, while sub-point jitter around a resting position does not.
            if activityPosition.map({ hypot(raw.x - $0.x, raw.y - $0.y) > 0.5 }) ?? true {
                lastMove = time
                activityPosition = (raw.x, raw.y)
            }
            let rawVelocity = lastRaw.map { ((raw.x - $0.x) / step, (raw.y - $0.y) / step) } ?? (0, 0)
            lastRaw = (raw.x, raw.y)
            var clicked = false
            while clickIndex < clicks.count, clicks[clickIndex].time <= time {
                lastMove = max(lastMove, clicks[clickIndex].time)
                clickIndex += 1
                clicked = true
            }

            // The cursor: the spring toward the pointer, or the pointer itself (and afresh from it at a click,
            // moving as the pointer moves, so it never stalls there). The speed it loosens and tightens by
            // goes on being read through a click.
            pointerVelocity.x += (rawVelocity.0 - pointerVelocity.x) * speedBlend
            pointerVelocity.y += (rawVelocity.1 - pointerVelocity.y) * speedBlend
            if smoothed, frameIndex > 0, !clicked {
                let omega = 1 / Self.cursorTime(rest: restTime, speed: hypot(pointerVelocity.x, pointerVelocity.y))
                Self.spring(&cursor.x, &cursorVelocity.x, toward: raw.x, omega: omega, step: step)
                Self.spring(&cursor.y, &cursorVelocity.y, toward: raw.y, omega: omega, step: step)
            } else {
                cursor = (raw.x, raw.y, raw.cursor)
                cursorVelocity = clicked ? rawVelocity : (0, 0)
            }
            cursor.cursor = raw.cursor
            // Into the next click, the cursor drawn closes on the pointer.
            var drawn = (x: cursor.x, y: cursor.y)
            if smoothed, clickIndex < clicks.count, clicks[clickIndex].time - time < Self.clickApproach {
                let click = clicks[clickIndex]
                let t = 1 - (click.time - time) / Self.clickApproach
                let eased = t * t * (3 - 2 * t)
                drawn = (cursor.x + (click.x - cursor.x) * eased, cursor.y + (click.y - cursor.y) * eased)
            }

            // Fading while typing, until the pointer moves or clicks after the last key typed, and when the
            // pointer rests.
            while typingIndex < typing.count, typing[typingIndex] <= time {
                lastTyped = typing[typingIndex]
                typingIndex += 1
            }
            if lastTyped > lastMove {
                opacity = max(0, opacity - step / Self.typingFade)
            } else if project.cursor.hidesWhenIdle, time - lastMove > Self.idleDelay {
                opacity = max(0, opacity - step / Self.idleFade)
            } else {
                opacity = min(1, opacity + step / Self.returnFade)
            }

            // How far into a zoom, and whether one is fully in; where the camera looks comes after.
            while zoomIndex < zooms.count, zooms[zoomIndex].start <= time {
                activeZooms.append(zooms[zoomIndex])
                zoomIndex += 1
            }
            activeZooms.removeAll { $0.end < time }
            steady.append(activeZooms.contains { zoom in
                time >= zoom.start + Self.transitionLength(zoom) && time <= zoom.end - Self.transitionLength(zoom)
            })
            frames.append(Frame(
                zoom: Self.zoom(at: time, zooms: activeZooms), centerX: width / 2, centerY: height / 2, cursorX: drawn.x, cursorY: drawn.y,
                cursor: cursor.cursor, cursorOpacity: opacity
            ))
        }
        try StudioFraming.place(
            &frames, steady: steady, zooms: zooms, events: AutoZoom.events(in: telemetry), width: width, height: height, rate: rate,
            checkCancellation: checkCancellation
        )
        try checkCancellation()
        self.frames = frames
    }

    /// The camera and the cursor at `time` (the recording's seconds), between the two nearest samples.
    public func frame(at time: Double) -> Frame {
        guard let last = frames.last else {
            return Frame(zoom: 1, centerX: width / 2, centerY: height / 2, cursorX: 0, cursorY: 0, cursor: 0, cursorOpacity: 0)
        }
        let position = min(max(time * rate, 0), Double(frames.count - 1))
        let lower = Int(position.rounded(.down))
        guard lower < frames.count - 1 else { return last }
        let a = frames[lower], b = frames[lower + 1]
        let t = position - Double(lower)
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        let cursor = anchoredCursor(at: position / rate, lower: lower, a: a, b: b)
        return Frame(
            zoom: mix(a.zoom, b.zoom), centerX: mix(a.centerX, b.centerX), centerY: mix(a.centerY, b.centerY),
            cursorX: cursor.x, cursorY: cursor.y, cursor: a.cursor,
            cursorOpacity: mix(a.cursorOpacity, b.cursorOpacity)
        )
    }

    // MARK: Private

    /// Split the interpolation interval at actual click times. This keeps arbitrary seeks continuous on
    /// both sides of every anchor, without changing the fixed-rate storage used by the camera.
    private func anchoredCursor(at time: Double, lower: Int, a: Frame, b: Frame) -> (x: Double, y: Double) {
        var low = 0, high = clickAnchors.count
        while low < high {
            let middle = (low + high) / 2
            if clickAnchors[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        var left = (time: Double(lower) / rate, x: a.cursorX, y: a.cursorY)
        var right = (time: Double(lower + 1) / rate, x: b.cursorX, y: b.cursorY)
        if low > 0, clickAnchors[low - 1].time >= left.time {
            let click = clickAnchors[low - 1]
            left = (click.time, click.x, click.y)
        }
        if low < clickAnchors.count, clickAnchors[low].time <= right.time {
            let click = clickAnchors[low]
            right = (click.time, click.x, click.y)
        }
        let fraction = right.time > left.time ? (time - left.time) / (right.time - left.time) : 0
        return (left.x + (right.x - left.x) * fraction, left.y + (right.y - left.y) * fraction)
    }

    /// Merge recorded events into the sampled path; a click's coordinates win over a simultaneous sample.
    private static func anchoredSamples(_ samples: [StudioTelemetry.Sample], clicks: [StudioTelemetry.Click]) -> [StudioTelemetry.Sample] {
        guard !clicks.isEmpty else { return samples }
        var result: [StudioTelemetry.Sample] = []
        result.reserveCapacity(samples.count + clicks.count)
        var index = 0
        var cursor = samples.first?.cursor ?? 0
        for click in clicks {
            while index < samples.count, samples[index].time <= click.time {
                cursor = samples[index].cursor
                if samples[index].time < click.time { result.append(samples[index]) }
                index += 1
            }
            if result.last?.time == click.time { result.removeLast() }
            result.append(.init(time: click.time, x: click.x, y: click.y, cursor: cursor))
        }
        result.append(contentsOf: samples[index...])
        return result
    }

    /// How much the picture is zoomed at `time`: easing in at each zoom's start and out at its end, evenly in
    /// scale (its logarithm eased), so each moment of the ease enlarges the picture by the same proportion
    /// rather than rushing at first and crawling at the end.
    static func zoom(at time: Double, zooms: [StudioProject.Zoom]) -> Double {
        var level = 1.0
        for zoom in zooms where time >= zoom.start && time <= zoom.end && zoom.scale > 1 {
            let length = transitionLength(zoom)
            let progress = min(1, (time - zoom.start) / length, (zoom.end - time) / length)
            level = max(level, exp(log(zoom.scale) * easeInOut(max(0, progress))))
        }
        return level
    }

    static func transitionLength(_ zoom: StudioProject.Zoom) -> Double {
        max(0.05, min(transition, (zoom.end - zoom.start) / 3))
    }

    static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// The cursor's spring's time constant, in seconds, while the pointer moves at `speed` points a second: `rest`
    /// when it is still, falling toward `cursorQuickest` as it speeds up, halfway at `referenceSpeed`.
    static func cursorTime(rest: Double, speed: Double) -> Double {
        cursorQuickest + (rest - cursorQuickest) / (1 + speed / referenceSpeed)
    }

    /// One step of a critically damped spring pulling `value` toward `target`.
    static func spring(_ value: inout Double, _ velocity: inout Double, toward target: Double, omega: Double, step: Double) {
        // Exact for a critically damped spring over one step, so it is stable at any rate.
        let x = value - target
        let decay = exp(-omega * step)
        let newX = (x + (velocity + omega * x) * step) * decay
        velocity = (velocity - omega * (velocity + omega * x) * step) * decay
        value = target + newX
    }

    /// The pointer at `time`: between two readings a frame or so apart it moves straight from one to the next;
    /// across a longer gap it rested, so it stays at the earlier one. `index` carries the search forward.
    static func pointer(at time: Double, in samples: [StudioTelemetry.Sample], index: inout Int) -> (x: Double, y: Double, cursor: Int) {
        guard let first = samples.first else { return (0, 0, 0) }
        guard time > first.time else { return (first.x, first.y, first.cursor) }
        while index + 1 < samples.count, samples[index + 1].time <= time { index += 1 }
        let a = samples[index]
        guard index + 1 < samples.count else { return (a.x, a.y, a.cursor) }
        let b = samples[index + 1]
        let gap = b.time - a.time
        guard gap > 0, gap <= 0.05 else { return (a.x, a.y, a.cursor) }
        let t = (time - a.time) / gap
        return (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.cursor)
    }
}
