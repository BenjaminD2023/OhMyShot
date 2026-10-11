import AppKit
import OMSCore
import SwiftUI

/// The timeline: a ruler of seconds, the clip with its pictures and its cuts, the zooms above it, and the
/// playhead.
///
/// Click anywhere to move the playhead, drag on the ruler to scrub, drag along the clip to choose a stretch for
/// Cut. A zoom is chosen with a click; its ends drag to change when it starts and stops, its middle to move it.
/// A cut is chosen with a click; Delete takes it back (or removes a chosen zoom). With the timeline focused,
/// ← and → move the playhead (⇧ by a second), I and O choose a stretch from or to it, and Delete removes what is
/// chosen or cuts the chosen stretch. Zooms and cuts have their commands in a menu and for VoiceOver too.
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
    }

    @State private var drag: Drag?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                ruler(width: width)
                zooms(width: width)
                clip(width: width)
                playhead(width: width, height: geometry.size.height)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in dragChanged(value, width: width) }
                    .onEnded { value in dragEnded(value, width: width) }
            )
        }
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .focusable()
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
            let step = press.modifiers.contains(.shift) ? Self.longStep : Self.step
            model.controller?.seek(toRecordingTime: document.time + (press.key == .leftArrow ? -step : step))
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "iIoO"), phases: .down) { press in
            mark(start: press.characters.lowercased() == "i")
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward], phases: .down) { _ in
            removeChosen()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Timeline", bundle: .module))
    }

    // MARK: Drawing

    private func x(_ time: Double, width: CGFloat) -> CGFloat {
        let span = width - Self.inset * 2
        return Self.inset + CGFloat(document.duration > 0 ? time / document.duration : 0) * span
    }

    private func time(_ x: CGFloat, width: CGFloat) -> Double {
        let span = max(width - Self.inset * 2, 1)
        return min(max(Double((x - Self.inset) / span) * document.duration, 0), document.duration)
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
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let step = steps.first { Double(span) / (document.duration / $0) >= 64 } ?? 600
        let marks = Array(stride(from: 0.0, through: document.duration, by: step))
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
        ForEach(document.project.zooms) { zoom in
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

    private func clip(width: CGFloat) -> some View {
        let left = x(0, width: width), right = x(document.duration, width: width)
        let clipWidth = max(right - left, 1)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor))
                .overlay(alignment: .leading) { filmstrip(width: clipWidth) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(lineColor, lineWidth: lineWidth))
                .frame(width: clipWidth, height: Self.clipHeight)
                .offset(x: left, y: Self.clipTop)
            ForEach(document.project.cuts, id: \.lowerBound) { cut in
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
            if let range = model.selectedRange {
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

    /// The recording's pictures side by side along the clip, each as wide as the recording's shape makes it
    /// at the clip's height, each showing its own stretch.
    private func filmstrip(width: CGFloat) -> some View {
        let pictures = model.filmstrip
        let shape = document.recordingSize.height > 0 ? document.recordingSize.width / document.recordingSize.height : 16.0 / 10
        let slot = max(Self.clipHeight * shape, 8)
        let count = pictures.isEmpty ? 0 : max(1, Int((width / slot).rounded(.up)))
        return HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                let middle = (CGFloat(index) + 0.5) * slot / width
                let picture = pictures[min(pictures.count - 1, max(0, Int(middle * CGFloat(pictures.count))))]
                Image(decorative: picture, scale: 2)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: slot, height: Self.clipHeight)
                    .clipped()
            }
        }
        .frame(width: width, height: Self.clipHeight, alignment: .leading)
        .clipped()
        .accessibilityHidden(true)
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
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(Text("Playhead", bundle: .module))
        .accessibilityValue(TransportBar.spokenPosition(of: document))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.5 : -0.5
            model.controller?.seek(toRecordingTime: document.time + step)
        }
    }

    // MARK: Commands

    private func choose(zoom id: UUID) {
        document.selectedZoom = id
        document.selectedCut = nil
    }

    private func choose(cut start: Double) {
        document.selectedCut = start
        document.selectedZoom = nil
    }

    private func nudge(_ id: UUID, start: Bool, by shift: Double) {
        document.updateZoom(id) { zoom in
            if start { zoom.start = min(zoom.start + shift, zoom.end - 0.3) } else { zoom.end = max(zoom.end + shift, zoom.start + 0.3) }
        }
    }

    /// I chooses a stretch from the playhead (to the end of the one chosen, or of the recording); O to it.
    private func mark(start: Bool) {
        let now = document.time
        let range = model.selectedRange
        let lower = start ? now : (range?.lowerBound ?? 0)
        let upper = start ? (range?.upperBound ?? document.duration) : now
        model.selectedRange = upper - lower > 0.05 ? lower...upper : nil
    }

    /// Delete: the chosen zoom or cut goes, or else the chosen stretch is cut.
    private func removeChosen() {
        if document.selectedZoom != nil || document.selectedCut != nil {
            document.deleteSelection()
        } else if let range = model.selectedRange {
            document.cut(range)
            model.selectedRange = nil
        }
    }

    // MARK: Dragging

    private func dragChanged(_ value: DragGesture.Value, width: CGFloat) {
        let point = value.location
        let now = time(point.x, width: width)
        if drag == nil {
            drag = beginDrag(at: value.startLocation, width: width)
        }
        switch drag {
        case .scrub:
            model.controller?.seek(toRecordingTime: now)
        case .select(let from):
            let lower = min(from, now), upper = max(from, now)
            model.selectedRange = upper - lower > 0.05 ? lower...upper : nil
        case .moveZoom(let id, let grabbedAt, let start, let end):
            let shift = min(max(now - grabbedAt, -start), document.duration - end)
            document.updateZoom(id) { zoom in
                zoom.start = start + shift
                zoom.end = end + shift
            }
        case .resizeZoom(let id, let start):
            document.updateZoom(id) { zoom in
                if start { zoom.start = min(now, zoom.end - 0.3) } else { zoom.end = max(now, zoom.start + 0.3) }
            }
        case nil:
            break
        }
    }

    private func dragEnded(_ value: DragGesture.Value, width: CGFloat) {
        let moved = hypot(value.translation.width, value.translation.height) > 3
        if !moved {
            // A click: choose what is under it, and move the playhead there.
            let point = value.startLocation
            let at = time(point.x, width: width)
            if let zoom = zoom(at: point, width: width) {
                choose(zoom: zoom.id)
            } else if point.y >= Self.clipTop, let cut = document.project.cuts.first(where: { $0.contains(at) }) {
                choose(cut: cut.lowerBound)
            } else {
                document.selectedZoom = nil
                document.selectedCut = nil
            }
            model.selectedRange = nil
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
        if point.y >= Self.clipTop {
            document.selectedZoom = nil
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
