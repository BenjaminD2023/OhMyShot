import CoreGraphics
import Foundation
import Testing
@testable import OMSOCR

/// Lines drawn as ink columns: each glyph a run of ink at a known x, 20 px tall.
struct IconsTests {
    /// A glyph of `text` at each span, in order; spaces take no span.
    private struct Line {
        let text: String
        let spans: [ClosedRange<Int>]

        var ink: InkProfile {
            let width = (spans.map(\.upperBound).max() ?? 0) + 1
            var columns = [Bool](repeating: false, count: width)
            for span in spans { for x in span { columns[x] = true } }
            return InkProfile(originX: 0, ink: columns)
        }

        func glyph(_ range: Range<String.Index>) -> CGRect? {
            let visible = text.indices.filter { !text[$0].isWhitespace }
            guard let position = visible.firstIndex(of: range.lowerBound) else {
                // A space sits between its neighbors.
                let before = visible.lastIndex { $0 < range.lowerBound } ?? 0
                let x = CGFloat(spans[before].upperBound + 1)
                return CGRect(x: x, y: 0, width: 1, height: 20)
            }
            let span = spans[position]
            return CGRect(x: CGFloat(span.lowerBound), y: 0, width: CGFloat(span.count), height: 20)
        }

        func trimmed() -> String? {
            Icons.trimmed(text[...], ink: ink, lineHeight: 20, glyph: glyph).map { String($0.text) }
        }
    }

    /// CJK glyphs 18 px wide, 2 px apart, from `x`.
    private func cjk(_ count: Int, from x: Int) -> [ClosedRange<Int>] {
        (0..<count).map { (x + $0 * 20)...(x + $0 * 20 + 17) }
    }

    @Test func aLeadingIconGoes() {
        let line = Line(text: "首近期活动", spans: [0...15] + cjk(4, from: 26))
        #expect(line.trimmed() == "近期活动")
    }

    @Test func aTrailingDotAndATrailingIconGo() {
        #expect(Line(text: "开发调优●", spans: cjk(4, from: 0) + [90...95]).trimmed() == "开发调优")
        #expect(Line(text: "您的服务已升级 4", spans: cjk(7, from: 0) + [180...195]).trimmed() == "您的服务已升级")
        #expect(Line(text: "图资源荟萃●", spans: [0...15] + cjk(4, from: 26) + [116...121]).trimmed() == "资源荟萃")
    }

    @Test func fullWidthPunctuationDoesNotHideATrailingIcon() {
        // "，" has its ink at the left of its square; the blank half is wider than the gaps between glyphs.
        let spans = cjk(2, from: 0) + [40...44] + cjk(3, from: 60) + [120...124] + [190...205]
        #expect(Line(text: "您好，您的服，4", spans: spans).trimmed() == "您好，您的服，")
    }

    @Test func anEllipsisAfterACommaStays() {
        // "，…": the comma's blank half is the gap before the ellipsis, and an ellipsis is text.
        let spans = cjk(3, from: 0) + [60...64] + [78...82, 86...90, 94...98]
        #expect(Line(text: "您的服，…", spans: spans).trimmed() == nil)
    }

    @Test func aHeartBeforeACountGoes() {
        #expect(Line(text: "♥ 10", spans: [0...15, 26...31, 34...40]).trimmed() == "10")
    }

    @Test func bulletsDashesAndAttachedMarksStay() {
        // A dash is too narrow to be an icon.
        #expect(Line(text: "- 已全额支付", spans: [0...5] + cjk(5, from: 16)).trimmed() == nil)
        // No gap after the first character.
        #expect(Line(text: "#gateevent", spans: (0..<10).map { ($0 * 9)...($0 * 9 + 7) }).trimmed() == nil)
        // A trailing dot is only a dot when it reads as one.
        #expect(Line(text: "Johor 7", spans: [0...8, 10...18, 20...28, 30...38, 40...48, 70...75]).trimmed() == nil)
    }

    @Test func aShortWordBeforeTheRestStays() {
        // Monospaced "let options:": a keyword and one cell of space, not an icon and its label.
        let spans = (0..<3).map { ($0 * 9)...($0 * 9 + 7) } + (0..<8).map { (36 + $0 * 9)...(36 + $0 * 9 + 7) }
        #expect(Line(text: "let options:", spans: spans).trimmed() == nil)
    }

    @Test func aLabelBeforeItsColonAndACommentMarkStay() {
        // "答：": the colon's ink sits at the left of its square, so a gap follows it.
        let answer = [0...17, 20...24] + cjk(6, from: 40)
        #expect(Line(text: "答：识别结果会按", spans: answer).trimmed() == nil)
        // "// 计算": two slashes, then a monospaced cell of space.
        let comment = [0...6, 9...15] + cjk(4, from: 28)
        #expect(Line(text: "// 计算缩略", spans: comment).trimmed() == nil)
    }

    @Test func spacedOutTextStays() {
        // Every gap as wide as the first: lettering, not an icon.
        #expect(Line(text: "设 置 中 心", spans: [0...17, 30...47, 60...77, 90...107]).trimmed() == nil)
        // One character left after the "icon": a letter-spaced pair.
        #expect(Line(text: "确 定", spans: [0...17, 30...47]).trimmed() == nil)
    }

    @Test func aTerminalColumnStays() {
        // "-I", one cell, an icon, one cell, ".git": the first gap is no wider than the one after the icon.
        let line = Line(text: "-I • .git", spans: [0...3, 6...8, 20...28, 40...41, 43...46, 48...49, 51...54])
        #expect(line.trimmed() == nil)
    }
}

struct LineNumbersTests {
    private func line(_ text: String, x: CGFloat, y: Int, width: CGFloat) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: CGFloat(y) * 30, width: width, height: 24), confidence: 1)
    }

    private let code = ["func thumbnail(for url: URL) -> CGImage? {", "    guard let source = make(url) else {", "        return nil", "    }", "}"]

    @Test func aGutterBesideCodeGoes() {
        let numbers = (0..<5).map { line("\(32 + $0)", x: 20, y: $0, width: 30) }
        let lines = code.enumerated().map { line($1, x: 100, y: $0, width: 500) }
        let kept = LineNumbers.removed(from: numbers + lines)
        #expect(kept.map(\.text) == code)
    }

    @Test func aMisreadNumberIsTolerated() {
        let values = ["39", "48", "41", "42", "43"]
        let numbers = values.enumerated().map { line($1, x: 20, y: $0, width: 30) }
        let lines = code.enumerated().map { line($1, x: 100, y: $0, width: 500) }
        #expect(LineNumbers.removed(from: numbers + lines).count == 5)
    }

    @Test func misreadNumbersInTheColumnGoWithIt() {
        let values = ["32", "33", "S5", "35", "LL9", "373839"]
        let numbers = values.enumerated().map { line($1, x: 20, y: $0, width: 30) }
        let lines = code.enumerated().map { line($1, x: 100, y: $0, width: 500) }
        #expect(LineNumbers.removed(from: numbers + lines).map(\.text) == code)
        #expect(LineNumbers.removed(from: numbers + lines).count == code.count)
    }

    @Test func aNumberedListKeepsItsNumbers() {
        let numbers = (1...4).map { line("\($0)", x: 20, y: $0, width: 12) }
        let items = ["Apples", "Oranges", "Pears", "Plums"].enumerated().map { line($1, x: 60, y: $0 + 1, width: 120) }
        #expect(LineNumbers.removed(from: numbers + items).count == 8)
    }
}
