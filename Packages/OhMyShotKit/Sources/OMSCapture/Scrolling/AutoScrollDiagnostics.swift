#if DEBUG
import AppKit
import Foundation

/// Exercises production delivery against the dedicated input-probe process built by
/// Scripts/scroll-input-check.sh. The real pointer is observed, never positioned for the test.
public enum AutoScrollDiagnostics {
    public static func externalDelivery() async -> String {
        let url = URL(fileURLWithPath: "/tmp/ohmyshot-input-receiver.json")
        func state() -> [String: Any] {
            guard let data = try? Data(contentsOf: url) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        let info = state()
        guard let pid = info["pid"] as? Int32, let id = info["window"] as? UInt32,
              let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == "io.github.fzlzjerry.ohmyshot.input-probe",
              let x = info["x"] as? Double, let y = info["y"] as? Double,
              let width = info["width"] as? Double, let height = info["height"] as? Double else { return "FAIL: receiver unavailable" }
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let target = AutoScrollDestination(application: app, windowID: id, location: CGPoint(x: frame.midX, y: frame.midY), frame: frame)
        defer { app.terminate() }
        let source = CGEventSource(stateID: .hidSystemState)
        let before = NSEvent.mouseLocation
        let initial = info["offset"] as? Double ?? 0
        var hardwareWheels = 0
        let monitor = AutoScrollWheelMonitor(observesPointer: true) { _ in hardwareWheels += 1 }
        let monitored = monitor.start()
        defer { monitor.stop() }
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let anchor = CGPoint(x: target.location.x, y: primaryHeight - target.location.y)
        for index in 0..<12 {
            let oldPoint = NSEvent.mouseLocation
            let hardwareMoves = monitor.pointerEvents
            target.post(distance: 16, axis: .vertical, source: source, phase: index == 0 ? .began : .changed)
            try? await Task.sleep(for: .milliseconds(30))
            let point = NSEvent.mouseLocation
            if monitor.pointerEvents == hardwareMoves, hypot(oldPoint.x - anchor.x, oldPoint.y - anchor.y) > 3,
               hypot(point.x - anchor.x, point.y - anchor.y) < 3 { return "FAIL: pointer snapped to target; aborted" }
        }
        try? await Task.sleep(for: .milliseconds(120))
        let down = state()["offset"] as? Double ?? 0
        for _ in 0..<6 {
            target.post(distance: -16, axis: .vertical, source: source, phase: .changed)
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(120))
        let after = NSEvent.mouseLocation
        let up = state()["offset"] as? Double ?? 0
        let received = state()["received"] as? Int ?? 0
        let drift = hypot(after.x - before.x, after.y - before.y)
        target.post(distance: 0, axis: .vertical, source: source, phase: .ended)
        let passed = received == 18 && abs(down - initial - 192) < 0.5 && abs(up - initial - 96) < 0.5
            && (drift < 0.5 || monitor.pointerEvents > 0) && monitored
        let status = hardwareWheels > 0 ? "INCONCLUSIVE: hardware wheel input during check" : passed ? "PASS" : "FAIL"
        return "\(status): cross-process received \(received), offset \(initial) -> \(down) -> \(up), cursor displacement \(drift), hardware mouse moves \(monitor.pointerEvents), hardware wheel events \(hardwareWheels), monitor \(monitored)"
    }

}
#endif
