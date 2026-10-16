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

    /// How closely the movie is encoded: a smaller file or a sharper picture. Standard is the quality the
    /// recording itself is made at.
    public enum Quality: String, Codable, CaseIterable, Sendable {
        case smaller
        case standard
        case best
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

    /// How a click shows: a ring that widens as it fades, or ripples that spread one after another.
    public enum ClickEffect: String, Codable, CaseIterable, Sendable {
        case ring
        case ripple
    }

    /// The color of a click's effect: the user's accent, as the rings shown while recording take it, or one of
    /// the system's colors.
    public enum ClickColor: String, Codable, CaseIterable, Sendable {
        case accent
        case red
        case orange
        case yellow
        case green
        case blue
        case purple
        case white

        /// The color in sRGB from 0 to 1; nil for the accent, which is the user's to choose.
        public var rgb: (red: Double, green: Double, blue: Double)? {
            switch self {
            case .accent: nil
            case .red: (1, 0.231, 0.188)
            case .orange: (1, 0.584, 0)
            case .yellow: (1, 0.8, 0)
            case .green: (0.204, 0.78, 0.349)
            case .blue: (0, 0.478, 1)
            case .purple: (0.686, 0.322, 0.871)
            case .white: (1, 1, 1)
            }
        }
    }

    /// How the cursor is drawn again.
    public struct Cursor: Codable, Equatable, Sendable {
        /// What is drawn for the pointer.
        public enum Style: String, Codable, CaseIterable, Sendable {
            /// The cursor as the system showed it: an arrow, an I-beam over text, a hand over a link.
            case recorded
            /// An arrow at every moment, drawn sharp at any size, where the system showed another cursor.
            case arrow
            /// The cursor as recorded, with a soft circle of light under it.
            case highlight
        }

        /// Its size against what it was on screen.
        public var size: Double
        /// How much its path is smoothed, from 0 (as recorded) to 1.
        public var smoothing: Double
        /// It fades away after the pointer rests, and back when it moves.
        public var hidesWhenIdle: Bool
        /// It fades away while typing, as the system hides it, and back when the pointer moves or clicks.
        public var hidesWhileTyping: Bool
        /// An effect where each click lands.
        public var showsClicks: Bool
        public var style: Style
        /// Which effect, while clicks show.
        public var clickEffect: ClickEffect
        public var clickColor: ClickColor

        public init(
            size: Double = 1.5, smoothing: Double = 0.5, hidesWhenIdle: Bool = true, hidesWhileTyping: Bool = true, showsClicks: Bool = true,
            style: Style = .recorded, clickEffect: ClickEffect = .ring, clickColor: ClickColor = .accent
        ) {
            self.size = size
            self.smoothing = smoothing
            self.hidesWhenIdle = hidesWhenIdle
            self.hidesWhileTyping = hidesWhileTyping
            self.showsClicks = showsClicks
            self.style = style
            self.clickEffect = clickEffect
            self.clickColor = clickColor
        }

        private enum CodingKeys: String, CodingKey {
            case size, smoothing, hidesWhenIdle, hidesWhileTyping, showsClicks, style, clickEffect, clickColor
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
            // A name from a newer version, unknown here, takes the default rather than losing the project.
            style = (try? container.decodeIfPresent(Style.self, forKey: .style)) ?? defaults.style
            clickEffect = (try? container.decodeIfPresent(ClickEffect.self, forKey: .clickEffect)) ?? defaults.clickEffect
            clickColor = (try? container.decodeIfPresent(ClickColor.self, forKey: .clickColor)) ?? defaults.clickColor
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

        /// How the camera and the recording share the movie.
        public enum Layout: String, Codable, CaseIterable, Sendable {
            /// The camera in a bubble in a corner of the recording, as it sat on screen.
            case pictureInPicture
            /// The recording and the camera's own picture side by side, the movie wider for it.
            case sideBySide
            /// The camera fills the movie, where the recording was.
            case cameraOnly
            /// The recording alone: the camera hidden.
            case screenOnly
        }

        /// Which side of the recording the camera's picture takes in the side-by-side layout.
        public enum Side: String, Codable, CaseIterable, Sendable {
            case left
            case right
        }

        /// The layout of the movie where no stretch of the timeline says otherwise.
        public var layout: Layout
        public var shape: Shape
        /// The bubble's side in the recording's points: the recording bar's sizes, 120, 180, or 260.
        public var size: Double
        public var corner: Corner
        /// As a mirror shows it, as people expect to see themselves.
        public var mirrored: Bool
        public var side: Side
        /// The times the camera filled what was recorded are stretches of their own (`cameraSegments`), no
        /// longer read from the recording. False until Studio makes them so, as it opens a project.
        public var recordedFillsAreSegments: Bool

        /// Whether the camera shows at all: every layout but screen only. Hiding it is choosing screen only,
        /// and showing it again brings back the bubble.
        public var isShown: Bool {
            get { layout != .screenOnly }
            set {
                if newValue { if layout == .screenOnly { layout = .pictureInPicture } } else { layout = .screenOnly }
            }
        }

        /// - Parameter layout: how the camera is shown; nil takes the bubble, or screen only without `isShown`.
        public init(
            isShown: Bool = true, shape: Shape = .circle, size: Double = 180, corner: Corner = .bottomLeft, mirrored: Bool = true,
            layout: Layout? = nil, side: Side = .right, recordedFillsAreSegments: Bool = false
        ) {
            self.layout = layout ?? (isShown ? .pictureInPicture : .screenOnly)
            self.shape = shape
            self.size = size
            self.corner = corner
            self.mirrored = mirrored
            self.side = side
            self.recordedFillsAreSegments = recordedFillsAreSegments
        }

        /// `isShown` stays in what is saved, so a version that knows no layouts still hides the camera when
        /// the layout is screen only.
        private enum CodingKeys: String, CodingKey {
            case isShown, shape, size, corner, mirrored, layout, side, recordedFillsAreSegments
        }

        /// A camera saved before a setting existed takes its default; one saved before layouts shows its
        /// bubble, or nothing when it was hidden.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Camera()
            let shown = try container.decodeIfPresent(Bool.self, forKey: .isShown) ?? true
            // A layout from a newer version, unknown here, takes the one the old setting implies.
            layout = (try? container.decodeIfPresent(Layout.self, forKey: .layout)) ?? (shown ? .pictureInPicture : .screenOnly)
            shape = try container.decodeIfPresent(Shape.self, forKey: .shape) ?? defaults.shape
            size = try container.decodeIfPresent(Double.self, forKey: .size) ?? defaults.size
            corner = try container.decodeIfPresent(Corner.self, forKey: .corner) ?? defaults.corner
            mirrored = try container.decodeIfPresent(Bool.self, forKey: .mirrored) ?? defaults.mirrored
            side = (try? container.decodeIfPresent(Side.self, forKey: .side)) ?? defaults.side
            recordedFillsAreSegments = try container.decodeIfPresent(Bool.self, forKey: .recordedFillsAreSegments) ?? defaults.recordedFillsAreSegments
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(isShown, forKey: .isShown)
            try container.encode(layout, forKey: .layout)
            try container.encode(shape, forKey: .shape)
            try container.encode(size, forKey: .size)
            try container.encode(corner, forKey: .corner)
            try container.encode(mirrored, forKey: .mirrored)
            try container.encode(side, forKey: .side)
            try container.encode(recordedFillsAreSegments, forKey: .recordedFillsAreSegments)
        }
    }

    /// A stretch of the movie where the camera is shown another way than elsewhere: in its bubble, filling
    /// the movie, or not at all. Side by side widens the whole movie, so a stretch is never that.
    public struct CameraSegment: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        /// Seconds into the recording.
        public var start: Double
        public var end: Double
        public var layout: Camera.Layout

        public init(id: UUID = UUID(), start: Double, end: Double, layout: Camera.Layout) {
            self.id = id
            self.start = start
            self.end = end
            self.layout = layout
        }

        private enum CodingKeys: String, CodingKey {
            case id, start, end, layout
        }

        /// A layout from a newer version, unknown here, shows the camera in its bubble, as the plan takes a
        /// stretch of Side by side.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            start = try container.decode(Double.self, forKey: .start)
            end = try container.decode(Double.self, forKey: .end)
            layout = (try? container.decode(Camera.Layout.self, forKey: .layout)) ?? .pictureInPicture
        }

        /// The identifier of the stretch the camera's fill from `start` to `end` becomes, made from those times
        /// so that taking the same fill twice (a saved project opened again, one in the history compared with
        /// one on disk) makes the same stretch.
        static func adoptedID(start: Double, end: Double) -> UUID {
            let bits = [start.bitPattern, end.bitPattern]
            let bytes = bits.flatMap { word in (0..<8).map { UInt8(truncatingIfNeeded: word >> UInt64(56 - 8 * $0)) } }
            return UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
            ))
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
    /// Stretches of the movie that show the camera another way than its layout does, in order.
    public var cameraSegments: [CameraSegment]
    /// The picture blurs along its way while the camera zooms and pans, as a film camera's would.
    public var motionBlur: Bool
    /// How closely the exported movie is encoded.
    public var quality: Quality

    /// The defaults are the annotation editor's background card's: the same padding, corners, and shadow.
    public init(
        background: Background = .gradient("sky"), padding: Double = 0.08, cornerRadius: Double = 12, shadow: Double = 0.5,
        aspect: Aspect = .auto, cursor: Cursor = Cursor(), zooms: [Zoom] = [], cuts: [ClosedRange<Double>] = [], showsKeys: Bool = true,
        keystrokeMode: KeystrokeMode = .all, automaticZooms: Bool = true, camera: Camera = Camera(), motionBlur: Bool = true,
        quality: Quality = .standard, cameraSegments: [CameraSegment] = []
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
        self.cameraSegments = cameraSegments
        self.motionBlur = motionBlur
        self.quality = quality
    }

    private enum CodingKeys: String, CodingKey {
        case background, padding, cornerRadius, shadow, aspect, cursor, zooms, cuts, showsKeys, keystrokeMode, automaticZooms, camera, cameraSegments, motionBlur, quality
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
        cameraSegments = try container.decodeIfPresent([CameraSegment].self, forKey: .cameraSegments) ?? []
        motionBlur = try container.decodeIfPresent(Bool.self, forKey: .motionBlur) ?? defaults.motionBlur
        quality = try container.decodeIfPresent(Quality.self, forKey: .quality) ?? defaults.quality
    }

    /// Makes the times the camera filled what was recorded (`fills`, in the recording's seconds) stretches of
    /// the timeline, camera only, so they can be moved and removed like any other; the movie is the same. Done
    /// once: a project that has them as stretches already, or hides the camera (which kept them hidden), is left.
    public mutating func adoptRecordedFills(_ fills: [ClosedRange<Double>], duration: Double) {
        guard !camera.recordedFillsAreSegments, camera.layout != .screenOnly else { return }
        camera.recordedFillsAreSegments = true
        // Where the camera filled, in the room the project's own stretches leave.
        let covered = cameraSegments.map { (start: $0.start, end: $0.end) }
        for part in StudioCameraPlan.parts(of: fills, outside: covered) {
            let start = max(0, part.lowerBound), end = min(duration, part.upperBound)
            guard end - start >= Self.shortestSegment else { continue }
            cameraSegments.append(CameraSegment(id: CameraSegment.adoptedID(start: start, end: end), start: start, end: end, layout: .cameraOnly))
        }
        cameraSegments.sort { $0.start < $1.start }
    }

    /// The project as Studio opens it: the times the camera filled what was recorded are stretches by then.
    /// Projects are compared in this form, so one kept before being opened equals the same one opened and kept.
    public func opened(for telemetry: StudioTelemetry, duration: Double) -> StudioProject {
        var project = self
        if let camera = telemetry.camera { project.adoptRecordedFills(camera.fills, duration: duration) }
        return project
    }

    /// The shortest stretch of the timeline for the camera's layout, in seconds.
    public static let shortestSegment = 0.5
}
