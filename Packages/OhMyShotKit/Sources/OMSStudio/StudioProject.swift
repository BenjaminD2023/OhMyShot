import CoreGraphics
import Foundation
import OMSCore

/// How a Studio recording is filmed again: everything the Studio window sets, kept in the recording's
/// project beside the telemetry so it can be set again later.
nonisolated public struct StudioProject: Codable, Equatable, Sendable {
    public enum Background: Codable, Equatable, Sendable {
        /// One of the built-in gradients, by name: the annotation editor's backgrounds.
        case gradient(String)
        /// A plain color, sRGB from 0 to 1.
        case color(red: Double, green: Double, blue: Double)
    }

    /// The movie's shape: the recording's own with the background around it, or a fixed one.
    public enum Aspect: String, Codable, CaseIterable, Sendable {
        case auto
        case widescreen
        case standard
        case square
        case vertical

        /// Width over height, or nil for the recording's own.
        public var ratio: Double? {
            switch self {
            case .auto: nil
            case .widescreen: 16.0 / 9
            case .standard: 4.0 / 3
            case .square: 1
            case .vertical: 9.0 / 16
            }
        }
    }

    /// A stretch of the movie drawn larger, following the pointer.
    public struct Zoom: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        /// Seconds into the recording; the zoom eases in from `start` and out until `end`.
        public var start: Double
        public var end: Double
        /// How much larger the picture is drawn: 2 shows a quarter of it.
        public var scale: Double
        /// Placed from clicks and typing, rather than by hand.
        public var isAutomatic: Bool

        public init(id: UUID = UUID(), start: Double, end: Double, scale: Double, isAutomatic: Bool) {
            self.id = id
            self.start = start
            self.end = end
            self.scale = scale
            self.isAutomatic = isAutomatic
        }
    }

    /// How the cursor is drawn again.
    public struct Cursor: Codable, Equatable, Sendable {
        /// Its size against what it was on screen.
        public var size: Double
        /// How much its path is smoothed, from 0 (as recorded) to 1.
        public var smoothing: Double
        /// It fades away after the pointer rests, and back when it moves.
        public var hidesWhenIdle: Bool
        /// A ring where each click lands.
        public var showsClicks: Bool

        public init(size: Double = 1.5, smoothing: Double = 0.5, hidesWhenIdle: Bool = true, showsClicks: Bool = true) {
            self.size = size
            self.smoothing = smoothing
            self.hidesWhenIdle = hidesWhenIdle
            self.showsClicks = showsClicks
        }
    }

    public var background: Background
    /// The room around the recording, as a fraction of its shorter side.
    public var padding: Double
    /// The recording's corners, in its points.
    public var cornerRadius: Double
    /// The shadow under the recording, from 0 (none) to 1.
    public var shadow: Double
    public var aspect: Aspect
    public var cursor: Cursor
    public var zooms: [Zoom]
    /// Stretches of the recording left out of the movie, in its seconds.
    public var cuts: [ClosedRange<Double>]
    /// The keys pressed, shown at the foot of the movie, when they were written down.
    public var showsKeys: Bool
    /// Which of them: all, or shortcuts only (never more than were written down).
    public var keystrokeMode: KeystrokeMode
    /// Zooms are placed on the clicks and the typing; the ones placed or changed by hand stay either way.
    public var automaticZooms: Bool

    /// The defaults are the annotation editor's background card's: the same padding, corners, and shadow.
    public init(
        background: Background = .gradient("sky"), padding: Double = 0.08, cornerRadius: Double = 12, shadow: Double = 0.5,
        aspect: Aspect = .auto, cursor: Cursor = Cursor(), zooms: [Zoom] = [], cuts: [ClosedRange<Double>] = [], showsKeys: Bool = true,
        keystrokeMode: KeystrokeMode = .all, automaticZooms: Bool = true
    ) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.aspect = aspect
        self.cursor = cursor
        self.zooms = zooms
        self.cuts = cuts
        self.showsKeys = showsKeys
        self.keystrokeMode = keystrokeMode
        self.automaticZooms = automaticZooms
    }

    private enum CodingKeys: String, CodingKey {
        case background, padding, cornerRadius, shadow, aspect, cursor, zooms, cuts, showsKeys, keystrokeMode, automaticZooms
    }

    /// A project saved before a setting existed takes its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StudioProject()
        background = try container.decodeIfPresent(Background.self, forKey: .background) ?? defaults.background
        padding = try container.decodeIfPresent(Double.self, forKey: .padding) ?? defaults.padding
        cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? defaults.cornerRadius
        shadow = try container.decodeIfPresent(Double.self, forKey: .shadow) ?? defaults.shadow
        aspect = try container.decodeIfPresent(Aspect.self, forKey: .aspect) ?? defaults.aspect
        cursor = try container.decodeIfPresent(Cursor.self, forKey: .cursor) ?? defaults.cursor
        zooms = try container.decodeIfPresent([Zoom].self, forKey: .zooms) ?? []
        cuts = try container.decodeIfPresent([ClosedRange<Double>].self, forKey: .cuts) ?? []
        showsKeys = try container.decodeIfPresent(Bool.self, forKey: .showsKeys) ?? defaults.showsKeys
        keystrokeMode = try container.decodeIfPresent(KeystrokeMode.self, forKey: .keystrokeMode) ?? defaults.keystrokeMode
        automaticZooms = try container.decodeIfPresent(Bool.self, forKey: .automaticZooms) ?? defaults.automaticZooms
    }
}
