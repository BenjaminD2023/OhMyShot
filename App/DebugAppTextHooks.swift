#if DEBUG
import AppKit
import Foundation
import OMSCapture
import OMSCore
import OMSOCR
import OSLog

extension DebugHooks {
    /// Returns true when `hook` was one of these.
    func handleAppTextHook(_ hook: String, _ url: URL) -> Bool {
        guard hook == "app-text" else { return false }
        // x, y, w, h: an area in AppKit's global points (default: the centered region text-test reads); window=<id> instead
        // reads that window alone, covered or not, asking its own app, as Capture Text does a window. Asks the apps there
        // whatever Settings says, then writes the area's geometry, the windows at its middle, and what was found to
        // debug-snapshots/app-text.json. The texts (Vision's lines, the apps' answers, the merged lines) go in only when
        // only=<app name> owns the window read, or the window in front at the area's middle: a check must never write down
        // the person's own windows. The log has numbers alone.
        let number = { (name: String) in Self.parameter(name, in: url).flatMap(Double.init).map { CGFloat($0) } }
        guard let display = displays.layout.primary else { return true }
        let rect = CGRect(
            x: number("x") ?? display.frame.midX - 200, y: number("y") ?? display.frame.midY - 150,
            width: number("w") ?? 400, height: number("h") ?? 300
        )
        let window = Self.parameter("window", in: url).flatMap { CGWindowID($0) }
        let only = Self.parameter("only", in: url)
        Task { await readAppText(in: rect, window: window, only: only) }
        return true
    }

    private struct AppTextReport: Encodable {
        struct Answer: Encodable {
            let line: Int
            let app: String
            let pieces: [String]
        }

        let allowed: Bool
        /// The area as captured (AppKit's global points), the picture's size, and each Vision line's box in it.
        let frame: [CGFloat]
        let pixels: [Int]
        let boxes: [[Int]]
        /// The windows at the area's middle when it was read, front to back.
        let windows: [String]
        let milliseconds: Int
        let points: Int
        let outOfTime: Bool
        let secure: Int
        let vision: [String]
        let answers: [Answer]
        let merged: [String]
        let taken: [Int]
        let source: String?
    }

    private func readAppText(in rect: CGRect, window: CGWindowID?, only: String?) async {
        let allowed = AppText.isAllowed
        do {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let frame: CapturedFrame
            var pid: pid_t?
            var owner: String?
            if let window, let info = list.first(where: { $0[kCGWindowNumber as String] as? CGWindowID == window }),
               let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] {
                let cgFrame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
                owner = info[kCGWindowOwnerName as String] as? String
                pid = info[kCGWindowOwnerPID as String] as? pid_t
                let target = WindowTarget(id: window, frame: displays.layout.flipped(cgFrame), ownerName: owner ?? "", title: nil)
                frame = try await capturer.captureWindow(target, shadow: false, layout: displays.layout)
            } else {
                frame = try await capturer.captureArea(rect, in: displays.layout)
            }
            let lines = try await VisionPipeline(options: .preferred()).recognize(frame.image).lines
            let place = AppTextPlace(frame: frame.frame, scale: CGFloat(frame.image.width) / max(frame.frame.width, 1), pid: pid)
            let reading = await AppText.read(lines.map(\.box), in: place, layout: displays.layout)
            let read = reading.lines.map { AppTextLine(box: $0.box, pieces: $0.pieces, app: $0.app) }
            let merge = AppTextMerge.merged(lines, with: read)
            let milliseconds = Int(reading.duration.components.seconds * 1000 + reading.duration.components.attoseconds / 1_000_000_000_000_000)
            let middle = displays.layout.flipped(CGPoint(x: frame.frame.midX, y: frame.frame.midY))
            let front = list.first { info in
                guard (info[kCGWindowOwnerPID as String] as? pid_t) != ProcessInfo.processInfo.processIdentifier,
                      let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
                return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0).contains(middle)
                    && (info[kCGWindowLayer as String] as? Int) == 0
            }
            let shows = only != nil && only == (owner ?? front?[kCGWindowOwnerName as String] as? String)
            let windows = list.compactMap { info -> String? in
                guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
                let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
                guard rect.contains(middle) else { return nil }
                return "\(info[kCGWindowOwnerName as String] as? String ?? "") layer \(info[kCGWindowLayer as String] as? Int ?? 0) \(rect)"
            }
            let report = AppTextReport(
                allowed: allowed, frame: [frame.frame.minX, frame.frame.minY, frame.frame.width, frame.frame.height],
                pixels: [frame.image.width, frame.image.height],
                boxes: lines.map { [Int($0.box.minX), Int($0.box.minY), Int($0.box.width), Int($0.box.height)] },
                windows: windows, milliseconds: milliseconds, points: reading.points, outOfTime: reading.outOfTime, secure: reading.secure,
                vision: shows ? lines.map(\.text) : [],
                answers: reading.lines.compactMap { answer in
                    lines.firstIndex { $0.box == answer.box }.map { AppTextReport.Answer(line: $0, app: answer.app, pieces: shows ? answer.pieces : []) }
                },
                merged: shows ? merge.lines.map(\.text) : [], taken: merge.taken, source: merge.source
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try FileManager.default.createDirectory(at: Self.snapshotDirectory, withIntermediateDirectories: true)
            try encoder.encode(report).write(to: Self.snapshotDirectory.appending(path: "app-text.json"))
            let changed = merge.changed
            Log.app.notice("debug.app-text allowed=\(allowed, privacy: .public) texts=\(shows, privacy: .public) lines=\(lines.count, privacy: .public) answered=\(reading.lines.count, privacy: .public) taken=\(merge.taken.count, privacy: .public) dropped=\(merge.dropped, privacy: .public) changed=\(changed, privacy: .public) points=\(reading.points, privacy: .public) ms=\(milliseconds, privacy: .public) outOfTime=\(reading.outOfTime, privacy: .public)")
        } catch {
            Log.app.error("debug.app-text failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
