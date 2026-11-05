/// Only values which affect motion in recording time. Appearance, cuts, and preview resolution do not.
nonisolated struct StudioMotionKey: Equatable, Sendable {
    struct Zoom: Equatable, Sendable {
        let start: Double
        let end: Double
        let scale: Double
    }

    let smoothing: Double
    let hidesWhenIdle: Bool
    let hidesWhileTyping: Bool
    let zooms: [Zoom]

    init(_ project: StudioProject) {
        smoothing = min(max(project.cursor.smoothing, 0), 1)
        hidesWhenIdle = project.cursor.hidesWhenIdle
        hidesWhileTyping = project.cursor.hidesWhileTyping
        // In order, as the track takes them: a zoom dragged past another moves in time but not in the project's
        // list, and the same zooms listed otherwise make the same motion.
        zooms = project.zooms.map { Zoom(start: $0.start, end: $0.end, scale: $0.scale) }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.scale < $1.scale
        }
    }
}
