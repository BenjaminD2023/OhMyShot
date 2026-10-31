import AppKit
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

    /// A press, where and when, and its release.
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
        /// When the button came up and where: nil when that wasn't seen, as in recordings made before releases
        /// were written down, for a button still held when recording stopped, or for one released in a pause.
        /// Set together or not at all.
        public var releaseTime: Double?
        public var releaseX: Double?
        public var releaseY: Double?

        /// How far, in points, the pointer moves between the press and the release for a drag rather than a click.
        public static let dragDistance = 4.0

        public init(
            time: Double, x: Double, y: Double, button: Button, releaseTime: Double? = nil, releaseX: Double? = nil, releaseY: Double? = nil
        ) {
            self.time = time
            self.x = x
            self.y = y
            self.button = button
            self.releaseTime = releaseTime
            self.releaseX = releaseX
            self.releaseY = releaseY
        }

        /// Whether it was released `dragDistance` or farther from where it was pressed.
        public var isDrag: Bool {
            guard releaseTime != nil, let releaseX, let releaseY else { return false }
            return hypot(releaseX - x, releaseY - y) >= Self.dragDistance
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

        /// A press that types, rather than a shortcut: held with none of Command, Control, and Option, and not
        /// a function key. Presses kept only as presses were typing.
        public var isTyping: Bool {
            !KeystrokeCaption.isShortcut(Keystroke(
                keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: modifiers), characters: characters,
                keyCharacters: keyCharacters, isRepeat: isRepeat
            ))
        }
    }

    /// The camera, recorded beside the recording in a movie of its own (`StudioFiles.camera`): where that
    /// movie begins, when the camera filled what was recorded, and how its bubble looked.
    public struct Camera: Codable, Equatable, Sendable {
        /// Where the camera's movie begins: host seconds while recording; once retimed, the recording's
        /// seconds, negative when the camera's began first.
        public var start: Double
        /// When the camera filled what was recorded, in place of its bubble.
        public var fills: [ClosedRange<Double>]
        /// The bubble as it was while recording, for Studio to begin with: its shape, side, corner, mirror.
        public var bubble: StudioProject.Camera

        public init(start: Double, fills: [ClosedRange<Double>] = [], bubble: StudioProject.Camera) {
            self.start = start
            self.fills = fills
            self.bubble = bubble
        }
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
    /// The camera recorded beside the recording; nil when none was.
    public var camera: Camera?
    /// The camera's bubble showed while recording, but no movie of it could be kept: Studio says so where its
    /// settings would be.
    public var cameraFailed: Bool?

    public init(
        width: Double, height: Double, pixelsPerPoint: Double, samples: [Sample] = [], cursors: [Cursor] = [], clicks: [Click] = [],
        keys: [Key] = [], keystrokeMode: KeystrokeMode? = nil, camera: Camera? = nil
    ) {
        self.width = width
        self.height = height
        self.pixelsPerPoint = pixelsPerPoint
        self.samples = samples
        self.cursors = cursors
        self.clicks = clicks
        self.keys = keys
        self.keystrokeMode = keystrokeMode
        self.camera = camera
    }

    /// The same, on the movie's timeline: seconds from `start` (the movie's first frame, host seconds), with
    /// what happened during `pauses` left out and what came after each pause moved earlier by its length.
    /// The pointer's last place before the start begins the movie. A release in a pause is left out with
    /// the rest of the pause, its press kept as a click. The camera's times, which span the pauses, take the
    /// movie's time where each pause was cut out.
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
        func spanningTime(_ time: Double) -> Double {
            var offset = 0.0
            for pause in pauses {
                if time < pause.lowerBound { break }
                if time < pause.upperBound { return pause.lowerBound - start - offset }
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
            var moved = click
            moved.time = time
            moved.releaseTime = click.releaseTime.flatMap(movieTime)
            if moved.releaseTime == nil {
                moved.releaseX = nil
                moved.releaseY = nil
            }
            return moved
        }
        moved.keys = keys.compactMap { key in
            guard let time = movieTime(key.time), time >= 0 else { return nil }
            var moved = key
            moved.time = time
            return moved
        }
        moved.camera = camera.map { camera in
            var moved = camera
            moved.start = spanningTime(camera.start)
            moved.fills = camera.fills.compactMap { fill in
                let range = max(0, spanningTime(fill.lowerBound))...max(0, spanningTime(fill.upperBound))
                return range.upperBound > range.lowerBound ? range : nil
            }
            return moved
        }
        return moved
    }
}
