import Foundation

/// The model's tokens back to text, as its tokenizer's decoder makes them (tokenizer.json: `▁` becomes a space, each
/// run of byte tokens `<0xHH>` is one UTF-8 string, or one U+FFFD a byte where the bytes aren't UTF-8, and the pieces
/// are joined as they are). The pack holds the tokens as a JSON array of strings by id (`vocabulary.json`, the
/// tokenizer's vocabulary and its added tokens), so the reader needs no tokenizer of its own: the prompts were
/// tokenized when the pack was made.
public struct PaddleOCRVLTokens: Sendable {
    enum Piece: Sendable {
        case text(String)
        case byte(UInt8)
    }

    let pieces: [Piece]

    public init(vocabulary: [String]) {
        pieces = vocabulary.map { token in
            let scalars = Array(token.utf8)
            if scalars.count == 6, token.hasPrefix("<0x"), token.hasSuffix(">"), let byte = UInt8(token.dropFirst(3).prefix(2), radix: 16) {
                return .byte(byte)
            }
            return .text(token.replacingOccurrences(of: "\u{2581}", with: " "))
        }
    }

    public init(contentsOf url: URL) throws {
        try self.init(vocabulary: JSONDecoder().decode([String].self, from: Data(contentsOf: url)))
    }

    public var count: Int { pieces.count }

    public func text(_ tokens: some Sequence<Int>) -> String {
        var result = ""
        var bytes: [UInt8] = []
        func flush() {
            guard !bytes.isEmpty else { return }
            if let string = String(validating: bytes, as: UTF8.self) {
                result += string
            } else {
                result += String(repeating: "\u{FFFD}", count: bytes.count)
            }
            bytes.removeAll()
        }
        for token in tokens where pieces.indices.contains(token) {
            switch pieces[token] {
            case .byte(let byte):
                bytes.append(byte)
            case .text(let text):
                flush()
                result += text
            }
        }
        flush()
        return result
    }
}
