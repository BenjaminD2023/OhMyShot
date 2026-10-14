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
/// The camera eases into each zoom toward the pointer and, fully zoomed, moves only when the cursor nears the
/// edge of what it shows, through a slower spring, never past the recording's edges.
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
        self.rate = rate
        width = telemetry.width
        height = telemetry.height
        let count = max(1, Int((duration * rate).rounded(.up)) + 1)
        let step = 1 / rate
        let samples = telemetry.samples
        let zooms = project.zooms.sorted { $0.start < $1.start }

        // The cursor's spring: a time constant at rest from 0.02 s (barely smoothed) to 0.15 s, shorter the
        // faster the pointer goes, by its velocity averaged over `speedWindow`.
        let smoothing = min(max(project.cursor.smoothing, 0), 1)
        let smoothed = smoothing > 0
        let restTime = Self.cursorQuickest + 0.13 * smoothing
        let speedBlend = 1 - exp(-step / Self.speedWindow)
        // The camera's spring is slower: it should glide, not chase.
        let cameraOmega = 1 / 0.35

        var frames: [Frame] = []
        frames.reserveCapacity(count)
        var index = 0
        var lastMove = -Double.infinity
        var lastRaw: (x: Double, y: Double)?
        var cursor = Self.pointer(at: 0, in: samples, index: &index)
        var cursorVelocity = (x: 0.0, y: 0.0)
        var pointerVelocity = (x: 0.0, y: 0.0)
        var center = (x: cursor.x, y: cursor.y)
        var centerVelocity = (x: 0.0, y: 0.0)
        var opacity = 1.0
        var clickIndex = 0
        let clicks = telemetry.clicks.map(\.time).sorted()
        // Typing, shortcuts left out: ⌘S doesn't hide the cursor, as it doesn't on screen.
        let typing = project.cursor.hidesWhileTyping ? telemetry.keys.filter(\.isTyping).map(\.time).sorted() : []
        var typingIndex = 0
        var lastTyped = -Double.infinity

        for frameIndex in 0..<count {
            let time = Double(frameIndex) * step
            let raw = Self.pointer(at: time, in: samples, index: &index)
            if let last = lastRaw, hypot(raw.x - last.x, raw.y - last.y) > 0.5 { lastMove = time }
            if lastRaw == nil { lastMove = time }
            let rawVelocity = lastRaw.map { ((raw.x - $0.x) / step, (raw.y - $0.y) / step) } ?? (0, 0)
            lastRaw = (raw.x, raw.y)
            var clicked = false
            while clickIndex < clicks.count, clicks[clickIndex] <= time {
                lastMove = max(lastMove, clicks[clickIndex])
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
            if smoothed, clickIndex < clicks.count, clicks[clickIndex] - time < Self.clickApproach {
                let t = 1 - (clicks[clickIndex] - time) / Self.clickApproach
                let eased = t * t * (3 - 2 * t)
                drawn = (cursor.x + (raw.x - cursor.x) * eased, cursor.y + (raw.y - cursor.y) * eased)
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

            // The camera: how far into a zoom, and where it looks.
            let zoom = Self.zoom(at: time, zooms: zooms)
            let fullyIn = zooms.contains { zoom in
                time >= zoom.start + Self.transitionLength(zoom) && time <= zoom.end - Self.transitionLength(zoom)
            }
            var target = drawn
            if fullyIn {
                // Fully zoomed, the camera moves only to keep the cursor within the middle of what it shows.
                let reachX = width / zoom * 0.3, reachY = height / zoom * 0.3
                target = (
                    min(max(center.x, drawn.x - reachX), drawn.x + reachX),
                    min(max(center.y, drawn.y - reachY), drawn.y + reachY)
                )
            }
            if frameIndex == 0 {
                center = target
            } else {
                Self.spring(&center.x, &centerVelocity.x, toward: target.x, omega: cameraOmega, step: step)
                Self.spring(&center.y, &centerVelocity.y, toward: target.y, omega: cameraOmega, step: step)
            }
            let halfWidth = width / zoom / 2, halfHeight = height / zoom / 2
            let clampedX = min(max(center.x, halfWidth), width - halfWidth)
            let clampedY = min(max(center.y, halfHeight), height - halfHeight)
            frames.append(Frame(
                zoom: zoom, centerX: clampedX, centerY: clampedY, cursorX: drawn.x, cursorY: drawn.y, cursor: cursor.cursor,
                cursorOpacity: opacity
            ))
        }
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
        return Frame(
            zoom: mix(a.zoom, b.zoom), centerX: mix(a.centerX, b.centerX), centerY: mix(a.centerY, b.centerY),
            cursorX: mix(a.cursorX, b.cursorX), cursorY: mix(a.cursorY, b.cursorY), cursor: a.cursor,
            cursorOpacity: mix(a.cursorOpacity, b.cursorOpacity)
        )
    }

    // MARK: Private

    /// How much the picture is zoomed at `time`: easing in at each zoom's start and out at its end.
    static func zoom(at time: Double, zooms: [StudioProject.Zoom]) -> Double {
        var level = 1.0
        for zoom in zooms where time >= zoom.start && time <= zoom.end {
            let length = transitionLength(zoom)
            let progress = min(1, (time - zoom.start) / length, (zoom.end - time) / length)
            level = max(level, 1 + (zoom.scale - 1) * easeInOut(max(0, progress)))
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
