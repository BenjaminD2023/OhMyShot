import Foundation

/// Puts whole translated sentences one after another, as the language writes them.
///
/// A sentence that ends in a full-width mark (Chinese and Japanese: 。！？) is followed directly by the next; any other
/// is followed by a space. So the English "Saved. Nothing changed." and the Chinese "已保存。没有变化。" both read as
/// written, whichever language each sentence came in (a server's own message after a translated one, say). Each
/// sentence is translated whole: this never glues pieces of one sentence together.
public enum Sentences {
    public static func joined(_ sentences: [String]) -> String {
        var text = ""
        for sentence in sentences.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !sentence.isEmpty {
            if let last = text.last, !fullWidthEnds.contains(last) { text.append(" ") }
            text += sentence
        }
        return text
    }

    public static func joined(_ sentences: String?...) -> String {
        joined(sentences.compactMap(\.self))
    }

    /// The marks after which Chinese and Japanese start the next sentence without a space.
    private static let fullWidthEnds: Set<Character> = ["。", "！", "？", "：", "；", "」", "』", "）"]
}
