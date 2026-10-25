import Foundation
import Testing
@testable import OMSOCR

struct ProseLinearScanTests {
    /// The former rule, kept only as a bounded reference to verify the optimization preserves every
    /// punctuation/spacing decision, including skipped emoji, combining marks and non-Latin scripts.
    private func legacy(_ text: String) -> String {
        func square(_ character: Character) -> Bool { Script.isCJK(character) && !Script.isHangul(character) }
        var characters = Array(text)
        let hasCJK = characters.contains(where: Script.isCJK)
        let mostlyLatin = characters.filter(Script.isLatinOrDigit).count > characters.filter(Script.isCJK).count * 2
        func neighbor(_ index: Int, step: Int) -> Character? {
            var cursor = index + step
            while characters.indices.contains(cursor) {
                let character = characters[cursor]
                if character.isLetter || character.isNumber { return character }
                cursor += step
            }
            return nil
        }
        for index in characters.indices {
            let character = characters[index]
            let between = neighbor(index, step: -1).map(square) == true && neighbor(index, step: 1).map(square) == true
            if mostlyLatin {
                if let half = Punctuation.halfWidth[character], !between, !(character == "。" && hasCJK) { characters[index] = half }
            } else if let full = Punctuation.fullWidth[character], between { characters[index] = full }
        }
        var result: [Character] = []
        for (index, character) in characters.enumerated() {
            if character == " ", let last = result.last, square(last), index + 1 < characters.count, square(characters[index + 1]) { continue }
            result.append(character)
        }
        return String(result)
    }

    @Test func aLinearScanPreservesThePreviousMultilingualRules() {
        var state: UInt64 = 51
        let symbols = Array("Ab7甲乙あ한글éاא ,:!?（）[]。；：\t\n") + ["👩🏽‍💻", "e\u{301}"]
        let samples = ["", " , ! ", "甲 👩🏽‍💻, 乙", "abc：（甲，乙）", "한글, 글", "甲 3, 乙", "א, א", "é：甲"]
        for source in samples { #expect(TextAssembler.asProse(source) == legacy(source)) }
        for count in 0..<180 {
            var source = ""
            for _ in 0..<(count % 100) {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                source.append(symbols[Int(state % UInt64(symbols.count))])
            }
            #expect(TextAssembler.asProse(source) == legacy(source))
        }
    }

    @Test func longRunsOfPunctuationAndWhitespaceKeepTheirText() {
        let middle = String(repeating: ", ", count: 25_000)
        #expect(TextAssembler.asProse("甲" + middle + "乙") == "甲" + String(repeating: "， ", count: 25_000) + "乙")
        let blanks = String(repeating: " ", count: 50_000)
        #expect(TextAssembler.asProse(blanks) == blanks)
        #expect(TextAssembler.asProse("Hello" + middle + "world") == "Hello" + middle + "world")
    }
}
