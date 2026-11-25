import CoreGraphics

/// Only values which affect motion in recording time. Appearance, cuts, audio, and preview resolution do not.
nonisolated struct StudioMotionKey: Equatable, Sendable {
    struct Zoom: Equatable, Sendable {
        let start: Double
        let end: Double
        let scale: Double
        let target: StudioProject.Zoom.Spot?
    }

    let smoothing: Double
    let hidesWhenIdle: Bool
    let hidesWhileTyping: Bool
    let crop: CGRect?
    let zooms: [Zoom]

    init(_ project: StudioProject) {
        smoothing = min(max(project.cursor.smoothing, 0), 1)
        hidesWhenIdle = project.cursor.hidesWhenIdle
        hidesWhileTyping = project.cursor.hidesWhileTyping
        crop = StudioProject.normalizedCrop(project.crop)
        // In order, as the track takes them: a zoom dragged past another moves in time but not in the project's
        // list, and the same zooms listed otherwise make the same motion.
        zooms = project.zooms.map { Zoom(start: $0.start, end: $0.end, scale: $0.scale, target: $0.target) }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            if $0.scale != $1.scale { return $0.scale < $1.scale }
            let ax = $0.target?.x ?? -1
            let bx = $1.target?.x ?? -1
            if ax != bx { return ax < bx }
            return ($0.target?.y ?? -1) < ($1.target?.y ?? -1)
        }
    }
}
