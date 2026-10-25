import AppKit
import SwiftUI

/// Native horizontal scrollbar with a thumb that represents the visible duration.
struct StudioTimelineScroller: NSViewRepresentable {
    @Binding var position: Double
    let visible: Double
    let duration: Double

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScroller {
        let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 100, height: 14))
        scroller.scrollerStyle = .legacy
        scroller.controlSize = .small
        scroller.target = context.coordinator
        scroller.action = #selector(Coordinator.changed(_:))
        scroller.setAccessibilityLabel(String(localized: "Timeline Position", bundle: .module))
        return scroller
    }

    func updateNSView(_ scroller: NSScroller, context: Context) {
        context.coordinator.parent = self
        scroller.knobProportion = duration > 0 ? min(visible / duration, 1) : 1
        scroller.doubleValue = duration > visible ? position / (duration - visible) : 0
        scroller.isEnabled = duration > visible
    }

    final class Coordinator: NSObject {
        var parent: StudioTimelineScroller
        init(_ parent: StudioTimelineScroller) { self.parent = parent }

        @objc func changed(_ sender: NSScroller) {
            switch sender.hitPart {
            case .decrementPage: parent.position -= parent.visible * 0.9
            case .incrementPage: parent.position += parent.visible * 0.9
            case .decrementLine: parent.position -= parent.visible * 0.05
            case .incrementLine: parent.position += parent.visible * 0.05
            default: parent.position = sender.doubleValue * max(parent.duration - parent.visible, 0)
            }
        }
    }
}

/// Passes through pointer presses and handles only wheel events over the timeline, preserving its gestures.
struct StudioTimelineWheel: NSViewRepresentable {
    var scroll: (Double) -> Void
    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ view: WheelView, context: Context) { view.scroll = scroll }

    final class WheelView: NSView {
        var scroll: ((Double) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .scrollWheel else { return nil }
            return super.hitTest(point)
        }

        override func scrollWheel(with event: NSEvent) {
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            scroll?(-Double(delta) * (event.hasPreciseScrollingDeltas ? 1 : 12))
        }
    }
}
