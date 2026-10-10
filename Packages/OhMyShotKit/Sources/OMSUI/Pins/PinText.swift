import AppKit

/// How a text pin is laid out: the face, and the card's size at 100 percent. The card is the Text
/// Result Card's: 12 pt corners (the pin setting), up to 420 pt wide, the text in label ink. The text is
/// laid out once, at 100 percent, and drawn scaled with the pin's zoom: the system face changes its
/// optical size as it grows, so text set at a larger size would break its lines anew.
enum PinText {
    static let maxWidth: CGFloat = 420
    static let minWidth: CGFloat = 64
    /// Inside the card, around the text.
    static let padding = CGSize(width: 14, height: 11)
    /// Lines shown before the rest is cut with an ellipsis; Copy still takes all of it.
    static let maxLines = 30
    /// The most of a long text the card ever lays out, so a pasted log never stalls it.
    static let maxCharacters = 4000

    /// The system face at 13 pt, or the monospaced one at 12 pt for code.
    static func font(for text: String) -> NSFont {
        isCodeLike(text)
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 13)
    }

    /// Code, read conservatively, since a false positive sets a sentence in a monospaced face: a fenced
    /// block, or two or more lines indented by a tab or at least two spaces.
    static func isCodeLike(_ text: String) -> Bool {
        let shown = displayed(text)
        if shown.contains("```") { return true }
        let indented = shown.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("\t") || $0.hasPrefix("  ") }
        return indented.count >= 2
    }

    /// What the card shows: no more than one line past the cap and `maxCharacters` characters, without
    /// trailing blank lines.
    static func displayed(_ text: String) -> String {
        var shown = String(text.prefix(maxCharacters))
        let lines = shown.split(separator: "\n", maxSplits: maxLines + 1, omittingEmptySubsequences: false)
        if lines.count > maxLines + 1 {
            shown = lines.prefix(maxLines + 1).joined(separator: "\n")
        }
        while let last = shown.last, last.isWhitespace { shown.removeLast() }
        return shown
    }

    /// The text as the card draws it, in label ink.
    static func attributed(_ text: String) -> NSAttributedString {
        let shown = displayed(text)
        return NSAttributedString(string: shown.isEmpty ? " " : shown, attributes: [
            .font: font(for: text),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    /// The text's own size at 100 percent: its width up to the card's, its height up to `maxLines` lines.
    static func textSize(for text: String) -> CGSize {
        let font = font(for: text)
        let inner = maxWidth - 2 * padding.width
        let measured = attributed(text).boundingRect(
            with: CGSize(width: inner, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return CGSize(
            width: min(max(ceil(measured.width), minWidth - 2 * padding.width), inner),
            height: min(ceil(measured.height), ceil(lineHeight * CGFloat(maxLines)))
        )
    }

    /// The card's size at 100 percent: the text and the padding around it.
    static func cardSize(for text: String) -> CGSize {
        let size = textSize(for: text)
        return CGSize(width: size.width + 2 * padding.width, height: size.height + 2 * padding.height)
    }

    /// What copying a selection of `range` in `shown`, the part of `full` the card lays out, takes: the
    /// selected text, or the whole text when all that the card holds is selected, so Select All and Copy
    /// still take what was cut. Nil with nothing selected.
    static func copied(selecting range: NSRange, in shown: String, of full: String) -> String? {
        let length = (shown as NSString).length
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        if range.location == 0, range.length >= length { return full }
        let kept = NSIntersectionRange(range, NSRange(location: 0, length: length))
        return kept.length > 0 ? (shown as NSString).substring(with: kept) : nil
    }
}
