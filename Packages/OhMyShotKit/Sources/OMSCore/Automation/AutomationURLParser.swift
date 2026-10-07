import CoreGraphics
import Foundation

public enum AutomationURLError: Error, Equatable, Sendable {
    case wrongScheme(String?)
    case unknownCommand(String)
    case missingParameter(String)
    case invalidParameter(name: String, value: String)
}

/// Parses `<scheme>://<command>?<parameters>` URLs. Unknown parameters are ignored, so callers written
/// for newer versions of CleanShot's API keep working.
public enum AutomationURLParser {
    public static func parse(_ url: URL, scheme: String) -> Result<AutomationCommand, AutomationURLError> {
        guard url.scheme?.lowercased() == scheme.lowercased() else {
            return .failure(.wrongScheme(url.scheme))
        }
        let name = (url.host(percentEncoded: false) ?? "").lowercased()
        var parameters: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            parameters[item.name.lowercased()] = item.value ?? ""
        }
        do {
            return .success(try command(named: name, parameters: Parameters(values: parameters)))
        } catch let error as AutomationURLError {
            return .failure(error)
        } catch {
            return .failure(.unknownCommand(name))
        }
    }

    private static func command(named name: String, parameters p: Parameters) throws -> AutomationCommand {
        switch name {
        case "all-in-one":
            return .allInOne(try p.region())
        case "capture-area":
            return .captureArea(try p.region(), action: try p.action())
        case "capture-previous-area":
            return .capturePreviousArea(action: try p.action())
        case "capture-fullscreen":
            return .captureFullscreen(action: try p.action())
        case "capture-window":
            return .captureWindow(action: try p.action())
        case "self-timer":
            return .selfTimer(action: try p.action())
        case "scrolling-capture":
            return .scrollingCapture(
                try p.region(),
                start: try p.bool("start") ?? false,
                autoscroll: try p.bool("autoscroll") ?? false
            )
        case "pin":
            return .pin(file: try p.file())
        case "record-screen":
            return .recordScreen(try p.region())
        case "capture-text":
            return .captureText(file: try p.file(), region: try p.region(), lineBreaks: try p.bool("linebreaks"))
        case "open-annotate":
            return .openAnnotate(file: try p.file())
        case "open-from-clipboard":
            return .openFromClipboard
        case "toggle-desktop-icons":
            return .toggleDesktopIcons
        case "hide-desktop-icons":
            return .hideDesktopIcons
        case "show-desktop-icons":
            return .showDesktopIcons
        case "add-quick-access-overlay":
            guard let file = try p.file() else { throw AutomationURLError.missingParameter("filepath") }
            return .addQuickAccessOverlay(file: file)
        case "open-history":
            return .openHistory
        case "restore-recently-closed":
            return .restoreRecentlyClosed
        case "open-settings":
            return .openSettings(tab: p.values["tab"])
        default:
            throw AutomationURLError.unknownCommand(name)
        }
    }
}

private struct Parameters {
    let values: [String: String]

    /// `x`, `y`, `width`, and `height` come as a set or not at all; `display` may come alone.
    func region() throws -> AutomationRegion {
        let names = ["x", "y", "width", "height"]
        let given = names.filter { values[$0] != nil }
        var rect: CGRect?
        if !given.isEmpty {
            guard given.count == names.count else {
                let missing = names.first { values[$0] == nil } ?? "x"
                throw AutomationURLError.missingParameter(missing)
            }
            let x = try number("x"), y = try number("y")
            let width = try number("width"), height = try number("height")
            guard width > 0 else { throw AutomationURLError.invalidParameter(name: "width", value: values["width"] ?? "") }
            guard height > 0 else { throw AutomationURLError.invalidParameter(name: "height", value: values["height"] ?? "") }
            rect = CGRect(x: x, y: y, width: width, height: height)
        }
        var display: Int?
        if let raw = values["display"] {
            guard let number = Int(raw), number >= 1 else {
                throw AutomationURLError.invalidParameter(name: "display", value: raw)
            }
            display = number
        }
        return AutomationRegion(rect: rect, display: display)
    }

    func action() throws -> CaptureAction? {
        guard let raw = values["action"] else { return nil }
        guard let action = CaptureAction(rawValue: raw.lowercased()) else {
            throw AutomationURLError.invalidParameter(name: "action", value: raw)
        }
        return action
    }

    /// An absolute path, optionally starting with `~`. Existence is checked by whoever opens it.
    func file() throws -> URL? {
        guard let raw = values["filepath"] else { return nil }
        let path = (raw as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else {
            throw AutomationURLError.invalidParameter(name: "filepath", value: raw)
        }
        return URL(filePath: path).standardizedFileURL
    }

    func bool(_ name: String) throws -> Bool? {
        guard let raw = values[name] else { return nil }
        switch raw.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: throw AutomationURLError.invalidParameter(name: name, value: raw)
        }
    }

    private func number(_ name: String) throws -> CGFloat {
        let raw = values[name] ?? ""
        guard let value = Double(raw), value.isFinite else {
            throw AutomationURLError.invalidParameter(name: name, value: raw)
        }
        return CGFloat(value)
    }
}
