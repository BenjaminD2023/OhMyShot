#if DEBUG
import AppIntents
import AppKit
import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import ImageIO
import OMSAnnotate
import OMSCapture
import OMSCore
import OMSOCR
import OMSRecording
import OMSStudio
import OMSUI
import OSLog
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Endpoints for the annotation editor, and for the readings its tools wait on, slowed or failing when a hook asks.
extension DebugHooks {
    /// The real reader of a capture's text, while redact-slow or textlines-slow stands in for it.
    private static var unslowedReadText: (@Sendable (CGImage) -> CaptureReading)?
    /// How many seconds longer the redaction suggestions and the highlighter's lines take to read.
    private static var readingDelays = (redactions: 0, textLines: 0)
    /// How many of the next readings of each fail, as a reading the capture could not be made for does.
    private static var readingFailures = (redactions: 0, textLines: 0)

    /// Returns true when `hook` was one of these.
    func handleEditorHook(_ hook: String, _ url: URL) -> Bool {
        switch hook {
        case "editor-demo":
            // The annotation editor on the drawn page: marks=0 for none, spot=1 adds a spotlight,
            // tool=<tool>, select=<index>, edit=<index of a text mark>, zoom=actual; hidden=1 opens it
            // behind the wallpaper without making the app active, for editor-render; dark=1 turns the
            // page's shades over (white text on black).
            let value = { (name: String) in Self.parameter(name, in: url) }
            DebugEditorDemo.open(
                marks: value("marks") != "0",
                spot: value("spot") == "1",
                tool: value("tool").flatMap(AnnotationTool.init(rawValue:)),
                select: value("select").flatMap(Int.init),
                editText: value("edit").flatMap(Int.init),
                actualSize: value("zoom") == "actual",
                hidden: value("hidden") == "1",
                dark: value("dark") == "1"
            )
        case "editor-render":
            // The demo editor's window alone, through ScreenCaptureKit, as <name>.png: works behind the
            // wallpaper (editor-demo?hidden=1), so nothing shows.
            if let window = DebugEditorDemo.window {
                let name = Self.parameter("name", in: url) ?? "editor-render"
                Task { await captureHiddenWindow(window, name: name) }
            } else {
                Log.app.error("debug.editor-render: no demo editor")
            }
        case "editor-act":
            // Acts on the demo editor, or else on an editor opened from a card.
            DebugEditorDemo.act(on: annotations.openEditors.first) { Self.parameter($0, in: url) }
        case "redact-slow":
            // Reads for redaction suggestions take seconds= longer (0 puts them back), so the capsule's
            // finding state can be captured.
            Self.readingDelays.redactions = Self.intParameter("seconds", in: url) ?? 3
            Self.wrapReadings()
            Log.app.notice("debug.redact-slow \(Self.readingDelays.redactions, privacy: .public) s")
        case "textlines-slow":
            // Reads for the highlighter's lines of text take seconds= longer (0 puts them back), so the
            // capsule's finding state can be captured.
            Self.readingDelays.textLines = Self.intParameter("seconds", in: url) ?? 3
            Self.wrapReadings()
            Log.app.notice("debug.textlines-slow \(Self.readingDelays.textLines, privacy: .public) s")
        case "reading-fail":
            // The next times= readings for redaction suggestions and for the highlighter's lines fail (0
            // puts them back), so the capsule's "Couldn't read text" and Try Again can be captured.
            let times = Self.intParameter("times", in: url) ?? 1
            Self.readingFailures = (times, times)
            Self.wrapReadings()
            Log.app.notice("debug.reading-fail \(times, privacy: .public)")
        case "redact-scan":
            // Reads the drawn demo page for redaction suggestions and logs them; nothing is shown.
            if let image = DebugPanelDemo.image(), let read = AnnotationSession.readText {
                Task {
                    let found = ((try? await read(image).redactionSuggestions()) ?? []).map { "\($0.label)@\(NSStringFromRect($0.rect))" }
                    Log.app.notice("debug.redact-scan \(found.joined(separator: "; "), privacy: .public)")
                }
            }
        case "textlines-scan":
            // Reads the drawn demo page for the lines the highlighter snaps to and logs where they lie (each
            // line's rect and word count); nothing is shown.
            if let image = DebugPanelDemo.image(), let read = AnnotationSession.readText {
                Task {
                    let found = ((try? await read(image).textLines()) ?? []).map { "\(NSStringFromRect($0.rect))/\($0.words.count)" }
                    Log.app.notice("debug.textlines-scan \(found.count, privacy: .public): \(found.joined(separator: "; "), privacy: .public)")
                }
            }
        case "reading-scan":
            // Reads the drawn demo page for both tools from one reading, as an editor does when both are
            // used: the redaction suggestions, then the lines, each with its latency probe. The lines come
            // from the Chinese reading the suggestions made, so theirs is the fitting alone. Logs counts.
            if let image = DebugPanelDemo.image(), let read = AnnotationSession.readText {
                Task {
                    let reading = read(image)
                    let suggestions = (try? await reading.redactionSuggestions())?.count ?? -1
                    let lines = (try? await reading.textLines())?.count ?? -1
                    Log.app.notice("debug.reading-scan suggestions=\(suggestions, privacy: .public) lines=\(lines, privacy: .public)")
                }
            }
        default:
            return false
        }
        return true
    }

    /// Makes the tools' readings take `readingDelays` longer and fail `readingFailures` times, the real
    /// reading still under them, or puts the real one back when they are neither slowed nor failing.
    private static func wrapReadings() {
        if unslowedReadText == nil { unslowedReadText = AnnotationSession.readText }
        let original = unslowedReadText
        let delays = readingDelays
        guard delays != (0, 0) || readingFailures != (0, 0) else {
            AnnotationSession.readText = original
            return
        }
        AnnotationSession.readText = { @Sendable image in
            let reading = original?(image) ?? CaptureReading()
            return CaptureReading(
                redactionSuggestions: {
                    try? await Task.sleep(for: .seconds(delays.redactions))
                    if await takeFailure(redactions: true) { throw CocoaError(.fileReadUnknown) }
                    return try await reading.redactionSuggestions()
                },
                textLines: {
                    try? await Task.sleep(for: .seconds(delays.textLines))
                    if await takeFailure(redactions: false) { throw CocoaError(.fileReadUnknown) }
                    return try await reading.textLines()
                }
            )
        }
    }

    /// Whether this reading is one of the failures asked for, counting it.
    private static func takeFailure(redactions: Bool) -> Bool {
        if redactions {
            guard readingFailures.redactions > 0 else { return false }
            readingFailures.redactions -= 1
        } else {
            guard readingFailures.textLines > 0 else { return false }
            readingFailures.textLines -= 1
        }
        return true
    }
}
#endif
