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
        /// It fades away while typing, as the system hides it, and back when the pointer moves or clicks.
        public var hidesWhileTyping: Bool
        /// A ring where each click lands.
        public var showsClicks: Bool

        public init(size: Double = 1.5, smoothing: Double = 0.5, hidesWhenIdle: Bool = true, hidesWhileTyping: Bool = true, showsClicks: Bool = true) {
            self.size = size
            self.smoothing = smoothing
            self.hidesWhenIdle = hidesWhenIdle
            self.hidesWhileTyping = hidesWhileTyping
            self.showsClicks = showsClicks
        }

        private enum CodingKeys: String, CodingKey {
            case size, smoothing, hidesWhenIdle, hidesWhileTyping, showsClicks
        }

        /// A cursor saved before a setting existed takes its default.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Cursor()
            size = try container.decodeIfPresent(Double.self, forKey: .size) ?? defaults.size
            smoothing = try container.decodeIfPresent(Double.self, forKey: .smoothing) ?? defaults.smoothing
            hidesWhenIdle = try container.decodeIfPresent(Bool.self, forKey: .hidesWhenIdle) ?? defaults.hidesWhenIdle
            hidesWhileTyping = try container.decodeIfPresent(Bool.self, forKey: .hidesWhileTyping) ?? defaults.hidesWhileTyping
            showsClicks = try container.decodeIfPresent(Bool.self, forKey: .showsClicks) ?? defaults.showsClicks
        }
    }

    /// How the camera recorded beside the recording is shown: in a bubble in a corner of the recording, never
    /// zoomed with it, as it sat on screen.
    public struct Camera: Codable, Equatable, Sendable {
        public enum Shape: String, Codable, CaseIterable, Sendable {
            case circle
            case roundedSquare
        }

        public enum Corner: String, Codable, CaseIterable, Sendable {
            case bottomLeft
            case bottomRight
            case topLeft
            case topRight
        }

        public var isShown: Bool
        public var shape: Shape
        /// The bubble's side in the recording's points: the recording bar's sizes, 120, 180, or 260.
        public var size: Double
        public var corner: Corner
        /// As a mirror shows it, as people expect to see themselves.
        public var mirrored: Bool

        public init(isShown: Bool = true, shape: Shape = .circle, size: Double = 180, corner: Corner = .bottomLeft, mirrored: Bool = true) {
            self.isShown = isShown
            self.shape = shape
            self.size = size
            self.corner = corner
            self.mirrored = mirrored
        }

        private enum CodingKeys: String, CodingKey {
            case isShown, shape, size, corner, mirrored
        }

        /// A camera saved before a setting existed takes its default.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Camera()
            isShown = try container.decodeIfPresent(Bool.self, forKey: .isShown) ?? defaults.isShown
            shape = try container.decodeIfPresent(Shape.self, forKey: .shape) ?? defaults.shape
            size = try container.decodeIfPresent(Double.self, forKey: .size) ?? defaults.size
            corner = try container.decodeIfPresent(Corner.self, forKey: .corner) ?? defaults.corner
            mirrored = try container.decodeIfPresent(Bool.self, forKey: .mirrored) ?? defaults.mirrored
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
    /// The camera, when one was recorded beside the recording.
    public var camera: Camera
    /// The picture blurs along its way while the camera zooms and pans, as a film camera's would.
    public var motionBlur: Bool

    /// The defaults are the annotation editor's background card's: the same padding, corners, and shadow.
    public init(
        background: Background = .gradient("sky"), padding: Double = 0.08, cornerRadius: Double = 12, shadow: Double = 0.5,
        aspect: Aspect = .auto, cursor: Cursor = Cursor(), zooms: [Zoom] = [], cuts: [ClosedRange<Double>] = [], showsKeys: Bool = true,
        keystrokeMode: KeystrokeMode = .all, automaticZooms: Bool = true, camera: Camera = Camera(), motionBlur: Bool = true
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
        self.camera = camera
        self.motionBlur = motionBlur
    }

    private enum CodingKeys: String, CodingKey {
        case background, padding, cornerRadius, shadow, aspect, cursor, zooms, cuts, showsKeys, keystrokeMode, automaticZooms, camera, motionBlur
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
        camera = try container.decodeIfPresent(Camera.self, forKey: .camera) ?? defaults.camera
        motionBlur = try container.decodeIfPresent(Bool.self, forKey: .motionBlur) ?? defaults.motionBlur
    }
}
