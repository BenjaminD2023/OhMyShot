import AppKit
import OMSCore
import SwiftUI

/// The timeline: a ruler of seconds, the clip with its pictures and its cuts, the zooms above it, the camera's
/// layouts under it when the recording has a camera, and the playhead.
///
/// Click anywhere to move the playhead, drag on the ruler to scrub, drag along the clip to choose a stretch for
/// Cut. A zoom or a layout is chosen with a click; its ends drag to change when it starts and stops, its middle
/// to move it (a layout stays between its neighbors). A cut is chosen with a click; Delete takes it back (or
/// removes a chosen zoom or layout). With the timeline focused, ← and → move the playhead (⇧ by a second), I and
/// O choose a stretch from or to it, and Delete removes what is chosen or cuts the chosen stretch. Zooms,
/// layouts, and cuts have their commands in a menu and for VoiceOver too.
struct StudioTimeline: View {
    @Bindable var document: StudioDocument
    @Bindable var model: StudioWindowModel
    @Environment(\.colorSchemeContrast) private var contrast

    private static let inset: CGFloat = 16
    private static let rulerHeight: CGFloat = 24
    private static let zoomTop: CGFloat = 30
    private static let zoomHeight: CGFloat = 26
    private static let clipTop: CGFloat = 64
    private static let clipHeight: CGFloat = 40
    /// The camera's layouts, as chips under the clip, when it has any: 26 pt high, 6 pt below it.
    private static let layoutTop: CGFloat = 110
    private static let layoutHeight: CGFloat = 26
    /// How tall the timeline is, with and without the lane for the camera's layouts.
    static let height: CGFloat = 180
    static let heightWithLayouts: CGFloat = 208
    /// How near a zoom's end a press grabs that end, in points.
    private static let handleReach: CGFloat = 7
    /// How far the keys move the playhead, and VoiceOver a zoom's ends.
    private static let step = 0.1
    private static let longStep = 1.0
    private static let zoomStep = 0.25

    private enum Drag {
        case scrub
        case select(from: Double)
        case moveZoom(UUID, grabbedAt: Double, start: Double, end: Double)
        case resizeZoom(UUID, start: Bool)
        case moveLayout(UUID, grabbedAt: Double, start: Double, end: Double)
        case resizeLayout(UUID, start: Bool)
    }

    enum LaneHit: Equatable, Sendable {
        case ruler
        case zoomResize(UUID, start: Bool)
        case zoomMove(UUID)
        case layoutResize(UUID, start: Bool)
        case layoutMove(UUID)
        case cut(Double)
        case clipRange
    }

    @State private var drag: Drag?
    @State private var hoverX: CGFloat?
    @State private var snappedX: CGFloat?
    @State private var lastClick: (uptime: TimeInterval, location: CGPoint)?
    @State private var viewport: StudioTimelineViewport
    @State private var filmstrip = StudioTimelineFilmstrip()
    @FocusState private var timelineFocused: Bool

    init(document: StudioDocument, model: StudioWindowModel) {
        self.document = document
        self.model = model
        _viewport = State(initialValue: StudioTimelineViewport(duration: document.duration))
    }

    var body: some View {
        VStack(spacing: 4) {
            viewportControls
            GeometryReader { geometry in
                let width = geometry.size.width
                let request = filmstripRequest(width: width)
                ZStack(alignment: .topLeading) {
                    ruler(width: width)
                    zooms(width: width)
                    clip(width: width, request: request)
                    if document.canChangeLayoutAlongTheTimeline { layouts(width: width) }
                    snapGuide(height: geometry.size.height)
                    ghostPlayhead(width: width, height: geometry.size.height)
                    playhead(width: width, height: geometry.size.height)
                }
                .frame(width: width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let clamped = min(max(location.x, Self.inset), max(Self.inset, width - Self.inset))
                        hoverX = location.x >= Self.inset && location.x <= width - Self.inset ? clamped : nil
                    case .ended:
                        hoverX = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            timelineFocused = true
                            dragChanged(value, width: width)
                        }
                        .onEnded { value in dragEnded(value, width: width) }
                )
                .overlay {
                    StudioTimelineWheel { delta in
                        viewport.scroll(to: viewport.start + delta / max(width - Self.inset * 2, 1) * viewport.span)
                    }
                    .accessibilityHidden(true)
                }
                .task(id: request) { await filmstrip.load(source: document.source, request: request) }
            }
            if viewport.isFit {
                Color.clear.frame(height: 14)
            } else {
                StudioTimelineScroller(
                    position: Binding(get: { viewport.start }, set: { viewport.scroll(to: $0) }),
                    visible: viewport.span, duration: document.duration
                )
                .frame(height: 14)
                .padding(.horizontal, Self.inset)
            }
        }
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .focusable()
        .focused($timelineFocused)
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
            if press.modifiers.contains(.option) {
                chooseAdjacent(forward: press.key == .rightArrow)
                return .handled
            }
            let step = press.modifiers.contains(.shift) ? Self.longStep : Self.step
            model.controller?.seek(toRecordingTime: document.time + (press.key == .leftArrow ? -step : step))
            viewport.reveal(document.time)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "iIoO"), phases: .down) { press in
            mark(start: press.characters.lowercased() == "i")
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward], phases: .down) { _ in
            document.deleteSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            document.selection = .none
            return .handled
        }
        .onChange(of: document.time) { _, time in
            if document.isPlaying { viewport.reveal(time) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Timeline", bundle: .module))
        .accessibilityIdentifier("studio-timeline")
        .help(Text("← and → move the playhead. Option-← and Option-→ choose an edit. I and O mark a range; Delete removes it. Scroll to move along a zoomed timeline.", bundle: .module))
    }

    private var viewportControls: some View {
        HStack(spacing: 8) {
            Button { viewport.fit() } label: { Text("Fit", bundle: .module) }
                .help(Text("Show the whole recording", bundle: .module))
                .disabled(viewport.isFit)
            Button {
                if let range = selectionRange { viewport.fit(range) }
            } label: { Text("Fit Selection", bundle: .module) }
                .disabled(selectionRange == nil)
                .help(Text("Show the chosen edit or range in detail", bundle: .module))
            Spacer(minLength: 4)
            Button { viewport.zoom(by: 0.5, around: document.time) } label: { Image(systemName: "minus.magnifyingglass") }
                .accessibilityLabel(Text("Zoom Out Timeline", bundle: .module))
                .help(Text("Zoom Out Timeline", bundle: .module))
                .disabled(viewport.isFit)
            Button { viewport.zoom(by: 2, around: document.time) } label: { Image(systemName: "plus.magnifyingglass") }
                .accessibilityLabel(Text("Zoom In Timeline", bundle: .module))
                .help(Text("Zoom In Timeline", bundle: .module))
                .disabled(!viewport.canZoomIn)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, Self.inset)
        .frame(height: 26)
    }

    private var selectionRange: ClosedRange<Double>? {
        switch document.selection {
        case .range(let range): range
        case .zoom(let id): document.project.zooms.first { $0.id == id }.map { $0.start...$0.end }
        case .cut(let start): document.project.cuts.first { $0.lowerBound == start }
        case .cameraSegment(let id): document.project.cameraSegments.first { $0.id == id }.map { $0.start...$0.end }
        case .none: nil
        }
    }

    // MARK: Drawing

    private func x(_ time: Double, width: CGFloat) -> CGFloat {
        Self.inset + viewport.position(of: time, width: width - Self.inset * 2)
    }

    private func time(_ x: CGFloat, width: CGFloat) -> Double {
        viewport.time(at: x - Self.inset, width: max(width - Self.inset * 2, 1))
    }

    /// Lines around the clip, the cuts, and the zooms: the separator's hairline, or the contrast hairline
    /// under Increase Contrast.
    private var lineColor: Color {
        contrast == .increased ? Self.contrastHairline : Color(nsColor: .separatorColor)
    }

    private var lineWidth: CGFloat {
        contrast == .increased ? 1 : 0.5
    }

    /// Ticks at a step that keeps their labels apart, each labeled with monospaced digits.
    private func ruler(width: CGFloat) -> some View {
        let span = max(width - Self.inset * 2, 1)
        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let step = steps.first { Double(span) / (max(viewport.span, 0.001) / $0) >= 64 }
            ?? max(3600, viewport.span / max(Double(span) / 64, 1))
        let first = (viewport.start / step).rounded(.up) * step
        let marks = Array(stride(from: first, through: viewport.end, by: step))
        return ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.self) { mark in
                let position = x(mark, width: width)
                Rectangle()
                    .fill(Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 1, height: 6)
                    .offset(x: position, y: Self.rulerHeight - 6)
                // A tick too near the end for its label keeps only the tick.
                if position + 44 <= width {
                    Text(verbatim: TransportBar.format(mark).replacingOccurrences(of: ".0", with: ""))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: position + 3, y: 2)
                }
            }
        }
        .frame(width: width, height: Self.rulerHeight, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// Zooms as chips: the chip fill with the scale in label ink; the chosen one ringed in the accent, its
    /// scale semibold, with grips at its ends.
    private func zooms(width: CGFloat) -> some View {
        ForEach(document.project.zooms.filter { viewport.contains($0.start, $0.end) }) { zoom in
            let left = x(zoom.start, width: width), right = x(zoom.end, width: width)
            let chosen = document.selectedZoom == zoom.id
            let shape = RoundedRectangle(cornerRadius: Self.zoomHeight / 2, style: .continuous)
            shape
                .fill(contrast == .increased ? Self.chipFillStrong : Self.chipFill)
                .overlay(shape.strokeBorder(chosen ? Color.accentColor : lineColor, lineWidth: chosen ? 2 : lineWidth))
                .overlay(
                    Text(verbatim: String(format: "%.1f×", zoom.scale))
                        .font(.system(size: 11, weight: chosen ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                )
                .overlay(alignment: .leading) { grip(chosen: chosen, leading: true) }
                .overlay(alignment: .trailing) { grip(chosen: chosen, leading: false) }
                .frame(width: max(right - left, 8), height: Self.zoomHeight)
                .contentShape(shape)
                .contextMenu {
                    Button { document.removeZoom(zoom.id) } label: { Text("Remove Zoom", bundle: .module) }
                }
                .offset(x: left, y: Self.zoomTop)
                .accessibilityElement()
                .accessibilityLabel(Text("Zoom \(String(format: "%.1f", zoom.scale)) times, \(TransportBar.format(zoom.start)) to \(TransportBar.format(zoom.end))", bundle: .module))
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityAction { choose(zoom: zoom.id) }
                .accessibilityAction(named: Text("Remove Zoom", bundle: .module)) { document.removeZoom(zoom.id) }
                .accessibilityAction(named: Text("Start Earlier", bundle: .module)) { nudge(zoom.id, start: true, by: -Self.zoomStep) }
                .accessibilityAction(named: Text("Start Later", bundle: .module)) { nudge(zoom.id, start: true, by: Self.zoomStep) }
                .accessibilityAction(named: Text("End Earlier", bundle: .module)) { nudge(zoom.id, start: false, by: -Self.zoomStep) }
                .accessibilityAction(named: Text("End Later", bundle: .module)) { nudge(zoom.id, start: false, by: Self.zoomStep) }
        }
    }

    /// A zoom's end: a resize pointer within reach of it, and a grip while the zoom is chosen.
    private func grip(chosen: Bool, leading: Bool) -> some View {
        ZStack {
            Color.clear
            if chosen {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 12)
            }
        }
        .frame(width: Self.handleReach * 2)
        .contentShape(Rectangle())
        .pointerStyle(.frameResize(position: leading ? .leading : .trailing))
    }

    /// The camera's layouts as chips under the clip, like the zooms above it: the chip fill with the layout's
    /// symbol, and its name where there is room, in label ink; the chosen one ringed in the accent with grips.
    private func layouts(width: CGFloat) -> some View {
        ForEach(document.project.cameraSegments.filter { viewport.contains($0.start, $0.end) }) { segment in
            let left = x(segment.start, width: width), right = x(segment.end, width: width)
            let chosen = document.selectedSegment == segment.id
            let shape = RoundedRectangle(cornerRadius: Self.layoutHeight / 2, style: .continuous)
            shape
                .fill(contrast == .increased ? Self.chipFillStrong : Self.chipFill)
                .overlay(shape.strokeBorder(chosen ? Color.accentColor : lineColor, lineWidth: chosen ? 2 : lineWidth))
                .overlay(
                    HStack(spacing: 4) {
                        Image(systemName: segment.layout.symbol)
                            .font(.system(size: 11, weight: chosen ? .semibold : .regular))
                        if right - left >= 120 {
                            Text(verbatim: segment.layout.name)
                                .font(.system(size: 11, weight: chosen ? .semibold : .regular))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.primary)
                )
                .overlay(alignment: .leading) { grip(chosen: chosen, leading: true) }
                .overlay(alignment: .trailing) { grip(chosen: chosen, leading: false) }
                .frame(width: max(right - left, 8), height: Self.layoutHeight)
                .contentShape(shape)
                .contextMenu {
                    ForEach(StudioProject.Camera.Layout.stretchLayouts, id: \.self) { layout in
                        Button { document.setCameraSegmentLayout(segment.id, layout) } label: {
                            Label { Text(verbatim: layout.name) } icon: { Image(systemName: layout.symbol) }
                        }
                    }
                    Divider()
                    Button { document.removeCameraSegment(segment.id) } label: { Text("Remove Layout", bundle: .module) }
                }
                .offset(x: left, y: Self.layoutTop)
                .accessibilityElement()
                .accessibilityLabel(Text("\(segment.layout.name), \(TransportBar.format(segment.start)) to \(TransportBar.format(segment.end))", bundle: .module))
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityAction { choose(layout: segment.id) }
                .accessibilityAction(named: Text("Remove Layout", bundle: .module)) { document.removeCameraSegment(segment.id) }
                .accessibilityAction(named: Text("Start Earlier", bundle: .module)) { nudge(layout: segment.id, start: true, by: -Self.zoomStep) }
                .accessibilityAction(named: Text("Start Later", bundle: .module)) { nudge(layout: segment.id, start: true, by: Self.zoomStep) }
                .accessibilityAction(named: Text("End Earlier", bundle: .module)) { nudge(layout: segment.id, start: false, by: -Self.zoomStep) }
                .accessibilityAction(named: Text("End Later", bundle: .module)) { nudge(layout: segment.id, start: false, by: Self.zoomStep) }
                .accessibilityAction(named: Text("Picture in Picture", bundle: .module)) { document.setCameraSegmentLayout(segment.id, .pictureInPicture) }
                .accessibilityAction(named: Text("Camera Only", bundle: .module)) { document.setCameraSegmentLayout(segment.id, .cameraOnly) }
                .accessibilityAction(named: Text("Screen Only", bundle: .module)) { document.setCameraSegmentLayout(segment.id, .screenOnly) }
        }
    }

    private func clip(width: CGFloat, request: StudioFilmstripRequest) -> some View {
        let left = Self.inset, right = width - Self.inset
        let clipWidth = max(right - left, 1)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor))
                .overlay(alignment: .leading) { filmstrip(width: clipWidth, request: request) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(lineColor, lineWidth: lineWidth))
                .frame(width: clipWidth, height: Self.clipHeight)
                .pointerStyle(.horizontalText)
                .offset(x: left, y: Self.clipTop)
            ForEach(document.project.cuts.filter { viewport.contains($0.lowerBound, $0.upperBound) }, id: \.lowerBound) { cut in
                let chosen = document.selectedCut == cut.lowerBound
                let cutLeft = x(cut.lowerBound, width: width), cutRight = x(cut.upperBound, width: width)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                    .overlay(
                        // How much shorter the movie is for it, where there is room to say.
                        HStack(spacing: 4) {
                            Image(systemName: "scissors")
                                .font(.system(size: 11, weight: .semibold))
                            if cutRight - cutLeft >= 64 {
                                Text(verbatim: "−" + String(format: "%.1f s", cut.upperBound - cut.lowerBound))
                                    .font(.system(size: 11).monospacedDigit())
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(chosen ? Color.accentColor : lineColor, lineWidth: chosen ? 2 : lineWidth)
                    )
                    .frame(width: max(cutRight - cutLeft, 6), height: Self.clipHeight)
                    .pointerStyle(.link)
                    .contextMenu {
                        Button { document.restoreCut(at: cut.lowerBound) } label: { Text("Restore Cut", bundle: .module) }
                    }
                    .offset(x: cutLeft, y: Self.clipTop)
                    .accessibilityElement()
                    .accessibilityLabel(Text("Cut, \(TransportBar.format(cut.lowerBound)) to \(TransportBar.format(cut.upperBound))", bundle: .module))
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                    .accessibilityAction { choose(cut: cut.lowerBound) }
                    .accessibilityAction(named: Text("Restore Cut", bundle: .module)) { document.restoreCut(at: cut.lowerBound) }
            }
            if let range = document.selectedRange, viewport.contains(range.lowerBound, range.upperBound) {
                let rangeLeft = x(range.lowerBound, width: width), rangeRight = x(range.upperBound, width: width)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .frame(width: max(rangeRight - rangeLeft, 2), height: Self.clipHeight)
                    .offset(x: rangeLeft, y: Self.clipTop)
                    .accessibilityHidden(true)
            }
        }
    }

    private func filmstripRequest(width: CGFloat) -> StudioFilmstripRequest {
        let aspect = document.recordingSize.height > 0 ? document.recordingSize.width / document.recordingSize.height : 16.0 / 10
        return StudioFilmstripRequest(viewport: viewport, width: max(width - Self.inset * 2, 1), aspect: aspect)
    }

    /// Missing frames keep their own slot, so a failed decode cannot shift later pictures to the wrong time.
    private func filmstrip(width: CGFloat, request: StudioFilmstripRequest) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(request.samples) { sample in
                if let picture = filmstrip.images[sample.id] {
                    let left = viewport.position(of: sample.start, width: width)
                    let right = viewport.position(of: sample.end, width: width)
                    Image(decorative: picture, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: max(right - left, 1), height: Self.clipHeight)
                        .clipped()
                        .offset(x: left)
                }
            }
        }
        .frame(width: width, height: Self.clipHeight, alignment: .leading)
        .clipped()
        .accessibilityHidden(true)
    }

    /// A subtle hover indicator showing where a click or I/O mark on the timeline will land.
    @ViewBuilder
    private func ghostPlayhead(width: CGFloat, height: CGFloat) -> some View {
        if let hoverX, drag == nil {
            Rectangle()
                .fill(Color.accentColor.opacity(0.28))
                .frame(width: 1, height: height)
                .offset(x: hoverX - 0.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func snapGuide(height: CGFloat) -> some View {
        if let snappedX {
            Rectangle()
                .fill(Color.accentColor.opacity(0.65))
                .frame(width: 1, height: height)
                .offset(x: snappedX - 0.5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Snaps `time` to the nearest candidate boundary within 5 pt on the timeline when `enabled` is true.
    static func snappedTime(
        _ time: Double, candidates: [Double], duration: Double, width: CGFloat, viewport: StudioTimelineViewport,
        enabled: Bool = true
    ) -> (time: Double, snapped: Bool) {
        guard enabled else { return (time, false) }
        let span = max(width - Self.inset * 2, 1)
        let targetX = viewport.position(of: time, width: span)
        let threshold: CGFloat = 5
        var best: (candidate: Double, distance: CGFloat)?
        for candidate in ([0, duration] + candidates) {
            let candidateX = viewport.position(of: candidate, width: span)
            let dist = abs(candidateX - targetX)
            guard dist <= threshold else { continue }
            if best == nil || dist < best!.distance {
                best = (candidate, dist)
            }
        }
        if let best { return (best.candidate, true) }
        return (time, false)
    }

    /// Classifies what a point on the timeline hits, for lane cursor and interaction testing.
    static func laneHit(
        at point: CGPoint, width: CGFloat, viewport: StudioTimelineViewport,
        zooms: [StudioProject.Zoom], cuts: [ClosedRange<Double>],
        cameraSegments: [StudioProject.CameraSegment] = []
    ) -> LaneHit {
        let span = max(width - Self.inset * 2, 1)
        func x(_ t: Double) -> CGFloat { Self.inset + viewport.position(of: t, width: span) }
        let at = viewport.time(at: point.x - Self.inset, width: span)
        if point.y < Self.rulerHeight { return .ruler }
        if point.y >= Self.zoomTop, point.y <= Self.zoomTop + Self.zoomHeight,
           let zoom = zooms.first(where: { point.x >= x($0.start) - Self.handleReach && point.x <= x($0.end) + Self.handleReach }) {
            if abs(point.x - x(zoom.start)) <= Self.handleReach { return .zoomResize(zoom.id, start: true) }
            if abs(point.x - x(zoom.end)) <= Self.handleReach { return .zoomResize(zoom.id, start: false) }
            return .zoomMove(zoom.id)
        }
        if !cameraSegments.isEmpty, point.y >= Self.layoutTop, point.y <= Self.layoutTop + Self.layoutHeight,
           let seg = cameraSegments.first(where: { point.x >= x($0.start) - Self.handleReach && point.x <= x($0.end) + Self.handleReach }) {
            if abs(point.x - x(seg.start)) <= Self.handleReach { return .layoutResize(seg.id, start: true) }
            if abs(point.x - x(seg.end)) <= Self.handleReach { return .layoutResize(seg.id, start: false) }
            return .layoutMove(seg.id)
        }
        if point.y >= Self.clipTop, point.y <= Self.clipTop + Self.clipHeight {
            if let cut = cuts.first(where: { $0.contains(at) }) {
                return .cut(cut.lowerBound)
            }
            return .clipRange
        }
        return .ruler
    }

    /// The playhead; for VoiceOver, where the movie is, moved half a second at a time.
    private func playhead(width: CGFloat, height: CGFloat) -> some View {
        let position = x(document.time, width: width)
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2, height: height)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 9, height: 9)
                .offset(y: Self.rulerHeight - 8)
        }
        .offset(x: position - 1)
        .opacity(viewport.contains(document.time, document.time) ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(Text("Playhead", bundle: .module))
        .accessibilityValue(TransportBar.spokenPosition(of: document))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.5 : -0.5
            model.controller?.seek(toRecordingTime: document.time + step)
            viewport.reveal(document.time)
        }
    }

    // MARK: Commands

    private func choose(zoom id: UUID) {
        document.selection = .zoom(id)
    }

    private func choose(cut start: Double) {
        document.selection = .cut(start)
    }

    private func choose(layout id: UUID) {
        document.selection = .cameraSegment(id)
    }

    /// Option-arrows reach every edit, including edits outside the current viewport, without using a mouse.
    private func chooseAdjacent(forward: Bool) {
        let items = StudioTimelineNavigation.items(
            zooms: document.project.zooms, cuts: document.project.cuts,
            layouts: document.canChangeLayoutAlongTheTimeline ? document.project.cameraSegments : []
        )
        guard let chosen = StudioTimelineNavigation.adjacent(
            in: items, selection: document.selection, time: document.time, forward: forward
        ) else { return }
        document.selection = chosen.selection
        model.controller?.seek(toRecordingTime: chosen.start)
        viewport.reveal(chosen.start)
    }

    private func nudge(_ id: UUID, start: Bool, by shift: Double) {
        document.updateZoom(id) { zoom in
            if start { zoom.start = min(zoom.start + shift, zoom.end - 0.3) } else { zoom.end = max(zoom.end + shift, zoom.start + 0.3) }
        }
    }

    private func nudge(layout id: UUID, start: Bool, by shift: Double) {
        document.updateCameraSegment(id) { segment in
            if start { segment.start += shift } else { segment.end += shift }
        }
    }

    /// I chooses a stretch from the playhead (to the end of the one chosen, or of the recording); O to it.
    private func mark(start: Bool) {
        let now = document.time
        let range = document.selectedRange
        let lower = start ? now : (range?.lowerBound ?? 0)
        let upper = start ? (range?.upperBound ?? document.duration) : now
        document.selection = upper - lower > 0.05 ? .range(lower...upper) : .none
    }

    // MARK: Dragging

    private func snapCandidates(excludingZoom zoomID: UUID? = nil, excludingSegment segmentID: UUID? = nil, includePlayhead: Bool = true) -> [Double] {
        var points: [Double] = []
        if includePlayhead { points.append(document.time) }
        for cut in document.project.cuts {
            points.append(cut.lowerBound)
            points.append(cut.upperBound)
        }
        for zoom in document.project.zooms where zoom.id != zoomID {
            points.append(zoom.start)
            points.append(zoom.end)
        }
        for seg in document.project.cameraSegments where seg.id != segmentID {
            points.append(seg.start)
            points.append(seg.end)
        }
        return points
    }

    private func dragChanged(_ value: DragGesture.Value, width: CGFloat) {
        let point = value.location
        let rawNow = time(point.x, width: width)
        if drag == nil {
            drag = beginDrag(at: value.startLocation, width: width)
        }
        let snapEnabled = !NSEvent.modifierFlags.contains(.command)
        switch drag {
        case .scrub:
            let snapped = Self.snappedTime(
                rawNow, candidates: snapCandidates(includePlayhead: false),
                duration: document.duration, width: width, viewport: viewport, enabled: snapEnabled
            )
            snappedX = snapped.snapped ? x(snapped.time, width: width) : nil
            model.controller?.seek(toRecordingTime: snapped.time)
        case .select(let from):
            let snapped = Self.snappedTime(
                rawNow, candidates: snapCandidates(),
                duration: document.duration, width: width, viewport: viewport, enabled: snapEnabled
            )
            snappedX = snapped.snapped ? x(snapped.time, width: width) : nil
            let lower = min(from, snapped.time), upper = max(from, snapped.time)
            document.selection = upper - lower > 0.05 ? .range(lower...upper) : .none
        case .moveZoom(let id, let grabbedAt, let start, let end):
            var shift = min(max(rawNow - grabbedAt, -start), document.duration - end)
            let snappedStart = Self.snappedTime(
                start + shift, candidates: snapCandidates(excludingZoom: id),
                duration: document.duration, width: width, viewport: viewport, enabled: snapEnabled
            )
            if snappedStart.snapped {
                shift = min(max(snappedStart.time - start, -start), document.duration - end)
                snappedX = x(start + shift, width: width)
            } else {
                snappedX = nil
            }
            document.updateZoom(id) { zoom in
                zoom.start = start + shift
                zoom.end = end + shift
            }
        case .resizeZoom(let id, let start):
            let snapped = Self.snappedTime(
                rawNow, candidates: snapCandidates(excludingZoom: id),
                duration: document.duration, width: width, viewport: viewport, enabled: snapEnabled
            )
            snappedX = snapped.snapped ? x(snapped.time, width: width) : nil
            document.updateZoom(id) { zoom in
                if start { zoom.start = min(snapped.time, zoom.end - 0.3) } else { zoom.end = max(snapped.time, zoom.start + 0.3) }
            }
        case .moveLayout(let id, let grabbedAt, let start, let end):
            // Kept to the room between its neighbors, whole.
            let limits = document.limits(ofCameraSegment: id)
            let shift = min(max(rawNow - grabbedAt, limits.lowerBound - start), limits.upperBound - end)
            snappedX = nil
            document.updateCameraSegment(id) { segment in
                segment.start = start + shift
                segment.end = end + shift
            }
        case .resizeLayout(let id, let start):
            let snapped = Self.snappedTime(
                rawNow, candidates: snapCandidates(excludingSegment: id),
                duration: document.duration, width: width, viewport: viewport, enabled: snapEnabled
            )
            snappedX = snapped.snapped ? x(snapped.time, width: width) : nil
            document.updateCameraSegment(id) { segment in
                if start { segment.start = min(snapped.time, segment.end - StudioProject.shortestSegment) } else { segment.end = max(snapped.time, segment.start + StudioProject.shortestSegment) }
            }
        case nil:
            break
        }
    }

    private func dragEnded(_ value: DragGesture.Value, width: CGFloat) {
        snappedX = nil
        let moved = hypot(value.translation.width, value.translation.height) > 3
        if !moved {
            // A click: choose what is under it, and move the playhead there.
            let point = value.startLocation
            let at = time(point.x, width: width)
            let nowUptime = ProcessInfo.processInfo.systemUptime
            let isDoubleClick: Bool = if let prev = lastClick,
                                        nowUptime - prev.uptime <= NSEvent.doubleClickInterval,
                                        hypot(point.x - prev.location.x, point.y - prev.location.y) <= 6 {
                true
            } else {
                false
            }
            lastClick = isDoubleClick ? nil : (nowUptime, point)
            if let zoom = zoom(at: point, width: width) {
                choose(zoom: zoom.id)
            } else if isDoubleClick, point.y >= Self.zoomTop, point.y <= Self.zoomTop + Self.zoomHeight {
                model.controller?.seek(toRecordingTime: at)
                document.time = at
                if document.canAddZoom { document.addZoom() }
                document.endContinuousChange()
                drag = nil
                return
            } else if let layout = layout(at: point, width: width) {
                choose(layout: layout.id)
            } else if point.y >= Self.clipTop, point.y <= Self.clipTop + Self.clipHeight, let cut = document.project.cuts.first(where: { $0.contains(at) }) {
                choose(cut: cut.lowerBound)
            } else {
                document.selection = .none
            }
            model.controller?.seek(toRecordingTime: at)
        }
        // A dragged zoom is taken back in one step.
        document.endContinuousChange()
        drag = nil
    }

    /// What a drag starting at `point` does: on the ruler, scrub; on a zoom, move or resize it; on the clip,
    /// choose a stretch.
    private func beginDrag(at point: CGPoint, width: CGFloat) -> Drag {
        let at = time(point.x, width: width)
        if point.y < Self.rulerHeight { return .scrub }
        if let zoom = zoom(at: point, width: width) {
            choose(zoom: zoom.id)
            document.beginContinuousChange()
            let left = x(zoom.start, width: width), right = x(zoom.end, width: width)
            if abs(point.x - left) <= Self.handleReach { return .resizeZoom(zoom.id, start: true) }
            if abs(point.x - right) <= Self.handleReach { return .resizeZoom(zoom.id, start: false) }
            return .moveZoom(zoom.id, grabbedAt: at, start: zoom.start, end: zoom.end)
        }
        if let layout = layout(at: point, width: width) {
            choose(layout: layout.id)
            document.beginContinuousChange()
            let left = x(layout.start, width: width), right = x(layout.end, width: width)
            if abs(point.x - left) <= Self.handleReach { return .resizeLayout(layout.id, start: true) }
            if abs(point.x - right) <= Self.handleReach { return .resizeLayout(layout.id, start: false) }
            return .moveLayout(layout.id, grabbedAt: at, start: layout.start, end: layout.end)
        }
        if point.y >= Self.clipTop, point.y <= Self.clipTop + Self.clipHeight {
            document.selection = .none
            return .select(from: at)
        }
        return .scrub
    }

    private func zoom(at point: CGPoint, width: CGFloat) -> StudioProject.Zoom? {
        guard point.y >= Self.zoomTop, point.y <= Self.zoomTop + Self.zoomHeight else { return nil }
        return document.project.zooms.first { zoom in
            point.x >= x(zoom.start, width: width) - Self.handleReach && point.x <= x(zoom.end, width: width) + Self.handleReach
        }
    }

    private func layout(at point: CGPoint, width: CGFloat) -> StudioProject.CameraSegment? {
        guard document.canChangeLayoutAlongTheTimeline, point.y >= Self.layoutTop, point.y <= Self.layoutTop + Self.layoutHeight else { return nil }
        return document.project.cameraSegments.first { segment in
            point.x >= x(segment.start, width: width) - Self.handleReach && point.x <= x(segment.end, width: width) + Self.handleReach
        }
    }

    // MARK: Colors

    /// The chip fill (black 0.08, white 0.16 in Dark), doubled under Increase Contrast.
    private static let chipFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.08)
    })
    private static let chipFillStrong = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.28) : NSColor(white: 0, alpha: 0.16)
    })
    /// The 1 pt contrast hairline's ink (black 0.35, white 0.5 in Dark).
    private static let contrastHairline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0, alpha: 0.35)
    })
}
