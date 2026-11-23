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

    @Test func aFullWidthEllipsisStays() {
        // The Chinese model reads "..." full-width.
        let spans = cjk(3, from: 0) + [78...82, 86...90, 94...98]
        #expect(Line(text: "您的服．．．", spans: spans).trimmed() == nil)
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
        // The Chinese model reads the second slash full-width.
        #expect(Line(text: "/／ 计算缩略", spans: comment).trimmed() == nil)
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
        let kept = LineNumbers.removed(from: numbers + lines).lines
        #expect(kept.map(\.text) == code)
    }

    @Test func aMisreadNumberIsTolerated() {
        let values = ["39", "48", "41", "42", "43"]
        let numbers = values.enumerated().map { line($1, x: 20, y: $0, width: 30) }
        let lines = code.enumerated().map { line($1, x: 100, y: $0, width: 500) }
        #expect(LineNumbers.removed(from: numbers + lines).lines.count == 5)
    }

    @Test func misreadNumbersInTheColumnGoWithIt() {
        let values = ["32", "33", "S5", "35", "LL9", "373839"]
        let numbers = values.enumerated().map { line($1, x: 20, y: $0, width: 30) }
        let lines = code.enumerated().map { line($1, x: 100, y: $0, width: 500) }
        #expect(LineNumbers.removed(from: numbers + lines).lines.map(\.text) == code)
        #expect(LineNumbers.removed(from: numbers + lines).lines.count == code.count)
    }

    @Test func aNumberedListKeepsItsNumbers() {
        let numbers = (1...4).map { line("\($0)", x: 20, y: $0, width: 12) }
        let items = ["Apples", "Oranges", "Pears", "Plums"].enumerated().map { line($1, x: 60, y: $0 + 1, width: 120) }
        #expect(LineNumbers.removed(from: numbers + items).lines.count == 8)
    }

    /// Beside a narrow gutter, as Vim's `number` draws it (one space after the numbers), Vision reads a number and the
    /// code after it as one line. 10 px a character: the numbers end at 50, the code starts at 60.
    @Test func numbersReadWithTheirCodeGo() {
        let lines = [
            line("32 func thumbnail(for url: URL) -> CGImage? {", x: 30, y: 0, width: 450),
            line("33", x: 30, y: 1, width: 20),
            line("guard let source = make(url) else {", x: 100, y: 1, width: 350),
            line("34", x: 30, y: 2, width: 20),
            line("return nil", x: 140, y: 2, width: 100),
            line("35 }", x: 30, y: 3, width: 40),
        ]
        let removed = LineNumbers.removed(from: lines)
        #expect(removed.lines.map(\.text) == ["func thumbnail(for url: URL) -> CGImage? {", "guard let source = make(url) else {", "return nil", "}"])
        #expect(removed.lines.map(\.box.minX) == [60, 100, 140, 60])
        #expect(removed.end == 50)
    }

    /// Where the picture's ink is known, the code read with a number starts at its first glyph: Vision's one space
    /// stands for the indentation too.
    @Test func inkPlacesTheCodeReadWithANumber() {
        let text = "guard let source = make(url) else {"
        let lines = [
            line("32", x: 30, y: 0, width: 20),
            line("func thumbnail(for url: URL) -> CGImage? {", x: 60, y: 0, width: 420),
            line("33 " + text, x: 30, y: 1, width: 420),
            line("34", x: 30, y: 2, width: 20),
            line("return nil", x: 140, y: 2, width: 100),
        ]
        // Digits at 31–39 and 41–49, the code's glyphs from 101, 10 px apart.
        let ink = { (box: CGRect) -> InkProfile? in
            let columns = (Int(box.minX)..<Int(box.maxX)).map { x in
                x < 50 ? (x - 31) % 10 < 8 && x >= 31 : x >= 101 && (x - 101) % 10 < 8
            }
            return InkProfile(originX: Int(box.minX), ink: columns)
        }
        let removed = LineNumbers.removed(from: lines, ink: ink).lines
        #expect(removed.map(\.text) == ["func thumbnail(for url: URL) -> CGImage? {", text, "return nil"])
        #expect(removed[1].box.minX == 101)
        #expect(removed[1].box.maxX == 450)
    }

    /// Inside the column, a number read with a closing brace and no space, and a misread number before a space.
    @Test func whatALineStartsWithInsideTheColumnGoes() {
        let lines = [
            line("1", x: 40, y: 0, width: 10),
            line("func f() {", x: 60, y: 0, width: 100),
            line("З import os", x: 40, y: 1, width: 110),
            line("3", x: 40, y: 2, width: 10),
            line("x = g(1)", x: 100, y: 2, width: 80),
            line("4", x: 40, y: 3, width: 10),
            line("return x", x: 100, y: 3, width: 80),
            line("5}", x: 40, y: 4, width: 30),
        ]
        let removed = LineNumbers.removed(from: lines).lines
        #expect(removed.map(\.text) == ["func f() {", "import os", "x = g(1)", "return x", "}"])
        #expect(removed[1].box.minX == 60)
    }

    @Test func aSnippetOfTwoLinesLosesItsNumbers() {
        let numbers = ["41", "42"].enumerated().map { line($1, x: 20, y: $0, width: 30) }
        let snippet = ["let total = items.reduce(0) { $0 + $1.price }", "print(total)"]
        let lines = snippet.enumerated().map { line($1, x: 100, y: $0, width: 450) }
        #expect(LineNumbers.removed(from: numbers + lines).lines.map(\.text) == snippet)
        // Read with its numbers, its punctuation full-width as the Chinese model reads it.
        let fullWidth = ["1 let x ＝ 1", "2 let y ＝ 2"].enumerated().map { line($1, x: 20, y: $0, width: CGFloat($1.count * 10)) }
        #expect(LineNumbers.removed(from: fullWidth).lines.map(\.text) == ["let x ＝ 1", "let y ＝ 2"])
        // Two lines of YAML.
        for yaml in [["1 name: app", "2 port: 8080"], ["1 - name: app", "2 - name: worker"], ["1 Services:", "2 - app"]] {
            let lines = yaml.enumerated().map { line($1, x: 20, y: $0, width: CGFloat($1.count * 10)) }
            #expect(LineNumbers.removed(from: lines).lines.map(\.text) == yaml.map { String($0.dropFirst(2)) })
        }
    }

    @Test func twoNumbersThatDoNotFollowEachOtherStay() {
        let numbers = ["3", "7"].enumerated().map { line($1, x: 20, y: $0, width: 12) }
        let lines = ["let total = items.reduce(0) { $0 + $1.price }", "print(total)"].enumerated().map { line($1, x: 100, y: $0, width: 450) }
        #expect(LineNumbers.removed(from: numbers + lines).lines.count == 4)
    }

    /// Code whose lines start with numbers, and no gutter: the assignment starts left of the numbers' column, or
    /// in it above them, where no misread number is.
    @Test func codeStartingWithNumbersKeepsThem() {
        let operands = [line("1 + foo(),", x: 40, y: 1, width: 100), line("2 + bar()", x: 40, y: 2, width: 90)]
        let outdented = [line("nums = [", x: 0, y: 0, width: 80)] + operands
        #expect(LineNumbers.removed(from: outdented).lines == outdented)
        // Short enough to fit the column's width.
        let short = [line("a = [", x: 0, y: 0, width: 50)] + operands + [line("]", x: 0, y: 3, width: 10)]
        #expect(LineNumbers.removed(from: short).lines == short)
        let aligned = [line("nums = [", x: 40, y: 0, width: 80)] + operands
        #expect(LineNumbers.removed(from: aligned).lines == aligned)
        // At two indents and nothing else: the deeper numbers, on rows of their own, keep the shallower ones from a gutter.
        let nested = [("1 + foo(),", 40), ("2 + bar(),", 40), ("3 + baz() + sum([", 40), ("4 * tax,", 80), ("5 * fee,", 80), ("6 * price,", 80)]
            .enumerated().map { line($1.0, x: CGFloat($1.1), y: $0, width: CGFloat($1.0.count * 10)) }
        #expect(LineNumbers.removed(from: nested).lines == nested)
        // Between 99 and 101, a keyword as long as 101 is no misread number.
        let keyword = [("98 + foo();", 0), ("99 + bar();", 1), ("let x = 1;", 2), ("101 + baz();", 4), ("102 + qux();", 5)]
            .map { line($0.0, x: 40, y: $0.1, width: CGFloat($0.0.count * 10)) }
        #expect(LineNumbers.removed(from: keyword).lines == keyword)
    }

    /// A shell's `history`: its numbers count up beside commands, which are no code listing.
    @Test func aShellHistoryKeepsItsNumbers() {
        let lines = ["501 git status", "502 git pull --rebase", "503 open .", "504 swift build"].enumerated().map { line($1, x: 20, y: $0, width: 200) }
        #expect(LineNumbers.removed(from: lines).lines == lines)
    }
    /// A right-aligned gutter, 14 px a character: a wider number read with its closing brace starts left of the others.
    @Test func aWiderNumberReadWithItsBraceGoes() {
        let lines = [
            line("98", x: 40, y: 0, width: 28),
            line("if done {", x: 96, y: 0, width: 126),
            line("99", x: 40, y: 1, width: 28),
            line("return", x: 152, y: 1, width: 84),
            line("100}", x: 26, y: 2, width: 56),
        ]
        let removed = LineNumbers.removed(from: lines)
        #expect(removed.lines.map(\.text) == ["if done {", "return", "}"])
        #expect(removed.end == 68)
    }

    /// Short rows read with their numbers inside the column keep their code.
    @Test func aShortRowReadWithItsNumberKeepsItsCode() {
        let lines = [
            line("1", x: 40, y: 0, width: 10),
            line("let f = {", x: 60, y: 0, width: 90),
            line("2", x: 40, y: 1, width: 10),
            line("print(x)", x: 100, y: 1, width: 80),
            line("3};", x: 40, y: 2, width: 21),
            line("4", x: 40, y: 3, width: 10),
            line("if x {", x: 60, y: 3, width: 60),
            line("5}", x: 40, y: 4, width: 20),
        ]
        #expect(LineNumbers.removed(from: lines).lines.map(\.text) == ["let f = {", "print(x)", "};", "if x {", "}"])
    }

    /// A digit misread in a number read with its code (\"2O\" for 20) goes with the number.
    @Test func aMisreadDigitGoesWithItsNumber() {
        let lines = [
            line("18 import sys", x: 30, y: 0, width: 130),
            line("19", x: 30, y: 1, width: 20),
            line("2O import os", x: 30, y: 2, width: 120),
            line("21", x: 30, y: 3, width: 20),
            line("print(os.sep)", x: 60, y: 3, width: 130),
        ]
        #expect(LineNumbers.removed(from: lines).lines.map(\.text) == ["import sys", "import os", "print(os.sep)"])
        // Between 99 and 101, a misread 100 is as long as the number below it.
        let wider = [
            line("98", x: 40, y: 0, width: 20), line("def main():", x: 80, y: 0, width: 110),
            line("99", x: 40, y: 1, width: 20), line("import sys", x: 120, y: 1, width: 100),
            line("I00 import os", x: 30, y: 2, width: 130),
            line("101", x: 30, y: 3, width: 30), line("print(sys.argv)", x: 120, y: 3, width: 150),
            line("102", x: 30, y: 4, width: 30), line("return 0", x: 120, y: 4, width: 80),
        ]
        #expect(LineNumbers.removed(from: wider).lines.map(\.text) == ["def main():", "import sys", "import os", "print(sys.argv)", "return 0"])
    }

    /// A line a little left of the column is no number misread: its first word stays.
    @Test func aWordLeftOfTheColumnStays() {
        let lines = [
            line("1", x: 40, y: 0, width: 10),
            line("func f() {", x: 60, y: 0, width: 100),
            line("let x = 1", x: 35, y: 1, width: 90),
            line("2", x: 40, y: 2, width: 10),
            line("return x", x: 60, y: 2, width: 80),
            line("3", x: 40, y: 3, width: 10),
            line("}", x: 60, y: 3, width: 10),
        ]
        #expect(LineNumbers.removed(from: lines).lines == lines)
    }

    /// The code's own numbers, right of the gutter, are not part of it.
    @Test func numbersInTheCodeDoNotHideTheGutter() {
        let numbers = (1...6).map { line("\($0)", x: 40, y: $0 - 1, width: 10) }
        let code = [("def totals():", 60), ("return [", 100), ("3 * price,", 140), ("4 * tax,", 140), ("5 * fee,", 140), ("]", 100)]
        let lines = code.enumerated().map { line($1.0, x: CGFloat($1.1), y: $0, width: CGFloat($1.0.count * 10)) }
        #expect(LineNumbers.removed(from: numbers + lines).lines.map(\.text) == code.map(\.0))
    }

    /// Two numbered lines of prose, however much their first words look like code.
    @Test func twoNumberedLinesOfProseKeepTheirNumbers() {
        for first in ["1 for more information see the guide", "1 for more information: see the guide"] {
            let lines = [first, "2 return the form by Friday"].enumerated().map { line($1, x: 20, y: $0, width: CGFloat($1.count * 10)) }
            #expect(LineNumbers.removed(from: lines).lines == lines)
        }
    }

    /// A left-aligned gutter: the code is read again right of its widest number, not of the middle one.
    @Test func theGutterEndsAtItsWidestNumber() {
        let numbers = (7...11).map { line("\($0)", x: 30, y: $0 - 7, width: $0 < 10 ? 10 : 20) }
        let code = ["func f() {", "let a = 1", "let b = 2", "return a + b", "}"]
        let lines = code.enumerated().map { line($1, x: 60, y: $0, width: CGFloat($1.count * 10)) }
        let removed = LineNumbers.removed(from: numbers + lines)
        #expect(removed.lines.map(\.text) == code)
        #expect(removed.end == 50)
    }
}
