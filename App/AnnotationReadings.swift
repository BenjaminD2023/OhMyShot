import CoreGraphics
import Foundation
import OMSAnnotate
import OMSCore
import OMSOCR
import OSLog

/// A capture's text, read on this Mac for the annotation tools, one reading for both: the redaction tool's
/// suggestions, what reading finds better covered, and the lines of text the highlighter snaps to, where they lie,
/// never what they say. `AnnotationSession.readText` reads with `reading(of:)` from launch; scripted checks wrap it.
nonisolated enum AnnotationReadings {
    static func reading(of image: CGImage) -> CaptureReading {
        let recognition = TextRecognition(image)
        return CaptureReading(
            redactionSuggestions: {
                let probe = LatencyProbe("annotate.redactions")
                defer { probe.end() }
                do {
                    let found = try await SensitiveTextScanner().scan(recognition)
                    Log.app.notice("Redaction suggestions: \(found.count, privacy: .public) found")
                    return found.map { RedactionSuggestion(rect: $0.box, label: label(for: $0.kind)) }
                } catch {
                    logUnread("Redaction suggestions", error)
                    throw error
                }
            },
            textLines: {
                let probe = LatencyProbe("annotate.textlines")
                defer { probe.end() }
                do {
                    let lines = try await TextLineReader().read(recognition)
                    Log.app.notice("Text lines: \(lines.count, privacy: .public) found")
                    return lines.map { TextLine(rect: $0.box, words: $0.words) }
                } catch {
                    logUnread("Text lines", error)
                    throw error
                }
            }
        )
    }

    /// Notes a reading for the annotation tools that failed; one dropped because nobody waits for it is no
    /// failure.
    private static func logUnread(_ what: StaticString, _ error: any Error) {
        guard !(error is CancellationError) else { return }
        Log.app.error("\(String(describing: what), privacy: .public): the capture could not be read (\(String(describing: error), privacy: .public))")
    }

    /// What a redaction suggestion's kind is called in its tooltip.
    static func label(for kind: SensitiveText.Kind) -> String {
        switch kind {
        case .email: String(localized: "Email address")
        case .phone: String(localized: "Phone number")
        case .card: String(localized: "Card number")
        case .idNumber: String(localized: "ID number")
        case .secret: String(localized: "Key or token")
        case .ipAddress: String(localized: "IP address")
        case .password: String(localized: "Password")
        case .address: String(localized: "Address")
        case .name: String(localized: "Name")
        }
    }
}
