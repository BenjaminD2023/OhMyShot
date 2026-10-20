import AppKit
import SwiftUI

/// Settings › About › Acknowledgments…: OhMyShot's license and the notices of the software it is built with, which
/// their licenses ask to go with every copy. They're in App/Acknowledgments.md, made by Scripts/acknowledgments.py, and
/// stay in English, as they were written.
struct AcknowledgmentsSheet: View {
    let url: URL
    let done: () -> Void
    @State private var document: Result<NSAttributedString, Error>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Acknowledgments", bundle: .module)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Group {
                switch document {
                case nil:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .success(let text):
                    AcknowledgmentsText(text: text)
                case .failure(let error):
                    Text(verbatim: error.localizedDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 400)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            HStack {
                Spacer()
                Button(action: done) { Text("Done", bundle: .module) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .task {
            document = Result { try AcknowledgmentsDocument.attributed(String(contentsOf: url, encoding: .utf8)) }
        }
    }
}

/// The notices in a text view: a single SwiftUI text of 80 KB is slow to lay out and to select in, and this one
/// selects, copies, and finds as any Mac text does.
private struct AcknowledgmentsText: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 6, height: 10)
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.textStorage?.setAttributedString(text)
            textView.setAccessibilityLabel(String(localized: "Acknowledgments", bundle: .module))
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
}

/// The notices file as the sheet shows it. The file is the script's own simple Markdown: an HTML comment and a title
/// (left out, as the sheet has its own), `##` and `###` headings, each with an address or an italic line of where it
/// comes from, lines of text, and each license in a ```text block, shown verbatim in a monospaced face so that its
/// lines, lists, and indents stay as their authors wrote them. Web addresses are links.
enum AcknowledgmentsDocument {
    static func attributed(_ markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func append(_ text: String, font: NSFont, color: NSColor = .labelColor, before: CGFloat) {
            // Each line is a paragraph of its own (a license's lines too), so only the first is set apart.
            let first = NSMutableParagraphStyle()
            first.paragraphSpacingBefore = result.length == 0 ? 0 : before
            let piece = NSMutableAttributedString(
                string: (result.length == 0 ? "" : "\n") + text,
                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: NSParagraphStyle.default]
            )
            let firstLine = (piece.string as NSString).paragraphRange(for: NSRange(location: result.length == 0 ? 0 : 1, length: 0))
            piece.addAttribute(.paragraphStyle, value: first, range: firstLine)
            for match in links.matches(in: piece.string, range: NSRange(location: 0, length: (piece.string as NSString).length)) {
                if let url = URL(string: (piece.string as NSString).substring(with: match.range)) {
                    piece.addAttribute(.link, value: url, range: match.range)
                }
            }
            result.append(piece)
        }
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let license = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        var fence: [String]?
        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if fence != nil {
                if line == "```" {
                    append((fence ?? []).joined(separator: "\n"), font: license, before: 8)
                    fence = nil
                } else {
                    fence?.append(line)
                }
            } else if line.hasPrefix("```") {
                fence = []
            } else if line.isEmpty || line.hasPrefix("<!--") || line.hasPrefix("# ") {
                continue
            } else if line.hasPrefix("## ") {
                append(String(line.dropFirst(3)), font: .systemFont(ofSize: 15, weight: .semibold), before: 22)
            } else if line.hasPrefix("### ") {
                append(String(line.dropFirst(4)), font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), before: 16)
            } else if line.hasPrefix("https://") || (line.count > 2 && line.hasPrefix("*") && line.hasSuffix("*")) {
                // A package's address, or where a part of one comes from (in italics): under its heading, quieter.
                let text = line.hasPrefix("*") ? String(line.dropFirst().dropLast()) : line
                append(text, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, before: 2)
            } else {
                append(line, font: body, before: 8)
            }
        }
        return result
    }

    /// A web address, without the punctuation around one: "<http://…>:", "(https://…)".
    private static let links = try! NSRegularExpression(pattern: #"https?://[^\s<>"()]*[^\s<>"().,;:]"#)
}

#if DEBUG
public extension Notification.Name {
    /// Opens the Acknowledgments sheet in an About pane, as Acknowledgments… does.
    static let debugOpenAcknowledgments = Notification.Name("OhMyShotDebugOpenAcknowledgments")
}
#endif
