import AppKit
import ApplicationServices
import OMSCore

/// Where a picture of the screen came from, so the apps there can be asked for the text they show (L0,
/// Docs/ocr.md › Text from apps).
public nonisolated struct AppTextPlace: Sendable, Equatable {
    /// The picture's area in AppKit's global space, in points.
    public var frame: CGRect
    /// The picture's pixels per point.
    public var scale: CGFloat
    /// The app whose window the picture is of (a window capture), asked wherever the window is, covered or not; nil
    /// asks the app whose window is in front at each line.
    public var pid: pid_t?

    public init(frame: CGRect, scale: CGFloat, pid: pid_t? = nil) {
        self.frame = frame
        self.scale = scale
        self.pid = pid
    }
}

/// What an app shows under one line of a picture: the text of each place along it, left to right.
public nonisolated struct AppTextPieces: Sendable, Equatable {
    /// The line's box in the picture, in pixels, as it was asked about.
    public var box: CGRect
    public var pieces: [String]
    /// The app's name.
    public var app: String

    public init(box: CGRect, pieces: [String], app: String) {
        self.box = box
        self.pieces = pieces
        self.app = app
    }
}

/// What the apps under a picture said about its lines.
public nonisolated struct AppTextReading: Sendable, Equatable {
    public var lines: [AppTextPieces] = []
    /// The lines asked about: all of them, unless time ran out.
    public var asked = 0
    /// Lines over a password field (or an element that couldn't say what it is), left alone.
    public var secure = 0
    /// Points asked: one question to an app each, and up to four more for a line of a text view.
    public var points = 0
    public var outOfTime = false
    public var duration: Duration = .zero

    public init() {}
}

/// Asks the apps under a picture of the screen, through Accessibility, for the text they show where Vision read its
/// lines (L0, Docs/ocr.md › Text from apps).
///
/// At points along each line it asks the app whose window is in front there (the picture's own app, for a window)
/// for the element at that point: of a text view or field, the line of text at the point; of anything else, its
/// text (a label's value, a button's title). Password fields are passed over. OhMyShot's own windows (the overlay, the
/// highlight, the Recognized Text window) are never asked: an app is asked about its own windows, wherever others lie.
/// Each question waits a tenth of a second at most, an app that doesn't answer in time isn't asked again, and the
/// whole reading stops at its budget: Capture Text then copies Vision's reading alone. Apps that don't share their
/// text unless told to turn their accessibility on (Chrome, Electron apps) say nothing, and are left as they are.
public nonisolated enum AppText {
    /// Whether OhMyShot may ask other apps for their text: Accessibility is on for it in System Settings.
    public static var isAllowed: Bool { AXIsProcessTrusted() }

    /// What the apps under `place` show at `boxes` (lines of its picture, in pixels).
    @concurrent
    public static func read(_ boxes: [CGRect], in place: AppTextPlace, layout: DisplayLayout, within budget: Duration = .milliseconds(150)) async -> AppTextReading {
        guard !boxes.isEmpty, isAllowed else { return AppTextReading() }
        let started = ContinuousClock.now
        let source = SystemAppText(excluding: ProcessInfo.processInfo.processIdentifier, until: started + budget)
        var reading = gather(boxes, frame: layout.flipped(place.frame), scale: place.scale, pid: place.pid, from: source, until: started + budget)
        reading.duration = ContinuousClock.now - started
        return reading
    }

    /// The reading, with `source` for Accessibility. `frame` is the picture's area in Core Graphics' global space
    /// (the top left of the main display at the origin, y down), where Accessibility places things.
    static func gather<Source: AppTextSource>(
        _ boxes: [CGRect], frame: CGRect, scale: CGFloat, pid: pid_t?, from source: Source, until deadline: ContinuousClock.Instant
    ) -> AppTextReading {
        var reading = AppTextReading()
        var texts: [Source.Element: String?] = [:]
        var names: [pid_t: String] = [:]
        lines: for box in boxes {
            let rect = CGRect(x: frame.minX + box.minX / scale, y: frame.minY + box.minY / scale, width: box.width / scale, height: box.height / scale)
            var pieces: [(key: Piece<Source.Element>, text: String)] = []
            var app: pid_t?
            var secure = false
            // Whether what was found covers the line from end to end, so the points left need not be asked.
            var covered = false
            var lastWithLines: Source.Element?
            for point in points(along: rect) {
                guard ContinuousClock.now < deadline else {
                    reading.outOfTime = true
                    break lines
                }
                reading.points += 1
                for candidate in pid.map({ [$0] }) ?? source.apps(at: point) {
                    guard let element = source.element(at: point, in: candidate) else { continue }
                    if source.isSecure(element) {
                        secure = true
                        break
                    }
                    // A line holds one line of a text view: the points after the first on it ask nothing more.
                    if element == lastWithLines { break }
                    let found: (key: Piece<Source.Element>, text: String)?
                    var extent: CGRect?
                    if let line = source.line(of: element, at: point) {
                        lastWithLines = element
                        found = (Piece(element: element, start: line.start), line.text)
                        extent = line.bounds
                    } else {
                        let known = texts[element] != nil
                        let text = texts[element] ?? source.text(of: element)
                        texts[element] = text
                        found = text.map { (Piece(element: element, start: nil), $0) }
                        if found != nil, !known { extent = source.frame(of: element) }
                    }
                    guard let found, !found.text.allSatisfy(\.isWhitespace) else { continue }
                    // A window's title says itself twice (its title and its document's).
                    if !pieces.contains(where: { $0.key == found.key }), pieces.last?.text != found.text { pieces.append(found) }
                    app = app ?? candidate
                    let slack = rect.height / 2
                    if let extent, extent.minX <= rect.minX + slack, extent.maxX >= rect.maxX - slack { covered = true }
                    break
                }
                if secure || covered { break }
            }
            reading.asked += 1
            if secure {
                reading.secure += 1
            } else if let app, !pieces.isEmpty {
                let name = names[app] ?? source.name(of: app)
                names[app] = name
                reading.lines.append(AppTextPieces(box: box, pieces: pieces.map(\.text), app: name))
            }
        }
        return reading
    }

    /// Where to ask along a line: a point at its middle when it is short, else from near one end to near the other,
    /// about four line heights apart, eight at most. The points left go unasked once what was found reaches from one
    /// end of the line to the other: a line of a text view, a paragraph of a web page.
    static func points(along rect: CGRect) -> [CGPoint] {
        let height = max(rect.height, 1)
        guard rect.width > height * 2 else { return [CGPoint(x: rect.midX, y: rect.midY)] }
        let inset = min(height / 2, rect.width / 4)
        let span = rect.width - inset * 2
        let count = min(8, max(2, Int((span / (height * 4)).rounded(.up)) + 1))
        return (0..<count).map { CGPoint(x: rect.minX + inset + span * CGFloat($0) / CGFloat(count - 1), y: rect.midY) }
    }

    /// One place's text along a line: an element, and for one with lines, where the line starts in it.
    struct Piece<Element: Hashable>: Hashable {
        let element: Element
        let start: Int?
    }
}

/// The parts of Accessibility `AppText` asks, apart for tests.
nonisolated protocol AppTextSource {
    associatedtype Element: Hashable
    /// The apps to ask at a point in Core Graphics' global space, nearest first: the one whose window is in front, then
    /// those behind a window that may let them show through (one above standard windows, which may be clear: a drop
    /// shelf at the top of the screen, a floating panel).
    func apps(at point: CGPoint) -> [pid_t]
    func element(at point: CGPoint, in app: pid_t) -> Element?
    func isSecure(_ element: Element) -> Bool
    /// The line of text at a point of an element that has lines (a text view, a field): where it starts in the
    /// element's text, what it says, and where it is on screen when the element says.
    func line(of element: Element, at point: CGPoint) -> (start: Int, text: String, bounds: CGRect?)?
    /// The text of an element without lines: a label's value, a button's title.
    func text(of element: Element) -> String?
    /// Where an element is on screen.
    func frame(of element: Element) -> CGRect?
    func name(of app: pid_t) -> String
}

/// Accessibility itself. Nothing is asked past the reading's deadline, so a point whose app answers slowly costs no more
/// than the time left.
nonisolated final class SystemAppText: AppTextSource {
    private struct Window {
        let pid: pid_t
        let frame: CGRect
        let isStandard: Bool
    }

    /// How long one question waits for an app's answer.
    static let timeout: Float = 0.1
    /// The longest text taken from an element without lines (past it, most likely a whole document).
    static let longest = 8000

    /// On screen, front to back, other than OhMyShot's.
    private let windows: [Window]
    private let deadline: ContinuousClock.Instant
    private var applications: [pid_t: AXUIElement] = [:]
    /// Apps that didn't answer a question in time, or aren't apps (the window server's windows).
    private var mute: Set<pid_t> = []

    init(excluding own: pid_t, until deadline: ContinuousClock.Instant) {
        self.deadline = deadline
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        windows = list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  (info[kCGWindowAlpha as String] as? CGFloat ?? 1) > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            return Window(pid: pid, frame: frame, isStandard: (info[kCGWindowLayer as String] as? Int) == 0)
        }
    }

    func apps(at point: CGPoint) -> [pid_t] {
        var apps: [pid_t] = []
        for window in windows where window.frame.contains(point) {
            if !mute.contains(window.pid), !apps.contains(window.pid) { apps.append(window.pid) }
            if window.isStandard || apps.count == 3 { break }
        }
        return apps
    }

    func element(at point: CGPoint, in app: pid_t) -> AXUIElement? {
        guard !mute.contains(app), ContinuousClock.now < deadline, let application = application(app) else { return nil }
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &element)
        if error == .cannotComplete { mute.insert(app) }
        guard error == .success, let element else { return nil }
        AXUIElementSetMessagingTimeout(element, Self.timeout)
        return element
    }

    /// A password field, or what can't be asked about in time (taken as one: nothing of it is read).
    func isSecure(_ element: AXUIElement) -> Bool {
        guard let values = attributes([kAXRoleAttribute, kAXSubroleAttribute], of: element) else { return true }
        return values.contains { ($0 as? String) == kAXSecureTextFieldSubrole }
    }

    func line(of element: AXUIElement, at point: CGPoint) -> (start: Int, text: String, bounds: CGRect?)? {
        var point = point
        guard let position = AXValueCreate(.cgPoint, &point),
              let at = range(parameterized(kAXRangeForPositionParameterizedAttribute, position, of: element))
        else { return nil }
        var line: CFRange
        if let number = parameterized(kAXLineForIndexParameterizedAttribute, NSNumber(value: at.location), of: element) as? Int,
           let found = range(parameterized(kAXRangeForLineParameterizedAttribute, NSNumber(value: number), of: element)) {
            line = found
        } else {
            // No lines to ask for: the characters around the point.
            let count = (attribute(kAXNumberOfCharactersAttribute, of: element) as? Int) ?? (at.location + 200)
            let start = max(0, at.location - 200)
            line = CFRange(location: start, length: max(0, min(count, at.location + 200) - start))
        }
        guard line.length > 0, line.length <= Self.longest, let wanted = AXValueCreate(.cfRange, &line),
              let text = parameterized(kAXStringForRangeParameterizedAttribute, wanted, of: element) as? String
        else { return nil }
        return (line.location, text, rect(parameterized(kAXBoundsForRangeParameterizedAttribute, wanted, of: element)))
    }

    func frame(of element: AXUIElement) -> CGRect? {
        guard let values = attributes([kAXPositionAttribute, kAXSizeAttribute], of: element) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard let first = axValue(values[0]), AXValueGetValue(first, .cgPoint, &origin),
              let second = axValue(values[1]), AXValueGetValue(second, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    func text(of element: AXUIElement) -> String? {
        if let count = attribute(kAXNumberOfCharactersAttribute, of: element) as? Int, count > Self.longest { return nil }
        if let value = attribute(kAXValueAttribute, of: element) as? String, !value.isEmpty, value.count <= Self.longest { return value }
        if let title = string(kAXTitleAttribute, of: element), !title.isEmpty { return title }
        return nil
    }

    func name(of app: pid_t) -> String {
        NSRunningApplication(processIdentifier: app)?.localizedName ?? ""
    }

    private func application(_ pid: pid_t) -> AXUIElement? {
        if let known = applications[pid] { return known }
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            mute.insert(pid)
            return nil
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, Self.timeout)
        applications[pid] = application
        return application
    }

    private func attribute(_ name: String, of element: AXUIElement) -> AnyObject? {
        guard asking(element) else { return nil }
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        heard(error, from: element)
        return error == .success ? value : nil
    }

    /// Several attributes in one question; nil when it can't be asked or wasn't answered.
    private func attributes(_ names: [String], of element: AXUIElement) -> [AnyObject]? {
        guard asking(element) else { return nil }
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values)
        heard(error, from: element)
        guard error == .success, let values = values as? [AnyObject], values.count == names.count else { return nil }
        return values
    }

    /// Whether there is time left to ask an element's app, and the app still answers.
    private func asking(_ element: AXUIElement) -> Bool {
        guard ContinuousClock.now < deadline else { return false }
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) != .success || !mute.contains(pid)
    }

    /// An app that didn't answer in time isn't asked again.
    private func heard(_ error: AXError, from element: AXUIElement) {
        guard error == .cannotComplete else { return }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success { mute.insert(pid) }
    }

    private func string(_ name: String, of element: AXUIElement) -> String? {
        attribute(name, of: element) as? String
    }

    private func parameterized(_ name: String, _ parameter: AnyObject, of element: AXUIElement) -> AnyObject? {
        guard asking(element) else { return nil }
        var value: AnyObject?
        let error = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value)
        heard(error, from: element)
        return error == .success ? value : nil
    }

    private func range(_ value: AnyObject?) -> CFRange? {
        var range = CFRange()
        guard let value = axValue(value), AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    private func rect(_ value: AnyObject?) -> CGRect? {
        var rect = CGRect.zero
        guard let value = axValue(value), AXValueGetValue(value, .cgRect, &rect), rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    /// An attribute's value as an AXValue, when it is one (an error, for an element that can't say, is one too, of
    /// another type).
    private func axValue(_ value: AnyObject?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
