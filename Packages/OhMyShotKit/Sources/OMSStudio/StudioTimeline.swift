import AppKit
import OMSCore
import OMSDesign
import SwiftUI

/// The timeline: a ruler of seconds, the clip with its pictures and its cuts, the zooms above it, the camera's
/// layouts under it when the recording has a camera, and the playhead.
///
/// Click anywhere to move the playhead, drag on the ruler to scrub, drag along the clip to choose a stretch for
/// Cut. A zoom or a layout is chosen with a click; its ends drag to change when it starts and stops, its middle
/// to move it (a layout stays between its neighbors). A cut is chosen with a click; Delete takes it back (or
/// removes a chosen zoom or layout). A stretch played faster or slower is a band along the clip's foot, chosen with
/// a click; Delete plays it as recorded again. With the timeline focused, ← and → move the playhead (⇧ by a second), I and
/// O choose a stretch from or to it, and Delete removes what is chosen or cuts the chosen stretch. Zooms,
/// layouts, cuts, and speeds have their commands in a menu and for VoiceOver too.
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
    /// A stretch played faster or slower, as a band along the clip's foot, never narrower than `speedWidth`.
    private static let speedHeight: CGFloat = 16
    private static let speedWidth: CGFloat = 6
    /// The camera's layouts, as chips under the clip, when it has any: 26 pt high, 6 pt below it.
    private static let layoutTop: CGFloat = 110
    private static let layoutHeight: CGFloat = 26
    /// How tall the timeline is, with and without the lane for the camera's layouts.
    static let height: CGFloat = 180
    static let heightWithLayouts: CGFloat = 208
    /// How near an edit's end a press grabs that end, in points.
    private static let handleReach: CGFloat = 7
    /// How far VoiceOver moves an edit's edge per custom action.
    private static let zoomStep = 0.25
    /// Minimum change in recording seconds before issuing another live preview seek during a drag (one 60 fps frame).
    static let scrubStep: Double = 1.0 / 60.0

    private enum Drag {
        case scrub
        case select(from: Double)
        case moveZoom(UUID, grabbedAt: Double, start: Double, end: Double)
        case resizeZoom(UUID, start: Bool)
        case moveLayout(UUID, grabbedAt: Double, start: Double, end: Double)
        case resizeLayout(UUID, start: Bool)
        case moveSpeed(currentStart: Double, grabbedAt: Double, initialStart: Double, initialEnd: Double)
        case resizeSpeed(Double, start: Bool)
        case cutResize(Double, leading: Bool)
    }

    enum LaneHit: Equatable, Sendable {
        case ruler
        case zoomResize(UUID, start: Bool)
        case zoomMove(UUID)
        case layoutResize(UUID, start: Bool)
        case layoutMove(UUID)
        case cutResize(Double, start: Bool)
        case cut(Double)
        case speedResize(Double, start: Bool)
        case speed(Double)
        case clipRange
    }

    @State private var drag: Drag?
    @State private var dragMoved = false
    @State private var dragStartPlayhead: Double?
    @State private var lastScrubTime: Double?
    @State private var hoverX: CGFloat?
    @State private var snappedX: CGFloat?
    @State private var lastClick: (uptime: TimeInterval, location: CGPoint)?
    @State private var viewport: StudioTimelineViewport
    @State private var filmstrip = StudioTimelineFilmstrip()
    @State private var rangeCapsuleWidth: CGFloat = 150
    @State private var pinchStartSpan: Double?
    @State private var pinchAnchorTime: Double?
    @State private var pinchAnchorFraction: Double?
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
                    telemetryTicks(width: width)
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
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if pinchStartSpan == nil {
                                let anchor = hoverX.map { time($0, width: width) } ?? document.time
                                pinchStartSpan = viewport.span
                                pinchAnchorTime = anchor
                                pinchAnchorFraction = viewport.span > 0 ? (anchor - viewport.start) / viewport.span : 0.5
                            }
                            guard let startSpan = pinchStartSpan, let anchor = pinchAnchorTime else { return }
                            let magnification = max(0.05, Double(value.magnification))
                            viewport.setSpan(startSpan / magnification, around: anchor, anchorFraction: pinchAnchorFraction)
                        }
                        .onEnded { _ in
                            pinchStartSpan = nil
                            pinchAnchorTime = nil
                            pinchAnchorFraction = nil
                        }
                )
                .overlay {
                    StudioTimelineWheel { delta in
                        viewport.scroll(to: viewport.start + delta / max(width - Self.inset * 2, 1) * viewport.span)
                    }
                    .accessibilityHidden(true)
                }
                .overlay(alignment: .topLeading) {
                    rangeActionCapsule(width: width)
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
        .onChange(of: document.time) { _, time in
            if document.isPlaying { viewport.reveal(time) }
        }
        .onChange(of: model.revealRequest?.id) { _, _ in
            if let time = model.revealRequest?.time { viewport.reveal(time) }
        }
        .onChange(of: model.timelineZoomRequest?.id) { _, _ in
            guard let action = model.timelineZoomRequest?.action else { return }
            switch action {
            case .zoomIn:
                viewport.zoom(by: 2, around: document.time)
            case .zoomOut:
                viewport.zoom(by: 0.5, around: document.time)
            case .reset:
                viewport.fit()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Timeline", bundle: .module))
        .accessibilityIdentifier("studio-timeline")
        .help(Text("← and → move the playhead. Option-← and Option-→ choose an edit. I and O mark a range; Delete removes it. Scroll to move along a zoomed timeline.", bundle: .module))
    }

    private var viewportControls: some View {
        HStack(spacing: 8) {
            // Bordered: words alone in a borderless row read as labels, not as buttons.
            Button { viewport.fit() } label: { Text("Fit", bundle: .module) }
                .buttonStyle(.bordered)
                .help(Text("Show the whole recording", bundle: .module))
                .disabled(viewport.isFit)
            Button {
                if let range = selectionRange { viewport.fit(range) }
            } label: { Text("Fit Selection", bundle: .module) }
                .buttonStyle(.bordered)
                .disabled(selectionRange == nil)
                .help(Text("Show the chosen edit or range in detail", bundle: .module))
            Spacer(minLength: 4)
            if !viewport.isFit {
                Button {
                    viewport.fit()
                } label: {
                    Text(verbatim: TransportBar.scale(viewport.zoomLevel))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(Text("Reset timeline zoom (⌘0)", bundle: .module))
                .accessibilityLabel(Text("Reset timeline zoom, currently \(TransportBar.oneDecimal(viewport.zoomLevel)) times", bundle: .module))
            }
            Button { viewport.zoom(by: 0.5, around: document.time) } label: { Image(systemName: "minus.magnifyingglass") }
                .accessibilityLabel(Text("Zoom Out Timeline", bundle: .module))
                .help(Text("Zoom Out Timeline (⌘-)", bundle: .module))
                .disabled(viewport.isFit)
            Button { viewport.zoom(by: 2, around: document.time) } label: { Image(systemName: "plus.magnifyingglass") }
                .accessibilityLabel(Text("Zoom In Timeline", bundle: .module))
                .help(Text("Zoom In Timeline (⌘+)", bundle: .module))
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
        case .speed(let start): document.project.speeds.first { $0.start == start }.map { $0.start...$0.end }
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
                    Text(verbatim: StudioTimeInput.tick(mark))
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

    /// Zooms as chips: the chip fill with the scale in label ink (and a subtle sparkles mark on automatic zooms);
    /// the chosen one ringed in the accent, its scale semibold, with grips at its ends.
    private func zooms(width: CGFloat) -> some View {
        ForEach(document.project.zooms.filter { viewport.contains($0.start, $0.end) }) { zoom in
            let left = x(zoom.start, width: width), right = x(zoom.end, width: width)
            let chosen = document.selectedZoom == zoom.id
            let shape = RoundedRectangle(cornerRadius: Self.zoomHeight / 2, style: .continuous)
            shape
                .fill(contrast == .increased ? Self.chipFillStrong : Self.chipFill)
                .overlay(shape.strokeBorder(chosen ? Color.accentColor : lineColor, lineWidth: chosen ? 2 : lineWidth))
                .overlay(
                    HStack(spacing: 2) {
                        if zoom.isAutomatic, right - left >= 40 {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9, weight: chosen ? .semibold : .regular))
                                .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
                                .accessibilityHidden(true)
                        }
                        Text(verbatim: TransportBar.scale(zoom.scale))
                            .font(.system(size: 11, weight: chosen ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 4)
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
                .accessibilityLabel(
                    zoom.isAutomatic
                        ? Text("Automatic zoom \(TransportBar.oneDecimal(zoom.scale)) times, \(TransportBar.format(zoom.start)) to \(TransportBar.format(zoom.end))", bundle: .module)
                        : Text("Zoom \(TransportBar.oneDecimal(zoom.scale)) times, \(TransportBar.format(zoom.start)) to \(TransportBar.format(zoom.end))", bundle: .module)
                )
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityAction { choose(zoom: zoom.id) }
                .accessibilityAction(named: Text("Remove Zoom", bundle: .module)) { document.removeZoom(zoom.id) }
                .accessibilityAction(named: Text("Start Earlier", bundle: .module)) { nudge(zoom.id, start: true, by: -Self.zoomStep) }
                .accessibilityAction(named: Text("Start Later", bundle: .module)) { nudge(zoom.id, start: true, by: Self.zoomStep) }
                .accessibilityAction(named: Text("End Earlier", bundle: .module)) { nudge(zoom.id, start: false, by: -Self.zoomStep) }
                .accessibilityAction(named: Text("End Later", bundle: .module)) { nudge(zoom.id, start: false, by: Self.zoomStep) }
        }
    }

    /// Floating capsule above a selected clip range offering Cut and Keep Only.
    @ViewBuilder
    private func rangeActionCapsule(width: CGFloat) -> some View {
        if let range = document.selectedRange, drag == nil, viewport.contains(range.lowerBound, range.upperBound) {
            let visibleLeft = max(Self.inset, x(range.lowerBound, width: width))
            let visibleRight = min(width - Self.inset, x(range.upperBound, width: width))
            let midX = (visibleLeft + visibleRight) / 2
            let halfWidth = rangeCapsuleWidth / 2
            let minX = Self.inset
            let maxX = max(minX, width - Self.inset - rangeCapsuleWidth)
            let originX = min(max(midX - halfWidth, minX), maxX)
            let capsule = Capsule()
            HStack(spacing: 8) {
                Button {
                    document.cut(range)
                } label: {
                    Label { Text("Cut", bundle: .module) } icon: { Image(systemName: "scissors") }
                }
                .accessibilityLabel(Text("Cut", bundle: .module))
                .help(Text("Leave the chosen range out of the movie", bundle: .module))
                Divider()
                    .frame(height: 12)
                Button {
                    document.keepOnly(range)
                } label: {
                    Label { Text("Keep Only", bundle: .module) } icon: { Image(systemName: "timeline.selection") }
                }
                .accessibilityLabel(Text("Keep Only", bundle: .module))
                .help(Text("Trim the movie to only the chosen range", bundle: .module))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.system(size: 11, weight: .medium))
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(nsColor: .windowBackgroundColor), in: capsule)
            .overlay(capsule.strokeBorder(lineColor, lineWidth: lineWidth))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rangeCapsuleWidth = $0 }
            .offset(x: originX, y: max(2, Self.clipTop - 32))
        }
    }

    /// Subtle click dots and displayable keystroke ticks along the hairline above the clip track, hidden when empty.
    @ViewBuilder
    private func telemetryTicks(width: CGFloat) -> some View {
        let clicks = document.telemetry.clicks
        let keys = document.telemetry.keys.filter { $0.keyCode != StudioTelemetry.Key.unrecordedKeyCode }
        if !clicks.isEmpty || !keys.isEmpty {
            let clipWidth = max(width - Self.inset * 2, 1)
            let clickPositions = Self.visibleEventPositions(
                times: clicks.map(\.time), viewport: viewport, width: clipWidth, minimumSpacing: 3.5
            )
            let keyPositions = Self.visibleEventPositions(
                times: keys.map(\.time), viewport: viewport, width: clipWidth, minimumSpacing: 2.5
            )
            let strong = contrast == .increased
            Canvas { context, _ in
                let keyColor = Color(nsColor: .tertiaryLabelColor).opacity(strong ? 0.95 : 0.7)
                for px in keyPositions {
                    let rect = CGRect(x: px - 0.75, y: 0.5, width: 1.5, height: 3)
                    context.fill(Path(roundedRect: rect, cornerRadius: 0.75), with: .color(keyColor))
                }
                let clickColor = Color(nsColor: .secondaryLabelColor).opacity(strong ? 1.0 : 0.75)
                for px in clickPositions {
                    let rect = CGRect(x: px - 1.5, y: 0.5, width: 3, height: 3)
                    context.fill(Path(ellipseIn: rect), with: .color(clickColor))
                }
            }
            .frame(width: clipWidth, height: 4)
            .offset(x: Self.inset, y: Self.clipTop - 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Filters event `times` to those inside `viewport`, mapping each to its x position in `0...width` and
    /// coalescing marks closer than `minimumSpacing` points so dense recordings remain legible.
    static func visibleEventPositions(
        times: [Double], viewport: StudioTimelineViewport, width: CGFloat, minimumSpacing: CGFloat
    ) -> [CGFloat] {
        guard !times.isEmpty, viewport.span > 0, width > 0 else { return [] }
        let visible = times.filter { $0 >= viewport.start && $0 <= viewport.end }.sorted()
        var result: [CGFloat] = []
        var lastX: CGFloat = -.infinity
        for eventTime in visible {
            let pos = CGFloat(viewport.position(of: eventTime, width: Double(width)))
            guard pos - lastX >= minimumSpacing else { continue }
            result.append(pos)
            lastX = pos
        }
        return result
    }

    /// An edit's end: a resize pointer within reach of it, and a grip while the edit is chosen.
    private func grip(chosen: Bool, leading: Bool, height: CGFloat = 12) -> some View {
        ZStack {
            Color.clear
            if chosen {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: height)
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
                .overlay(alignment: .bottomLeading) { waveformOverlay(width: clipWidth) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(lineColor, lineWidth: lineWidth))
                .frame(width: clipWidth, height: Self.clipHeight)
                .pointerStyle(.horizontalText)
                .offset(x: left, y: Self.clipTop)
            ForEach(document.project.speeds.filter { viewport.contains($0.start, $0.end) }, id: \.start) { speed in
                let chosen = document.selectedSpeed == speed.start
                let speedLeft = x(speed.start, width: width), speedRight = x(speed.end, width: width)
                let showHandles = speedRight - speedLeft >= Self.handleReach * 3
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
                    .overlay(
                        // How fast, where there is room to say.
                        HStack(spacing: 3) {
                            Image(systemName: speed.rate < 1 ? "tortoise.fill" : "hare.fill")
                                .font(.system(size: 9, weight: .semibold))
                            if speedRight - speedLeft >= 40 {
                                Text(verbatim: TransportBar.speed(speed.rate))
                                    .font(.system(size: 10, weight: chosen ? .semibold : .regular).monospacedDigit())
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(chosen ? Color.accentColor : Color.primary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(chosen ? Color.accentColor : lineColor, lineWidth: chosen ? 2 : lineWidth)
                    )
                    .overlay(alignment: .leading) { if showHandles { grip(chosen: chosen, leading: true, height: 10) } }
                    .overlay(alignment: .trailing) { if showHandles { grip(chosen: chosen, leading: false, height: 10) } }
                    .frame(width: max(speedRight - speedLeft, Self.speedWidth), height: Self.speedHeight)
                    .pointerStyle(.link)
                    .contextMenu {
                        ForEach(StudioProject.speedRates, id: \.self) { rate in
                            Button {
                                choose(speed: speed.start)
                                document.setSpeed(rate)
                            } label: {
                                Text(verbatim: TransportBar.speed(rate))
                            }
                        }
                        Divider()
                        Button { document.removeSpeed(at: speed.start) } label: { Text("Remove Speed", bundle: .module) }
                    }
                    .offset(x: speedLeft, y: Self.clipTop + Self.clipHeight - Self.speedHeight)
                    .accessibilityElement()
                    .accessibilityLabel(Text("\(TransportBar.speed(speed.rate)) speed, \(TransportBar.format(speed.start)) to \(TransportBar.format(speed.end))", bundle: .module))
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                    .accessibilityAction { choose(speed: speed.start) }
                    .accessibilityAction(named: Text("Remove Speed", bundle: .module)) { document.removeSpeed(at: speed.start) }
                    .accessibilityAction(named: Text("Start Earlier", bundle: .module)) { nudge(speedAt: speed.start, start: true, by: -Self.zoomStep) }
                    .accessibilityAction(named: Text("Start Later", bundle: .module)) { nudge(speedAt: speed.start, start: true, by: Self.zoomStep) }
                    .accessibilityAction(named: Text("End Earlier", bundle: .module)) { nudge(speedAt: speed.start, start: false, by: -Self.zoomStep) }
                    .accessibilityAction(named: Text("End Later", bundle: .module)) { nudge(speedAt: speed.start, start: false, by: Self.zoomStep) }
            }
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
                                Text(verbatim: "−" + TransportBar.oneDecimal(document.project.playedLength(of: cut)) + " s")
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
                    .overlay(alignment: .leading) { grip(chosen: chosen, leading: true) }
                    .overlay(alignment: .trailing) { grip(chosen: chosen, leading: false) }
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
                    .accessibilityAction(named: Text("Start Earlier", bundle: .module)) { nudge(cutAt: cut.lowerBound, start: true, by: -Self.zoomStep) }
                    .accessibilityAction(named: Text("Start Later", bundle: .module)) { nudge(cutAt: cut.lowerBound, start: true, by: Self.zoomStep) }
                    .accessibilityAction(named: Text("End Earlier", bundle: .module)) { nudge(cutAt: cut.lowerBound, start: false, by: -Self.zoomStep) }
                    .accessibilityAction(named: Text("End Later", bundle: .module)) { nudge(cutAt: cut.lowerBound, start: false, by: Self.zoomStep) }
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

    /// Subtle native peak waveform silhouette along the bottom of the clip track; dimmed while audio is muted.
    @ViewBuilder
    private func waveformOverlay(width: CGFloat) -> some View {
        let bins = document.waveform
        let duration = document.duration
        if !bins.isEmpty, duration > 0, width > 0 {
            let audio = document.project.audio
            let muted = audio.master.gain <= 0.001
                || (!document.sounds.isEmpty && document.sounds.allSatisfy { audio.effectiveGain(for: $0) <= 0.001 })
            let strong = contrast == .increased
            let barOpacity: Double = muted ? (strong ? 0.32 : 0.22) : (strong ? 0.92 : 0.72)
            let count = bins.count
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(muted ? 0.14 : 0.28)],
                    startPoint: .top, endPoint: .bottom
                )
                Canvas { context, size in
                    let maxBarHeight = size.height - 3
                    let binDuration = duration / Double(count)
                    let firstBin = max(0, Int((viewport.start / binDuration).rounded(.down)))
                    let lastBin = min(count - 1, Int((viewport.end / binDuration).rounded(.up)))
                    guard firstBin <= lastBin else { return }
                    let fill = Color.white.opacity(barOpacity)
                    for index in firstBin...lastBin {
                        let start = Double(index) * binDuration
                        let end = start + binDuration
                        let barLeft = CGFloat(viewport.position(of: start, width: Double(size.width)))
                        let barRight = CGFloat(viewport.position(of: end, width: Double(size.width)))
                        guard barRight >= 0, barLeft <= size.width else { continue }
                        let peak = CGFloat(min(max(bins[index], 0), 1))
                        let barHeight = max(1, peak * maxBarHeight)
                        let gap: CGFloat = (barRight - barLeft) >= 3 ? 1 : 0.5
                        let barWidth = max(1, (barRight - barLeft) - gap)
                        let rect = CGRect(x: barLeft, y: size.height - barHeight, width: barWidth, height: barHeight)
                        context.fill(Path(roundedRect: rect, cornerRadius: min(1, barWidth / 2)), with: .color(fill))
                    }
                }
            }
            .frame(width: width, height: 15)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
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

    /// Snaps either the leading or trailing edge of a block (`start...end`) moved by `rawShift` within
    /// `limits` to the nearest candidate boundary within 5 pt on the timeline. Returns the resulting shift
    /// and the snapped edge's time (for the snap guide), or `nil` when neither edge snapped.
    static func snappedMove(
        start: Double, end: Double, rawShift: Double, limits: ClosedRange<Double>,
        candidates: [Double], duration: Double, width: CGFloat, viewport: StudioTimelineViewport,
        enabled: Bool = true
    ) -> (shift: Double, snappedTime: Double?) {
        let minShift = limits.lowerBound - start
        let maxShift = limits.upperBound - end
        let clampedShift = min(max(rawShift, minShift), maxShift)
        guard enabled else { return (clampedShift, nil) }

        let length = end - start
        let span = max(width - Self.inset * 2, 1)
        let movedStart = start + clampedShift
        let movedEnd = end + clampedShift

        var best: (shift: Double, edgeTime: Double, distance: CGFloat)?

        let startCandidates = candidates.filter {
            $0 >= limits.lowerBound - 1e-9 && $0 <= limits.upperBound - length + 1e-9
        }
        let startSnap = snappedTime(
            movedStart, candidates: startCandidates, duration: duration, width: width, viewport: viewport, enabled: true
        )
        if startSnap.snapped {
            let candidateShift = startSnap.time - start
            if candidateShift >= minShift - 1e-9, candidateShift <= maxShift + 1e-9 {
                let boundedShift = min(max(candidateShift, minShift), maxShift)
                let dist = abs(viewport.position(of: start + boundedShift, width: span) - viewport.position(of: movedStart, width: span))
                best = (boundedShift, start + boundedShift, dist)
            }
        }

        let endCandidates = candidates.filter {
            $0 >= limits.lowerBound + length - 1e-9 && $0 <= limits.upperBound + 1e-9
        }
        let endSnap = snappedTime(
            movedEnd, candidates: endCandidates, duration: duration, width: width, viewport: viewport, enabled: true
        )
        if endSnap.snapped {
            let candidateShift = endSnap.time - end
            if candidateShift >= minShift - 1e-9, candidateShift <= maxShift + 1e-9 {
                let boundedShift = min(max(candidateShift, minShift), maxShift)
                let dist = abs(viewport.position(of: end + boundedShift, width: span) - viewport.position(of: movedEnd, width: span))
                if best == nil || dist < best!.distance {
                    best = (boundedShift, end + boundedShift, dist)
                }
            }
        }

        if let best { return (best.shift, best.edgeTime) }
        return (clampedShift, nil)
    }

    /// Whether a live preview seek to `target` should be issued given the last seeked time, avoiding redundant
    /// seeks for sub-frame deltas (< 1/60 s). When `force` is true (e.g. snapping onto a boundary), any distinct
    /// timestamp still seeks once so the playhead aligns cleanly with the snap guide.
    static func shouldSeekPreview(to target: Double, lastSeeked: Double?, force: Bool = false) -> Bool {
        guard let lastSeeked else { return true }
        if force { return abs(target - lastSeeked) > 1e-6 }
        return abs(target - lastSeeked) >= scrubStep
    }

    /// What a press at `point` is on: a zoom's end or its middle, a layout's end or its middle, a cut's end or
    /// its middle, a speed band's end or its middle, the rest of the clip, or else the ruler, which scrubs.
    /// The drags, the clicks, and the tests all ask this one question, so what the tests find is what the timeline does.
    static func laneHit(
        at point: CGPoint, width: CGFloat, viewport: StudioTimelineViewport,
        zooms: [StudioProject.Zoom], cuts: [ClosedRange<Double>],
        cameraSegments: [StudioProject.CameraSegment] = [], speeds: [StudioProject.Speed] = []
    ) -> LaneHit {
        // Where the timeline draws a time, and the time it reads at a place, as `x(_:width:)` and `time(_:width:)` do.
        func x(_ t: Double) -> CGFloat { Self.inset + viewport.position(of: t, width: width - Self.inset * 2) }
        if point.y < Self.rulerHeight { return .ruler }
        if point.y >= Self.zoomTop, point.y <= Self.zoomTop + Self.zoomHeight,
           let zoom = zooms.first(where: { point.x >= x($0.start) - Self.handleReach && point.x <= x($0.end) + Self.handleReach }) {
            if abs(point.x - x(zoom.start)) <= Self.handleReach { return .zoomResize(zoom.id, start: true) }
            if abs(point.x - x(zoom.end)) <= Self.handleReach { return .zoomResize(zoom.id, start: false) }
            return .zoomMove(zoom.id)
        }
        if point.y >= Self.layoutTop, point.y <= Self.layoutTop + Self.layoutHeight,
           let seg = cameraSegments.first(where: { point.x >= x($0.start) - Self.handleReach && point.x <= x($0.end) + Self.handleReach }) {
            if abs(point.x - x(seg.start)) <= Self.handleReach { return .layoutResize(seg.id, start: true) }
            if abs(point.x - x(seg.end)) <= Self.handleReach { return .layoutResize(seg.id, start: false) }
            return .layoutMove(seg.id)
        }
        if point.y >= Self.clipTop, point.y <= Self.clipTop + Self.clipHeight {
            if let cut = cuts.first(where: { point.x >= x($0.lowerBound) - Self.handleReach && point.x <= x($0.upperBound) + Self.handleReach }) {
                let cutLeft = x(cut.lowerBound), cutRight = x(cut.upperBound)
                if cutRight - cutLeft >= Self.handleReach * 3 {
                    let distStart = abs(point.x - cutLeft)
                    let distEnd = abs(point.x - cutRight)
                    if distStart <= Self.handleReach || distEnd <= Self.handleReach {
                        return .cutResize(cut.lowerBound, start: distStart <= distEnd)
                    }
                    return .cut(cut.lowerBound)
                } else {
                    if point.x >= cutLeft && point.x <= cutRight {
                        return .cut(cut.lowerBound)
                    }
                    return .cutResize(cut.lowerBound, start: point.x < cutLeft)
                }
            }
            // Where the band is drawn, at least `speedWidth` wide; of two drawn over each other, the later, on top.
            if point.y >= Self.clipTop + Self.clipHeight - Self.speedHeight,
               let speed = speeds.last(where: {
                   let left = x($0.start), right = x($0.end)
                   if right - left >= Self.handleReach * 3 {
                       return point.x >= left - Self.handleReach && point.x <= right + Self.handleReach
                   }
                   return point.x >= left && point.x < max(right, left + Self.speedWidth)
               }) {
                let speedLeft = x(speed.start), speedRight = x(speed.end)
                if speedRight - speedLeft >= Self.handleReach * 3 {
                    let distStart = abs(point.x - speedLeft)
                    let distEnd = abs(point.x - speedRight)
                    if distStart <= Self.handleReach || distEnd <= Self.handleReach {
                        return .speedResize(speed.start, start: distStart <= distEnd)
                    }
                }
                return .speed(speed.start)
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

    private func choose(speed start: Double) {
        document.selection = .speed(start)
    }

    private func choose(layout id: UUID) {
        document.selection = .cameraSegment(id)
    }

    private func nudge(_ id: UUID, start: Bool, by shift: Double) {
        guard let zoom = document.project.zooms.first(where: { $0.id == id }) else { return }
        document.setZoomEdge(id, start: start, to: (start ? zoom.start : zoom.end) + shift)
    }

    private func nudge(layout id: UUID, start: Bool, by shift: Double) {
        document.updateCameraSegment(id) { segment in
            if start { segment.start += shift } else { segment.end += shift }
        }
    }

    private func nudge(cutAt cutStart: Double, start: Bool, by shift: Double) {
        guard let cut = document.project.cuts.first(where: { $0.lowerBound == cutStart }) else { return }
        document.setCutEdge(at: cutStart, start: start, to: (start ? cut.lowerBound : cut.upperBound) + shift)
    }

    private func nudge(speedAt speedStart: Double, start: Bool, by shift: Double) {
        guard let speed = document.project.speeds.first(where: { $0.start == speedStart }) else { return }
        document.setSpeedEdge(at: speedStart, start: start, to: (start ? speed.start : speed.end) + shift)
    }

    // MARK: Dragging

    private func snapCandidates(
        excludingZoom zoomID: UUID? = nil,
        excludingSegment segmentID: UUID? = nil,
        excludingSpeed speedStart: Double? = nil,
        excludingCut cutStart: Double? = nil,
        includePlayhead: Bool = true
    ) -> [Double] {
        var points: [Double] = []
        if includePlayhead { points.append(dragStartPlayhead ?? document.time) }
        for cut in document.project.cuts where cut.lowerBound != cutStart {
            points.append(cut.lowerBound)
            points.append(cut.upperBound)
        }
        for speed in document.project.speeds where speed.start != speedStart {
            points.append(speed.start)
            points.append(speed.end)
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

    private func scrubPreview(to time: Double, snapped: Bool = false) {
        let clamped = min(max(time, 0), document.duration)
        guard Self.shouldSeekPreview(to: clamped, lastSeeked: lastScrubTime, force: snapped) else { return }
        lastScrubTime = clamped
        model.controller?.seek(toRecordingTime: clamped)
    }

    private func dragChanged(_ value: DragGesture.Value, width: CGFloat) {
        let point = value.location
        let rawNow = time(point.x, width: width)
        if drag == nil {
            dragStartPlayhead = document.time
            dragMoved = false
            lastScrubTime = nil
            drag = beginDrag(at: value.startLocation, width: width)
        }
        if !dragMoved, hypot(value.translation.width, value.translation.height) > 3 {
            dragMoved = true
        }
        let snapEnabled = !NSEvent.modifierFlags.contains(.command)
        switch drag {
        case .scrub:
            let snapped = Self.snappedTime(
                rawNow, candidates: snapCandidates(includePlayhead: false),
                duration: document.duration, width: width, viewport: viewport, enabled: snapEnabled
            )
            snappedX = snapped.snapped ? x(snapped.time, width: width) : nil
            scrubPreview(to: snapped.time, snapped: snapped.snapped)
        case .select(let from):
            guard dragMoved else { return }
            let snapped = Self.snappedTime(
                rawNow, candidates: snapCandidates(),
                duration: document.duration, width: width, viewport: viewport, enabled: snapEnabled
            )
            snappedX = snapped.snapped ? x(snapped.time, width: width) : nil
            let lower = min(from, snapped.time), upper = max(from, snapped.time)
            document.selection = upper - lower > 0.05 ? .range(lower...upper) : .none
            scrubPreview(to: snapped.time, snapped: snapped.snapped)
        case .moveZoom(let id, let grabbedAt, let start, let end):
            guard dragMoved else { return }
            let moved = Self.snappedMove(
                start: start, end: end, rawShift: rawNow - grabbedAt, limits: 0...max(0, document.duration),
                candidates: snapCandidates(excludingZoom: id),
                duration: document.duration, width: width, viewport: viewport, enabled: snapEnabled
            )
            snappedX = moved.snappedTime.map { x($0, width: width) }
            document.updateZoom(id) { zoom in
                zoom.start = start + moved.shift
                zoom.end = end + moved.shift
            }
            scrubPreview(to: start + moved.shift, snapped: moved.snappedTime != nil)
        case .resizeZoom(let id, let start):
            guard dragMoved else { return }
            let snapped = Self.snappedTime(
                rawNow, candidates: snapCandidates(excludingZoom: id),
                duration: document.duration, width: width, viewport: viewport, enabled: snapEnabled
            )
            snappedX = snapped.snapped ? x(snapped.time, width: width) : nil
            if let updated = document.setZoomEdge(id, start: start, to: snapped.time) {
                scrubPreview(to: start ? updated.lowerBound : updated.upperBound, snapped: snapped.snapped)
            }
        case .moveLayout(let id, let grabbedAt, let start, let end):
            guard dragMoved else { return }
            let limits = document.limits(ofCameraSegment: id)
            let moved = Self.snappedMove(
                start: start, end: end, rawShift: rawNow - grabbedAt, limits: limits,
                candidates: snapCandidates(excludingSegment: id),
                duration: document.duration, width: width, viewport: viewport, enabled: snapEnabled
            )
            snappedX = moved.snappedTime.map { x($0, width: width) }
            document.updateCameraSegment(id) { segment in
                segment.start = start + moved.shift
                segment.end = end + moved.shift
            }
            scrubPreview(to: start + moved.shift, snapped: moved.snappedTime != nil)
        case .resizeLayout(let id, let start):
            guard dragMoved else { return }
            let snapped = Self.snappedTime(
                rawNow, candidates: snapCandidates(excludingSegment: id),
                duration: document.duration, width: width, viewport: viewport, enabled: snapEnabled
            )
            snappedX = snapped.snapped ? x(snapped.time, width: width) : nil
            if let updated = document.setCameraSegmentEdge(id, start: start, to: snapped.time) {
                scrubPreview(to: start ? updated.lowerBound : updated.upperBound, snapped: snapped.snapped)
            }
        case .moveSpeed(let currentStart, let grabbedAt, let initialStart, let initialEnd):
            guard dragMoved else { return }
            let limits = document.limits(ofSpeedAt: currentStart)
            let moved = Self.snappedMove(
                start: initialStart, end: initialEnd, rawShift: rawNow - grabbedAt, limits: limits,
                candidates: snapCandidates(excludingSpeed: currentStart),
                duration: document.duration, width: width, viewport: viewport, enabled: snapEnabled
            )
            snappedX = moved.snappedTime.map { x($0, width: width) }
            if let updated = document.moveSpeed(at: currentStart, to: initialStart + moved.shift) {
                drag = .moveSpeed(currentStart: updated.lowerBound, grabbedAt: grabbedAt, initialStart: initialStart, initialEnd: initialEnd)
                scrubPreview(to: updated.lowerBound, snapped: moved.snappedTime != nil)
            }
        case .resizeSpeed(let speedStart, let start):
            guard dragMoved else { return }
            let snapped = Self.snappedTime(
                rawNow, candidates: snapCandidates(excludingSpeed: speedStart),
                duration: document.duration, width: width, viewport: viewport, enabled: snapEnabled
            )
            snappedX = snapped.snapped ? x(snapped.time, width: width) : nil
            if let updated = document.setSpeedEdge(at: speedStart, start: start, to: snapped.time) {
                drag = .resizeSpeed(updated.lowerBound, start: start)
                scrubPreview(to: start ? updated.lowerBound : updated.upperBound, snapped: snapped.snapped)
            }
        case .cutResize(let cutStart, let leading):
            guard dragMoved else { return }
            let snapped = Self.snappedTime(
                rawNow, candidates: snapCandidates(excludingCut: cutStart),
                duration: document.duration, width: width, viewport: viewport, enabled: snapEnabled
            )
            snappedX = snapped.snapped ? x(snapped.time, width: width) : nil
            if let updated = document.setCutEdge(at: cutStart, start: leading, to: snapped.time) {
                drag = .cutResize(updated.lowerBound, leading: leading)
                scrubPreview(to: leading ? updated.lowerBound : updated.upperBound, snapped: snapped.snapped)
            }
        case nil:
            break
        }
    }

    private func dragEnded(_ value: DragGesture.Value, width: CGFloat) {
        snappedX = nil
        let moved = dragMoved || hypot(value.translation.width, value.translation.height) > 3
        dragMoved = false
        lastScrubTime = nil
        dragStartPlayhead = nil
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
            switch hit(at: point, width: width) {
            case .zoomResize(let id, _), .zoomMove(let id):
                choose(zoom: id)
            case _ where isDoubleClick && point.y >= Self.zoomTop && point.y <= Self.zoomTop + Self.zoomHeight:
                // A double click on the zooms' lane, off every zoom, adds one there.
                model.controller?.seek(toRecordingTime: at)
                document.time = at
                if document.canAddZoom { document.addZoom() }
                document.endContinuousChange()
                drag = nil
                return
            case .layoutResize(let id, _), .layoutMove(let id):
                choose(layout: id)
            case .cutResize(let start, _), .cut(let start):
                choose(cut: start)
            case .speedResize(let start, _), .speed(let start):
                choose(speed: start)
            case .clipRange, .ruler:
                document.selection = .none
            }
            model.controller?.seek(toRecordingTime: at)
        }
        // A dragged edit is taken back in one step.
        document.endContinuousChange()
        drag = nil
    }

    /// What a drag starting at `point` does: on the ruler, scrub; on a zoom, layout, speed, or cut edge, move or
    /// resize it; on the clip, a cut's middle included, choose a stretch.
    private func beginDrag(at point: CGPoint, width: CGFloat) -> Drag {
        let at = time(point.x, width: width)
        switch hit(at: point, width: width) {
        case .ruler:
            return .scrub
        case .zoomResize(let id, let start):
            choose(zoom: id)
            document.beginContinuousChange()
            return .resizeZoom(id, start: start)
        case .zoomMove(let id):
            guard let zoom = document.project.zooms.first(where: { $0.id == id }) else { return .scrub }
            choose(zoom: id)
            document.beginContinuousChange()
            return .moveZoom(id, grabbedAt: at, start: zoom.start, end: zoom.end)
        case .layoutResize(let id, let start):
            choose(layout: id)
            document.beginContinuousChange()
            return .resizeLayout(id, start: start)
        case .layoutMove(let id):
            guard let layout = document.project.cameraSegments.first(where: { $0.id == id }) else { return .scrub }
            choose(layout: id)
            document.beginContinuousChange()
            return .moveLayout(id, grabbedAt: at, start: layout.start, end: layout.end)
        case .speedResize(let start, let isStart):
            choose(speed: start)
            document.beginContinuousChange()
            return .resizeSpeed(start, start: isStart)
        case .speed(let start):
            guard let speed = document.project.speeds.first(where: { $0.start == start }) else { return .scrub }
            choose(speed: start)
            document.beginContinuousChange()
            return .moveSpeed(currentStart: speed.start, grabbedAt: at, initialStart: speed.start, initialEnd: speed.end)
        case .cutResize(let start, let isStart):
            choose(cut: start)
            document.beginContinuousChange()
            return .cutResize(start, leading: isStart)
        case .cut, .clipRange:
            document.selection = .none
            return .select(from: at)
        }
    }

    /// What `point` is on, as the timeline draws it now: the layouts only where the layout can change along the
    /// timeline, which is when their lane is drawn.
    private func hit(at point: CGPoint, width: CGFloat) -> LaneHit {
        Self.laneHit(
            at: point, width: width, viewport: viewport, zooms: document.project.zooms, cuts: document.project.cuts,
            cameraSegments: document.canChangeLayoutAlongTheTimeline ? document.project.cameraSegments : [], speeds: document.project.speeds
        )
    }

    // MARK: Colors

    /// The chip fill (black 0.08, white 0.16 in Dark), doubled under Increase Contrast.
    private static let chipFill = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(cgColor: Theme.ChipFill.selectedColor(dark: appearance.isDark, contrast: false)) ?? .clear
    })
    private static let chipFillStrong = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(cgColor: Theme.ChipFill.selectedColor(dark: appearance.isDark, contrast: true)) ?? .clear
    })
    /// The 1 pt contrast hairline's ink (black 0.35, white 0.5 in Dark).
    private static let contrastHairline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0, alpha: 0.35)
    })
}
