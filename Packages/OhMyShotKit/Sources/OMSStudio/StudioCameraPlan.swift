import Foundation

/// When the camera shows, and how, worked out once from the project: its layout for the movie, the
/// stretches that show it another way (in its bubble, filling the movie, or not at all), and, until they are
/// made stretches of their own, the times the camera filled what was recorded.
///
/// Side by side makes the whole movie wider to hold the camera's picture, so it can't come and go: with it,
/// there are no stretches and nothing fills.
///
/// From one layout to the next the picture changes over `fade`. What belongs to the layout going away (the
/// bubble, or the camera filling the movie) fades out over the first half and what belongs to the one coming
/// fades in over the second, so the person is never shown twice; when only one of the two has anything to fade,
/// it takes the whole time.
nonisolated struct StudioCameraPlan: Equatable, Sendable {
    typealias Layout = StudioProject.Camera.Layout

    /// A stretch of the recording (its seconds) shown in `layout`.
    struct Stretch: Equatable, Sendable {
        var start: Double
        var end: Double
        var layout: Layout
    }

    /// What is drawn of the camera: how much of its bubble, and how much of its fill of the movie.
    struct Levels: Equatable, Sendable {
        var bubble: Double
        var fill: Double
    }

    /// Where a layout begins, until the next one does.
    private struct Piece: Equatable, Sendable {
        var start: Double
        var layout: Layout
    }

    /// How long a change of layout takes.
    static let fade = 0.25

    /// The layout wherever no stretch says otherwise.
    let base: Layout
    /// In order and never overlapping.
    let stretches: [Stretch]
    /// The base and the stretches laid end to end, the first from before the recording.
    private let pieces: [Piece]

    /// - Parameters:
    ///   - segments: the stretches the project sets.
    ///   - recordedFills: where the camera filled what was recorded, in the recording's seconds. They make
    ///     camera-only stretches too, in the room the project's own leave, while the project's layout is the
    ///     bubble and it hasn't taken them as stretches of its own (`recordedFillsAreSegments`).
    init(camera: StudioProject.Camera, segments: [StudioProject.CameraSegment], recordedFills: [ClosedRange<Double>]) {
        base = camera.layout
        guard camera.layout != .sideBySide else {
            stretches = []
            pieces = [Piece(start: -.infinity, layout: camera.layout)]
            return
        }
        // The project's own, none over the one before it, none side by side.
        var own: [Stretch] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let start = max(segment.start, own.last?.end ?? -.infinity)
            guard segment.end > start else { continue }
            own.append(Stretch(start: start, end: segment.end, layout: segment.layout == .sideBySide ? .pictureInPicture : segment.layout))
        }
        var all = own
        if camera.layout == .pictureInPicture, !camera.recordedFillsAreSegments {
            let covered = own.map { (start: $0.start, end: $0.end) }
            all += Self.parts(of: recordedFills, outside: covered).map { Stretch(start: $0.lowerBound, end: $0.upperBound, layout: .cameraOnly) }
        }
        all.sort { $0.start < $1.start }
        // Fills that overlap or touch are one stretch of the camera filling.
        var merged: [Stretch] = []
        for stretch in all {
            if var last = merged.last, last.layout == stretch.layout, stretch.start <= last.end {
                last.end = max(last.end, stretch.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(stretch)
            }
        }
        stretches = merged
        var pieces = [Piece(start: -.infinity, layout: camera.layout)]
        func add(_ piece: Piece) {
            // A layout that follows itself is no change.
            if pieces.last?.layout != piece.layout { pieces.append(piece) }
        }
        var lastEnd: Double?
        for stretch in merged {
            // The base is back between stretches that don't touch.
            if let lastEnd, stretch.start > lastEnd { add(Piece(start: lastEnd, layout: camera.layout)) }
            add(Piece(start: stretch.start, layout: stretch.layout))
            lastEnd = stretch.end
        }
        if let lastEnd { add(Piece(start: lastEnd, layout: camera.layout)) }
        self.pieces = pieces
    }

    /// The parts of `ranges` that none of `covered` takes, in order, ranges that overlap or touch counted as one.
    static func parts(of ranges: [ClosedRange<Double>], outside covered: [(start: Double, end: Double)]) -> [ClosedRange<Double>] {
        var joined: [ClosedRange<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = joined.last, range.lowerBound <= last.upperBound {
                joined[joined.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                joined.append(range)
            }
        }
        var rooms = joined
        for stretch in covered {
            rooms = rooms.flatMap { room -> [ClosedRange<Double>] in
                guard stretch.start < room.upperBound, room.lowerBound < stretch.end else { return [room] }
                var left: [ClosedRange<Double>] = []
                if room.lowerBound < stretch.start { left.append(room.lowerBound...stretch.start) }
                if stretch.end < room.upperBound { left.append(stretch.end...room.upperBound) }
                return left
            }
        }
        return rooms
    }

    /// Whether the camera is drawn at all: the layout shows it, or a stretch does.
    var usesCamera: Bool {
        base != .screenOnly || stretches.contains { $0.layout != .screenOnly }
    }

    /// The layout at `time`, a change in progress not counted.
    func layout(at time: Double) -> Layout {
        pieces.last(where: { $0.start <= time })?.layout ?? base
    }

    /// What is drawn of the camera at `time`: steady in a layout, or part-way from the one before it. A
    /// layout that holds from the first frame is there from it, with no change to make.
    func levels(at time: Double) -> Levels {
        guard let index = pieces.lastIndex(where: { $0.start <= time }) else { return Self.levels(of: base) }
        let piece = pieces[index]
        guard index > 0, piece.start > 0, time - piece.start < Self.fade else { return Self.levels(of: piece.layout) }
        return Self.levels(from: pieces[index - 1].layout, to: piece.layout, progress: (time - piece.start) / Self.fade)
    }

    /// What a layout draws of the camera, fully: the bubble in picture in picture, the fill in camera only.
    /// Side by side draws the camera's picture of its own, which no change fades.
    static func levels(of layout: Layout) -> Levels {
        Levels(bubble: layout == .pictureInPicture ? 1 : 0, fill: layout == .cameraOnly ? 1 : 0)
    }

    /// Part-way, `progress` from 0 to 1, from one layout to another.
    static func levels(from old: Layout, to new: Layout, progress: Double) -> Levels {
        let a = levels(of: old), b = levels(of: new)
        let p = min(max(progress, 0), 1)
        let leaving = a.bubble > b.bubble || a.fill > b.fill
        let arriving = b.bubble > a.bubble || b.fill > a.fill
        // Going out first and coming in after when both have something to do; else all the time there is.
        let out = leaving && arriving ? max(0, 1 - 2 * p) : 1 - p
        let come = leaving && arriving ? max(0, 2 * p - 1) : p
        func level(_ old: Double, _ new: Double) -> Double {
            old == new ? old : (old > new ? out : come)
        }
        return Levels(bubble: level(a.bubble, b.bubble), fill: level(a.fill, b.fill))
    }
}
