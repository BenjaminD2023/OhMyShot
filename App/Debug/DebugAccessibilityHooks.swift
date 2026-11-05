#if DEBUG
import AppKit
import ApplicationServices
import Foundation
import OMSCore
import OSLog

extension DebugHooks {
    /// Returns true when `hook` was one of these.
    func handleAccessibilityHook(_ hook: String, _ url: URL) -> Bool {
        guard hook == "ax-audit" else { return false }
        // Walks the app's own windows the way VoiceOver does (the accessibility API), and writes to
        // debug-snapshots/ax-audit.json every control a person can act on that has no name: its role, actions, and frame
        // in its window, never its text. labels=<window> adds every control's name and help for the windows of that class
        // (a demo window's, never one holding the person's captures). tree=<window> lists every element of that class's
        // windows, with its custom actions counted (names too with labels). The log has numbers alone.
        let labelsFor = Self.parameter("labels", in: url)
        let treeFor = Self.parameter("tree", in: url)
        // views=<window>: the classes of the views in that window's toolbar items, and each segmented control's segments.
        if let viewsFor = Self.parameter("views", in: url) {
            for window in NSApp.windows where String(describing: type(of: window.windowController ?? window)) == viewsFor {
                for item in window.toolbar?.items ?? [] {
                    Log.app.notice("debug.ax toolbar item=\(String(describing: type(of: item)), privacy: .public)")
                    var views = item.view.map { [($0, 1)] } ?? []
                    while let (view, depth) = views.popLast() {
                        var line = String(repeating: "  ", count: depth) + String(describing: type(of: view))
                        if let control = view as? NSSegmentedControl {
                            line += " segments=\(control.segmentCount)"
                            for segment in 0..<control.segmentCount {
                                line += " [\(segment): menu=\(control.menu(forSegment: segment) != nil) image=\(control.image(forSegment: segment) != nil) label=\(!(control.label(forSegment: segment) ?? "").isEmpty)]"
                            }
                        }
                        Log.app.notice("debug.ax toolbar \(line, privacy: .public)")
                        views.append(contentsOf: view.subviews.reversed().map { ($0, depth + 1) })
                    }
                }
            }
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let windows = NSApp.windows.filter(\.isVisible).map { window in
            let frame = window.frame
            return AccessibilityAudit.Window(
                name: String(describing: type(of: window.windowController ?? window)),
                frame: CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
            )
        }
        // On the main thread: the accessibility API answers the app's own questions in place, on the asking thread, so
        // asked from another thread SwiftUI would read its main-actor state there.
        Self.write(AccessibilityAudit.run(pid: getpid(), windows: windows, labelsFor: labelsFor, treeFor: treeFor))
        return true
    }

    private static func write(_ report: AccessibilityAudit.Report) {
        for window in report.windows {
            Log.app.notice("""
            debug.ax window=\(window.name, privacy: .public) elements=\(window.elements, privacy: .public) \
            controls=\(window.controls, privacy: .public) unnamed=\(window.unnamed.count, privacy: .public) \
            images=\(window.unnamedImages, privacy: .public)
            """)
        }
        if let error = report.error { Log.app.error("debug.ax error=\(error, privacy: .public)") }
        do {
            try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: snapshotDirectory.appending(path: "ax-audit.json"))
        } catch {
            Log.app.error("debug.ax write failed")
        }
    }
}

/// What VoiceOver can reach in the app's own windows, read through the accessibility API.
nonisolated private enum AccessibilityAudit {
    struct Window: Sendable {
        let name: String
        /// In the accessibility API's coordinates: points from the primary display's top-left corner.
        let frame: CGRect
    }

    struct Control: Encodable {
        let role: String
        let subrole: String?
        let identifier: String?
        let actions: [String]
        /// x, y, width, height in points from the window's top-left corner.
        let frame: [Int]
        /// The roles from the window down to it.
        let path: String
        let label: String?
        let help: String?
        var customActions = 0
    }

    struct WindowReport: Encodable {
        let name: String
        var elements = 0
        var controls = 0
        var unnamed: [Control] = []
        var unnamedImages = 0
        /// Every control's name, only for the windows `labels` named.
        var named: [Control] = []
        /// Every element, only for the windows `tree` named.
        var tree: [Control] = []
    }

    struct Report: Encodable {
        var windows: [WindowReport] = []
        var error: String?
    }

    /// Roles a person acts on: a control of one of these without a name is read as its role alone.
    private static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXTextField",
        "AXTextArea", "AXComboBox", "AXLink", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell", "AXSearchField",
    ]

    private static let systemNamedSubroles: Set<String> = [
        "AXCloseButton", "AXZoomButton", "AXMinimizeButton", "AXFullScreenButton", "AXToolbarButton",
        "AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage",
    ]

    static func run(pid: pid_t, windows: [Window], labelsFor: String?, treeFor: String?) -> Report {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3)
        var report = Report()
        guard let axWindows = value(app, kAXWindowsAttribute) as? [AXUIElement] else {
            report.error = "no windows"
            return report
        }
        for axWindow in axWindows {
            let origin = point(axWindow) ?? .zero
            let size = self.size(axWindow) ?? .zero
            let frame = CGRect(origin: origin, size: size)
            let name = windows.first { abs($0.frame.minX - frame.minX) < 2 && abs($0.frame.minY - frame.minY) < 2 && abs($0.frame.width - frame.width) < 2 }?.name ?? "?"
            var windowReport = WindowReport(name: name)
            walk(axWindow, path: "", origin: origin, depth: 0, into: &windowReport, keepNames: name == labelsFor, keepTree: name == treeFor)
            report.windows.append(windowReport)
        }
        return report
    }

    private static func walk(
        _ element: AXUIElement, path: String, origin: CGPoint, depth: Int, into report: inout WindowReport, keepNames: Bool, keepTree: Bool
    ) {
        guard depth < 60, report.elements < 20000 else { return }
        report.elements += 1
        let role = value(element, kAXRoleAttribute) as? String ?? "?"
        let here = path.isEmpty ? role : path + "/" + role
        let actions = actionNames(element)
        // The window's own buttons and a scroll bar's parts are named by the system from their subroles, and text is read
        // by its value: none of these needs a name of its own.
        let subrole = value(element, kAXSubroleAttribute) as? String
        let systemNamed = subrole.map(systemNamedSubroles.contains) ?? false || path.hasSuffix("AXScrollBar")
        let isControl = !systemNamed && (controlRoles.contains(role)
            || (actions.contains(kAXPressAction as String) && !["AXWindow", "AXMenuItem", "AXStaticText"].contains(role)))
        let label = [kAXTitleAttribute, kAXDescriptionAttribute]
            .compactMap { value(element, $0) as? String }
            .first { !$0.isEmpty }
        let titled = value(element, kAXTitleUIElementAttribute) != nil
        let placeholder = (value(element, kAXPlaceholderValueAttribute) as? String).map { !$0.isEmpty } ?? false
        func control(keepingText: Bool) -> Control {
            let position = point(element) ?? origin
            let size = self.size(element) ?? .zero
            return Control(
                role: role,
                subrole: subrole,
                identifier: value(element, kAXIdentifierAttribute) as? String,
                actions: actions.filter { !$0.hasPrefix("AXScroll") },
                frame: [Int(position.x - origin.x), Int(position.y - origin.y), Int(size.width), Int(size.height)],
                path: here,
                label: keepingText ? label : nil,
                help: keepingText ? value(element, kAXHelpAttribute) as? String : nil
            )
        }
        if isControl {
            report.controls += 1
            if label == nil && !titled && !placeholder {
                report.unnamed.append(control(keepingText: false))
            } else if keepNames {
                report.named.append(control(keepingText: true))
            }
        } else if role == "AXImage", label == nil {
            report.unnamedImages += 1
            report.unnamed.append(control(keepingText: false))
        }
        if keepTree {
            var entry = control(keepingText: keepNames)
            entry.customActions = (value(element, "AXCustomActions") as? [AnyObject])?.count ?? 0
            report.tree.append(entry)
        }
        for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            walk(child, path: here, origin: origin, depth: depth + 1, into: &report, keepNames: keepNames, keepTree: keepTree)
        }
    }

    private static func value(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private static func point(_ element: AXUIElement) -> CGPoint? {
        guard let value = value(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ element: AXUIElement) -> CGSize? {
        guard let value = value(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }
}
#endif
