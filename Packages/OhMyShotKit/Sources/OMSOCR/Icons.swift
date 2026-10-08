import CoreGraphics

/// Icons Vision reads as text: an app's symbol before a label (a calendar as 首, a link as @), a status
/// icon or an emoji after it (a muted bell as 4), an unread dot after it (●, 。). On real screenshots they
/// are the largest single source of errors in app interfaces.
///
/// An icon sits at an end of the line, about as wide as the line is tall, set apart by a gap far wider
/// than any inside the rest of the line; a dot is the same, only small. All of it must hold: a bullet or
/// dash ("- item") is too narrow to be an icon, spaced-out letters have gaps as wide as the one in
/// question, and text attached to its first character ("[27]", "#tag", "@name") has no gap at all. Only
/// the characters whose boxes lie over the icon go, only when they are one to three, and only when two
/// or more remain: a letter-spaced pair such as "确 定" looks like an icon and its label.
enum Icons {
    struct Trimmed: Equatable {
        /// The text without its icons.
        var text: Substring
        /// The horizontal span of what is left, in image x.
        var span: ClosedRange<CGFloat>
    }

    /// `text` without the icons at its ends, or nil when it has none. `glyph` gives the box of a range of
    /// the text in image coordinates, as Vision reports it.
    static func trimmed(
        _ text: Substring, ink: InkProfile, lineHeight: CGFloat, glyph: (Range<String.Index>) -> CGRect?
    ) -> Trimmed? {
        let runs = ink.runs.map { CGFloat($0.lowerBound)...CGFloat($0.upperBound) }
        guard runs.count >= 2, lineHeight > 0 else { return nil }
        let minimumGap = lineHeight * 0.4
        let iconWidth = (lineHeight * 0.5)...(lineHeight * 1.6)
        func gap(after index: Int) -> CGFloat { runs[index + 1].lowerBound - runs[index].upperBound }

        // The first gap wide enough to set something apart, within an icon's width of each end.
        var lead: Int?
        for index in 0..<(runs.count - 1) {
            guard runs[index].upperBound - runs[0].lowerBound <= iconWidth.upperBound else { break }
            if gap(after: index) >= minimumGap { lead = index; break }
        }
        var trail: Int?
        for index in stride(from: runs.count - 1, to: 0, by: -1) {
            guard runs[runs.count - 1].upperBound - runs[index].lowerBound <= iconWidth.upperBound else { break }
            if gap(after: index - 1) >= minimumGap { trail = index; break }
        }
        if let first = lead, let last = trail, last <= first + 1 {
            // One gap between two clusters: only the leading one can be the icon (a heart before "10").
            trail = nil
        }
        // The widest gap among the runs between the candidates, leaving out the blank half of full-width
        // punctuation, which is part of the mark ("，" is drawn at the left of its square).
        let marks = text.indices.filter { fullWidthMarks.contains(text[$0]) }.compactMap { glyph($0..<text.index(after: $0)) }
        let inner = (lead.map { $0 + 1 } ?? 0)..<(trail ?? runs.count)
        let innerGap = inner.dropLast()
            .filter { index in !marks.contains { $0.minX - 1 <= runs[index].upperBound && runs[index].upperBound <= $0.maxX + 1 } }
            .map { gap(after: $0) }.max() ?? 0

        var start = text.startIndex
        var end = text.endIndex
        var span = runs[0].lowerBound...runs[runs.count - 1].upperBound
        if let index = lead, gap(after: index) >= innerGap * 2,
           iconWidth.contains(runs[index].upperBound - runs[0].lowerBound),
           let cut = firstIndex(of: text, centeredAfter: runs[index].upperBound + gap(after: index) / 2, glyph: glyph),
           isIconReading(text[..<cut]), !attaching.contains(text[cut]),
           text[cut...].filter({ !$0.isWhitespace }).count >= 2 {
            start = cut
            span = runs[index + 1].lowerBound...span.upperBound
        }
        if let index = trail, gap(after: index - 1) >= innerGap * 2,
           let cut = firstIndex(of: text[start...], centeredAfter: runs[index].lowerBound - gap(after: index - 1) / 2, glyph: glyph),
           cut > start, gap(after: index - 1) >= minimumGap + blankHalf(before: cut, in: text[start...], glyph: glyph) {
            let removed = text[cut...].filter { !$0.isWhitespace }
            let width = runs[runs.count - 1].upperBound - runs[index].lowerBound
            let isIcon = iconWidth.contains(width) && isIconReading(text[cut...])
            let isDot = width < iconWidth.lowerBound && removed.count == 1 && removed.allSatisfy(dots.contains)
            if isIcon || isDot, text[start..<cut].filter({ !$0.isWhitespace }).count >= 2 {
                end = cut
                span = span.lowerBound...runs[index - 1].upperBound
            }
        }
        guard start != text.startIndex || end != text.endIndex else { return nil }
        while start < end, text[start].isWhitespace { start = text.index(after: start) }
        while end > start, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        guard start < end else { return nil }
        return Trimmed(text: text[start..<end], span: span)
    }

    /// What Vision makes of an icon: one character, or two or three symbols with one beyond ASCII ("〈\>").
    /// Not a word, however short: "let" before "options:" in monospaced code is a keyword, and the cell
    /// of space after it looks just like an icon's gap; nor "//" before a comment, nor "答：" before an
    /// answer.
    private static func isIconReading(_ text: Substring) -> Bool {
        let characters = text.filter { !$0.isWhitespace }
        // An ellipsis ends a truncated label; it is never an icon.
        if characters.allSatisfy({ $0 == "…" || $0 == "." }) { return false }
        if characters.count == 1 { return true }
        guard (2...3).contains(characters.count) else { return false }
        return characters.allSatisfy { !$0.isLetter && !$0.isNumber && !Script.isCJK($0) } && characters.contains { !$0.isASCII }
    }

    /// Marks that end the word before them: a gap after one is the mark's own blank half (a full-width
    /// colon is drawn at the left of its square), not an icon's distance.
    private static let attaching: Set<Character> = [
        "，", "。", "：", "；", "、", "！", "？", "）", "】", "」", "』", ",", ".", ":", ";", "!", "?", ")", "]", "/", "\\", "-", "_",
    ]

    /// Punctuation drawn in part of a square, the rest blank.
    private static let fullWidthMarks: Set<Character> = [
        "，", "。", "、", "：", "；", "！", "？", "…", "（", "）", "【", "】", "「", "」", "『", "』", "《", "》", "“", "”",
    ]

    /// The blank half of a full-width mark right before `index` ("，" before "…"), which is part of the
    /// gap that follows it and so does not set what comes after apart.
    private static func blankHalf(before index: String.Index, in text: Substring, glyph: (Range<String.Index>) -> CGRect?) -> CGFloat {
        guard let mark = text[..<index].lastIndex(where: { !$0.isWhitespace }), oneSidedMarks.contains(text[mark]),
              let box = glyph(mark..<text.index(after: mark)) else { return 0 }
        return box.width / 2
    }

    /// Full-width marks drawn at the left of their square, blank on the right. Not the ellipsis, whose dots
    /// span it.
    private static let oneSidedMarks: Set<Character> = ["，", "。", "、", "：", "；", "！", "？", "）", "】", "」", "』", "》", "”"]

    /// What an unread dot reads as.
    private static let dots: Set<Character> = ["●", "•", "·", "。", "o", "O", "°", "◦", "∙", "⋅"]

    /// The first non-blank character whose box is centered past `x`.
    private static func firstIndex(
        of text: Substring, centeredAfter x: CGFloat, glyph: (Range<String.Index>) -> CGRect?
    ) -> String.Index? {
        for index in text.indices where !text[index].isWhitespace {
            guard let box = glyph(index..<text.index(after: index)) else { return nil }
            if box.midX > x { return index }
        }
        return nil
    }
}
