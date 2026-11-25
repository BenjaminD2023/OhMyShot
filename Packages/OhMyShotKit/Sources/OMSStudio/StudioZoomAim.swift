import SwiftUI

/// Aims the zoom chosen on the timeline, over the preview: a click or a drag on the recording holds the zoom on the
/// spot under the pointer, and with the preview focused the arrow keys move that spot (⇧ ten times as far). The
/// spot shows as a ring over the preview while the movie is paused, with the part of the recording the zoom shows
/// outlined around it while the picture shown isn't the zoom's. Points are read through the frame the preview shows,
/// and through that frame as it was when a drag began until the drag ends, so the spot never chases a picture it
/// is moving.
struct StudioZoomAim: View {
    @Bindable var document: StudioDocument
    /// Reports when the aim view gains or loses keyboard focus so window-level arrow seeking yields to aim nudging.
    var onFocusChange: ((Bool) -> Void)? = nil
    @FocusState private var focused: Bool
    /// What the camera showed when the drag under way began; nil while none is aiming.
    @State private var aiming: StudioRenderer.View?
    /// A drag is under way, aiming or not: one that began off the recording aims nothing.
    @State private var dragging = false
    @Environment(\.colorSchemeContrast) private var contrast

    /// How far an arrow key moves the spot, as a share of the recording across or down; with ⇧; and a VoiceOver
    /// action.
    static let step = 0.01
    static let longStep = 0.1
    static let spokenStep = 0.05
    /// The ring's diameter, in points.
    static let ringDiameter = 22.0

    /// The chosen zoom and the renderer of the movie the preview shows, while the zoom can be aimed.
    private var chosen: (zoom: StudioProject.Zoom, renderer: StudioRenderer)? {
        guard let id = document.selectedZoom, let zoom = document.project.zooms.first(where: { $0.id == id }),
              let renderer = document.composition?.renderer, !document.compositionFailed else { return nil }
        return (zoom, renderer)
    }

    var body: some View {
        GeometryReader { proxy in
            if let chosen {
                let movie = Self.movieRect(canvas: chosen.renderer.layout.canvas, in: proxy.size)
                let view = aiming ?? chosen.renderer.view(at: document.shownTime)
                ZStack {
                    if !document.isPlaying, let target = chosen.zoom.target {
                        marks(target: target, zoom: chosen.zoom, renderer: chosen.renderer, view: view, movie: movie)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in dragChanged(value, zoom: chosen.zoom, renderer: chosen.renderer, movie: movie) }
                        .onEnded { _ in dragEnded() }
                )
            }
        }
        .focusable(chosen != nil)
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { press in
            guard let id = document.selectedZoom else { return .ignored }
            let step = press.modifiers.contains(.shift) ? Self.longStep : Self.step
            switch press.key {
            case .leftArrow: nudge(id, x: -step)
            case .rightArrow: nudge(id, x: step)
            case .upArrow: nudge(id, y: -step)
            default: nudge(id, y: step)
            }
            return .handled
        }
        .onChange(of: document.selectedZoom) { _, chosen in
            if chosen == nil { focused = false }
        }
        .onChange(of: focused) { _, isFocused in
            onFocusChange?(isFocused)
        }
        .onDisappear {
            onFocusChange?(false)
        }
        .allowsHitTesting(chosen != nil)
        .modifier(AimAccessibility(document: document, isActive: chosen != nil) { id, x, y in nudge(id, x: x, y: y) })
    }

    /// The ring on the spot, and the part of the recording the zoom shows while the picture shown isn't the zoom's.
    @ViewBuilder
    private func marks(target: StudioProject.Zoom.Spot, zoom: StudioProject.Zoom, renderer: StudioRenderer, view: StudioRenderer.View, movie: CGRect) -> some View {
        let canvas = renderer.layout.canvas
        let line = contrast == .increased ? 2.0 : 1.5
        let outline = contrast == .increased ? 4.0 : 3.0
        let edge = Color.white.opacity(contrast == .increased ? 1 : 0.9)
        let crop = renderer.project.effectiveCrop
        let displayed = StudioProject.Zoom.Spot(
            x: min(max(target.x, Double(crop.minX)), Double(crop.maxX)),
            y: min(max(target.y, Double(crop.minY)), Double(crop.maxY))
        )
        let center = Self.viewPoint(renderer.moviePoint(of: displayed, in: view), canvas: canvas, movie: movie)
        // Outside the zoom, still coming in, or under a stronger one, the picture isn't what the zoom shows.
        if !document.isFullyIn(zoom) {
            let corners = renderer.shown(around: displayed, scale: zoom.scale)
            let topLeft = Self.viewPoint(renderer.moviePoint(of: corners.topLeft, in: view), canvas: canvas, movie: movie)
            let bottomRight = Self.viewPoint(renderer.moviePoint(of: corners.bottomRight, in: view), canvas: canvas, movie: movie)
            let region = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
            ZStack {
                Rectangle().path(in: region).stroke(edge, lineWidth: outline)
                Rectangle().path(in: region).stroke(Color.accentColor, lineWidth: line)
            }
            .clipShape(Rectangle().path(in: Self.viewRect(renderer.layout.frame, canvas: canvas, movie: movie)))
        }
        ZStack {
            Circle().stroke(edge, lineWidth: outline)
            Circle().stroke(Color.accentColor, lineWidth: line)
            Circle().fill(Color.accentColor).frame(width: 4, height: 4)
                .overlay(Circle().stroke(edge, lineWidth: 1))
        }
        .frame(width: Self.ringDiameter, height: Self.ringDiameter)
        .position(center)
    }

    private func dragChanged(_ value: DragGesture.Value, zoom: StudioProject.Zoom, renderer: StudioRenderer, movie: CGRect) {
        focused = true
        if !dragging {
            dragging = true
            let start = Self.moviePoint(value.startLocation, canvas: renderer.layout.canvas, movie: movie)
            // Begun off the recording (on the background, the camera's picture beside it, or the camera filling the
            // movie), it aims nothing.
            guard renderer.showsRecording(atMovie: start, at: document.shownTime) else { return }
            aiming = renderer.view(at: document.shownTime)
            document.beginContinuousChange()
        }
        guard let aiming else { return }
        let point = Self.moviePoint(value.location, canvas: renderer.layout.canvas, movie: movie)
        let raw = renderer.spot(atMovie: point, in: aiming)
        let crop = renderer.project.effectiveCrop
        let clamped = StudioProject.Zoom.Spot(
            x: min(max(raw.x, Double(crop.minX)), Double(crop.maxX)),
            y: min(max(raw.y, Double(crop.minY)), Double(crop.maxY))
        )
        document.setZoomTarget(zoom.id, clamped)
    }

    private func dragEnded() {
        if aiming != nil { document.endContinuousChange() }
        aiming = nil
        dragging = false
    }

    /// Moves the chosen zoom's spot; one that follows the pointer is held where it looks now, and moved from there.
    private func nudge(_ id: UUID, x: Double = 0, y: Double = 0) {
        let crop = document.project.effectiveCrop
        let spot = document.aim(of: id)
        let moved = StudioProject.Zoom.Spot(
            x: min(max(spot.x + x * Double(crop.width), Double(crop.minX)), Double(crop.maxX)),
            y: min(max(spot.y + y * Double(crop.height), Double(crop.minY)), Double(crop.maxY))
        )
        document.setZoomTarget(id, moved)
    }

    // MARK: Geometry

    /// Where the movie shows in a view of `size`, fitted in it and centered, as the player fits it.
    static func movieRect(canvas: CGSize, in size: CGSize) -> CGRect {
        guard canvas.width > 0, canvas.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / canvas.width, size.height / canvas.height)
        let width = canvas.width * scale, height = canvas.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// The movie's pixel (y up) at `point` in the view (y down), the movie shown in `movie`.
    static func moviePoint(_ point: CGPoint, canvas: CGSize, movie: CGRect) -> CGPoint {
        guard movie.width > 0, movie.height > 0 else { return .zero }
        return CGPoint(x: (point.x - movie.minX) * canvas.width / movie.width, y: (movie.maxY - point.y) * canvas.height / movie.height)
    }

    /// Where the movie's pixel `point` (y up) shows in the view (y down): `moviePoint` the other way.
    static func viewPoint(_ point: CGPoint, canvas: CGSize, movie: CGRect) -> CGPoint {
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        return CGPoint(x: movie.minX + point.x * movie.width / canvas.width, y: movie.maxY - point.y * movie.height / canvas.height)
    }

    /// Where a rectangle of the movie (its pixels, y up) shows in the view.
    static func viewRect(_ rect: CGRect, canvas: CGSize, movie: CGRect) -> CGRect {
        let a = viewPoint(CGPoint(x: rect.minX, y: rect.maxY), canvas: canvas, movie: movie)
        let b = viewPoint(CGPoint(x: rect.maxX, y: rect.minY), canvas: canvas, movie: movie)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }
}

/// The aim for VoiceOver, while a zoom is chosen: the spot as how far across and down the recording it is, with
/// actions that move it as the arrow keys do. Hidden otherwise, so the preview reads as it did.
private struct AimAccessibility: ViewModifier {
    let document: StudioDocument
    let isActive: Bool
    let nudge: (UUID, Double, Double) -> Void

    func body(content: Content) -> some View {
        if isActive, let id = document.selectedZoom {
            let step = StudioZoomAim.spokenStep
            content
                .accessibilityElement()
                .accessibilityLabel(Text("Zoom target", bundle: .module))
                .accessibilityValue(value(of: id))
                .accessibilityHint(Text("Click or drag on the preview to aim the zoom. With the preview focused, the arrow keys move it.", bundle: .module))
                .accessibilityAction(named: Text("Move Left", bundle: .module)) { nudge(id, -step, 0) }
                .accessibilityAction(named: Text("Move Right", bundle: .module)) { nudge(id, step, 0) }
                .accessibilityAction(named: Text("Move Up", bundle: .module)) { nudge(id, 0, -step) }
                .accessibilityAction(named: Text("Move Down", bundle: .module)) { nudge(id, 0, step) }
                .help(Text("Click or drag on the preview to aim the zoom. With the preview focused, the arrow keys move it.", bundle: .module))
        } else {
            content.accessibilityHidden(true)
        }
    }

    private func value(of id: UUID) -> Text {
        guard let target = document.project.zooms.first(where: { $0.id == id })?.target else {
            return Text("Following the pointer", bundle: .module)
        }
        let across = target.x.formatted(.percent.precision(.fractionLength(0)))
        let down = target.y.formatted(.percent.precision(.fractionLength(0)))
        return Text("\(across) across, \(down) down", bundle: .module)
    }
}
