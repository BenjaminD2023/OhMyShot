import Foundation

/// The writing systems the post-processing tells apart.
enum Script {
    /// Han, kana, or Hangul: text laid out on a square grid, without spaces between characters.
    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // Hiragana, Katakana
                 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF, // CJK Unified Ideographs
                 0xF900...0xFAFF, // CJK Compatibility Ideographs
                 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF, // Hangul
                 0x20000...0x2FA1F: // CJK Extensions B and later
                true
            default:
                false
            }
        }
    }

    static func isKana(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
    }

    static func isHangul(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    }

    /// A Latin letter or an ASCII digit.
    static func isLatinOrDigit(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber
    }

    static func containsCJK(_ text: some StringProtocol) -> Bool {
        text.contains(where: isCJK)
    }

    /// A line in Latin script alone: no CJK, every letter Latin (so Cyrillic or Greek is not taken for
    /// it), and at least two letters, which leaves out lines of figures such as "$0".
    static func isLatinLine(_ text: some StringProtocol) -> Bool {
        var letters = 0
        for character in text {
            if isCJK(character) { return false }
            guard character.isLetter else { continue }
            guard character.unicodeScalars.allSatisfy({ $0.value < 0x250 || (0x1E00...0x1EFF).contains($0.value) }) else { return false }
            letters += 1
        }
        return letters >= 2
    }
}

/// Full-width punctuation and its half-width twin.
enum Punctuation {
    static let halfWidth: [Character: Character] = [
        "，": ",", "。": ".", "：": ":", "；": ";", "！": "!", "？": "?", "（": "(", "）": ")",
        "［": "[", "］": "]", "｛": "{", "｝": "}", "＜": "<", "＞": ">", "＝": "=", "＋": "+",
        "－": "-", "＊": "*", "／": "/", "＼": "\\", "＂": "\"", "＇": "'", "＃": "#", "＠": "@",
        "＆": "&", "％": "%", "＄": "$", "｜": "|", "～": "~", "＿": "_", "＾": "^", "｀": "`",
    ]

    /// The punctuation Chinese and Japanese text writes full-width.
    static let fullWidth: [Character: Character] = [
        ",": "，", ".": "。", ":": "：", ";": "；", "!": "！", "?": "？", "(": "（", ")": "）",
    ]
}
