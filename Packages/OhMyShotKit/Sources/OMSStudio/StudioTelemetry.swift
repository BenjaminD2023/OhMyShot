import CoreGraphics
import Foundation
import OMSCore

/// What the pointer and the keyboard did while a Studio recording ran: where the pointer was and how it
/// looked, every click, and every key, in the recording's own space (points from its top-left corner).
///
/// Times are host-clock seconds while recording; `retimed(start:pauses:)` moves them onto the movie's
/// timeline once the movie's start and its pauses are known.
nonisolated public struct StudioTelemetry: Codable, Equatable, Sendable {
    /// One reading of the pointer.
    public struct Sample: Codable, Equatable, Sendable {
        public var time: Double
        /// Where the pointer was, in the recording's points from its top-left corner; outside the recording
        /// when the pointer was outside it.
        public var x: Double
        public var y: Double
        /// The cursor it showed: an index into `cursors`.
        public var cursor: Int

        public init(time: Double, x: Double, y: Double, cursor: Int) {
            self.time = time
            self.x = x
            self.y = y
            self.cursor = cursor
        }
    }

    /// One look of the cursor, taken from the system as it showed it.
    public struct Cursor: Codable, Equatable, Sendable {
        /// Its picture as a PNG, drawn at `scale` pixels per point.
        public var png: Data
        public var scale: Double
        /// Its size, and the hot spot (the point that clicks), in points from its top-left corner.
        public var width: Double
        public var height: Double
        public var hotSpotX: Double
        public var hotSpotY: Double

        public init(png: Data, scale: Double, width: Double, height: Double, hotSpotX: Double, hotSpotY: Double) {
            self.png = png
            self.scale = scale
            self.width = width
            self.height = height
            self.hotSpotX = hotSpotX
            self.hotSpotY = hotSpotY
        }
    }

    public struct Click: Codable, Equatable, Sendable {
        public enum Button: String, Codable, Sendable {
            case primary
            case secondary
            case other
        }

        public var time: Double
        public var x: Double
        public var y: Double
        public var button: Button

        public init(time: Double, x: Double, y: Double, button: Button) {
            self.time = time
            self.x = x
            self.y = y
            self.button = button
        }
    }

    /// A key pressed, as the keystroke display takes it.
    public struct Key: Codable, Equatable, Sendable {
        public var time: Double
        public var keyCode: UInt16
        /// Control, Option, Shift, and Command, as `NSEvent.ModifierFlags` raw values.
        public var modifiers: UInt
        public var characters: String
        public var keyCharacters: String
        public var isRepeat: Bool

        public init(time: Double, keyCode: UInt16, modifiers: UInt, characters: String, keyCharacters: String, isRepeat: Bool) {
            self.time = time
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.characters = characters
            self.keyCharacters = keyCharacters
            self.isRepeat = isRepeat
        }

        /// A key typed alone under Shortcuts only: when, and nothing of which key, so typing still places
        /// zooms but is never written down.
        public static func unrecorded(time: Double, isRepeat: Bool) -> Key {
            Key(time: time, keyCode: unrecordedKeyCode, modifiers: 0, characters: "", keyCharacters: "", isRepeat: isRepeat)
        }

        /// No key has this code: the code of a press kept only as a press.
        public static let unrecordedKeyCode: UInt16 = 0xFFFF
    }

    /// The recording's size in points, and its pixels per point.
    public var width: Double
    public var height: Double
    public var pixelsPerPoint: Double
    public var samples: [Sample]
    public var cursors: [Cursor]
    public var clicks: [Click]
    public var keys: [Key]
    /// Which keys were written down, as Settings › Recording › Keystrokes chose: under Shortcuts only, a
    /// key typed alone is kept only as a press (`Key.unrecorded`), so no typing is written down. Nil when
    /// keys weren't written down at all.
    public var keystrokeMode: KeystrokeMode?

    public init(
        width: Double, height: Double, pixelsPerPoint: Double, samples: [Sample] = [], cursors: [Cursor] = [], clicks: [Click] = [],
        keys: [Key] = [], keystrokeMode: KeystrokeMode? = nil
    ) {
        self.width = width
        self.height = height
        self.pixelsPerPoint = pixelsPerPoint
        self.samples = samples
        self.cursors = cursors
        self.clicks = clicks
        self.keys = keys
        self.keystrokeMode = keystrokeMode
    }

    /// The same, on the movie's timeline: seconds from `start` (the movie's first frame, host seconds), with
    /// what happened during `pauses` left out and what came after each pause moved earlier by its length.
    /// The pointer's last place before the start begins the movie.
    public func retimed(start: Double, pauses: [ClosedRange<Double>]) -> StudioTelemetry {
        let pauses = pauses.sorted { $0.lowerBound < $1.lowerBound }
        func movieTime(_ time: Double) -> Double? {
            var offset = 0.0
            for pause in pauses {
                if time < pause.lowerBound { break }
                if time < pause.upperBound { return nil }
                offset += pause.upperBound - pause.lowerBound
            }
            return time - start - offset
        }
        var moved = self
        var samples: [Sample] = []
        var before: Sample?
        for sample in self.samples {
            guard let time = movieTime(sample.time) else { continue }
            if time < 0 {
                before = sample
                continue
            }
            if samples.isEmpty, let first = before, time > 0 {
                samples.append(Sample(time: 0, x: first.x, y: first.y, cursor: first.cursor))
            }
            samples.append(Sample(time: time, x: sample.x, y: sample.y, cursor: sample.cursor))
        }
        if samples.isEmpty, let last = before {
            samples.append(Sample(time: 0, x: last.x, y: last.y, cursor: last.cursor))
        }
        moved.samples = samples
        moved.clicks = clicks.compactMap { click in
            guard let time = movieTime(click.time), time >= 0 else { return nil }
            return Click(time: time, x: click.x, y: click.y, button: click.button)
        }
        moved.keys = keys.compactMap { key in
            guard let time = movieTime(key.time), time >= 0 else { return nil }
            var moved = key
            moved.time = time
            return moved
        }
        return moved
    }
}
