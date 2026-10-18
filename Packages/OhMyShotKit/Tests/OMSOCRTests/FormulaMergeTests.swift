import CoreGraphics
import Foundation
import Testing
@testable import OMSOCR

/// Formulas among text: the layout model's tiles and detections (FormulaFinder), and the formulas put into Vision's
/// lines (FormulaMerge); with OMS_FORMULA_PACK=<an installed formula pack's folder, version 2>, the test pages end to end.
struct FormulaMergeTests {
    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat = 40, wraps: Bool? = nil) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: height), confidence: 1, wrapsToNextLine: wraps)
    }

    private func formula(_ latex: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ kind: FormulaFinder.Region.Kind = .inline) -> FormulaMerge.Formula {
        FormulaMerge.Formula(kind: kind, box: CGRect(x: x, y: y, width: width, height: height), latex: latex)
    }

    /// The plan's lines, with each piece given the text in `pieces` (by its left edge), in reading order.
    private func merged(_ lines: [OCRLine], _ formulas: [FormulaMerge.Formula], pieces: [CGFloat: String] = [:]) -> [String] {
        let plan = FormulaMerge.plan(lines, formulas: formulas)
        let texts = plan.pieces.map { pieces[$0.box.minX] ?? "?" }
        return ReadingOrder.sorted(FormulaMerge.lines(lines, formulas: formulas, plan: plan, pieces: texts)).map(\.text)
    }

    // MARK: Merging

    @Test func aDisplayFormulaTakesThePlaceOfTheLinesVisionMadeOfIt() {
        let lines = [
            line("The first one sets the scale of everything that follows:", 80, 150, 620),
            line("-6土 v62- 4ac", 190, 225, 200, 30),
            line("2a", 270, 265, 30, 28),
            line("and the second is read the same way:", 80, 350, 600),
        ]
        let display = formula(#"x={\frac{-b\pm{\sqrt{b^{2}-4a c}}}{2a}}"#, 130, 222, 270, 76, .display)
        let plan = FormulaMerge.plan(lines, formulas: [display])
        #expect(plan.pieces.isEmpty)
        #expect(plan.kept == [0, 3])
        #expect(merged(lines, [display]) == [
            "The first one sets the scale of everything that follows:",
            #"$$x={\frac{-b\pm{\sqrt{b^{2}-4a c}}}{2a}}$$"#,
            "and the second is read the same way:",
        ])
        let made = FormulaMerge.lines(lines, formulas: [display], plan: plan, pieces: [])
        #expect(made.last?.box == CGRect(x: 130, y: 222, width: 270, height: 76))
        #expect(made.last?.wrapsToNextLine == false)
        #expect(made.last?.math == .display)
        #expect(made.first?.math == nil)
    }

    @Test func anInlineFormulaGoesBetweenTheTextBesideItReadAgain() {
        let lines = [line("Given a loss L(0), each step moves the parameters, Ot+1 = Ot - nVL(Ot),", 96, 185, 1434, wraps: true)]
        let formulas = [formula(#"L(\theta)"#, 270, 185, 75, 44), formula(#"\theta_{t+1}=\theta_{t}-\eta\nabla L(\theta_{t})"#, 1179, 184, 336, 44)]
        let plan = FormulaMerge.plan(lines, formulas: formulas)
        #expect(plan.pieces.map(\.box.minX) == [96, 345, 1515])
        #expect(plan.pieces.map(\.formulaBefore) == [false, true, true])
        #expect(plan.pieces.map(\.formulaAfter) == [true, true, false])
        #expect(plan.latin)
        let text = merged(lines, formulas, pieces: [96: "Given a loss", 345: ", each step moves the parameters,", 1515: ","])
        #expect(text == [#"Given a loss $L(\theta)$, each step moves the parameters, $\theta_{t+1}=\theta_{t}-\eta\nabla L(\theta_{t})$,"#])
        let made = FormulaMerge.lines(lines, formulas: formulas, plan: plan, pieces: ["a", "b", "c"])
        #expect(made[0].wrapsToNextLine == true)
        #expect(made[0].math == .inline)
    }

    @Test func aPieceIsCutAtTheBlankColumnsNearestTheFormula() {
        // A line 40 tall, a formula from 100 to 200 whose ink runs to 203; the comma after it at 206–210, a space, then
        // words from 220. Before it, words to 92, then a space, then the formula's ink from 98 (its box cut it close).
        let lines = [line("words L(x), more words", 0, 100, 400)]
        let formulas = [formula(#"L(\theta)"#, 100, 100, 100, 40)]
        let plan = FormulaMerge.plan(lines, formulas: formulas)
        let inked: [Range<Int>] = [0..<92, 98..<203, 206..<211, 220..<400]
        let crops = FormulaMerge.crops(plan, lines: lines, formulas: formulas, size: CGSize(width: 400, height: 300)) { rect in
            let start = Int(rect.minX.rounded(.down))
            return InkProfile(originX: start, ink: (start..<Int(rect.maxX.rounded(.up))).map { x in inked.contains { $0.contains(x) } })
        }
        // To the formula: up to 2 blank columns past the last word. After it: from the gap before the comma.
        #expect(crops.map { $0?.minX } == [0, 204])
        #expect(crops.map { $0?.maxX } == [94, 400])
        // A quarter of the line's height above and below.
        #expect(crops.allSatisfy { $0?.minY == 90 && $0?.maxY == 150 })
    }

    @Test func aPieceStopsShortOfTheLinesAboveAndBelow() {
        // A line made tall by a fraction beside it, reaching into the line above.
        let lines = [line("the line above", 0, 0, 800, 44), line("text beside the fraction", 0, 40, 800, 63), line("below", 0, 110, 800, 40)]
        let formulas = [formula(#"\frac{1}{2}"#, 300, 40, 60, 63)]
        let plan = FormulaMerge.plan(lines, formulas: formulas)
        let crops = FormulaMerge.crops(plan, lines: lines, formulas: formulas, size: CGSize(width: 800, height: 400)) { _ in nil }
        #expect(crops.count == 2)
        #expect(crops.allSatisfy { $0?.minY == 44 && $0?.maxY == 110 })
    }

    @Test func punctuationTheFormulaEndsOnGoesAfterIt() {
        #expect(FormulaMerge.wrapped(formula("ax^{2}+bx+c=0:", 0, 0, 1, 1), display: false) == "$ax^{2}+bx+c=0$:")
        #expect(FormulaMerge.wrapped(formula(#"a\,b\,"#, 0, 0, 1, 1), display: false) == #"$a\,b\,$"#)
        #expect(FormulaMerge.wrapped(formula("x=1.", 0, 0, 1, 1, .display), display: true) == "$$x=1.$$")
        #expect(FormulaMerge.wrapped(formula("x=1", 0, 0, 1, 1, .display), display: false) == "$x=1$")
    }

    @Test func linesWithFormulasAreNeitherCodeNorJoinedToADisplayFormula() {
        let lines = [
            OCRLine(text: "The mean squared error is", box: CGRect(x: 0, y: 0, width: 600, height: 40), confidence: 1, wrapsToNextLine: true),
            OCRLine(text: #"$$\mathrm{MSE}=\frac{1}{n}\sum_{i}(y_{i}-\hat{y}_{i})^{2}$$"#, box: CGRect(x: 300, y: 60, width: 400, height: 100), confidence: 1, math: .display),
            OCRLine(text: #"and its gradient is $-\frac{2}{n}(y_{i}-\hat{y}_{i})$, which"#, box: CGRect(x: 0, y: 180, width: 900, height: 40), confidence: 1, wrapsToNextLine: true, math: .inline),
            OCRLine(text: "we use below.", box: CGRect(x: 0, y: 230, width: 300, height: 40), confidence: 1),
        ]
        #expect(!TextAssembler.isCodeListing(lines))
        #expect(TextAssembler.assemble(lines, options: .init(joinsWrappedLines: true)) == """
        The mean squared error is
        $$\\mathrm{MSE}=\\frac{1}{n}\\sum_{i}(y_{i}-\\hat{y}_{i})^{2}$$
        and its gradient is $-\\frac{2}{n}(y_{i}-\\hat{y}_{i})$, which we use below.
        """)
        // Translated, a formula set apart is left as it is; a sentence with one in it is prose, its LaTeX kept.
        let units = TranslationUnits.group(lines)
        #expect(units.map(\.skip) == [nil, .code, nil])
        #expect(units[2].text == #"and its gradient is $-\frac{2}{n}(y_{i}-\hat{y}_{i})$, which we use below."#)
        // A price is no formula.
        let price = OCRLine(text: "The ticket was $5 and the drink at the door was $3", box: CGRect(x: 0, y: 0, width: 400, height: 20), confidence: 1)
        #expect(TranslationUnits.group([price]).first?.skip == nil)
        // The LaTeX is left as it is, the text around it as prose: "：" between two Chinese characters stays full width.
        #expect(TextAssembler.withMath(#"由此可得：$c=\sqrt{a^{2}+b^{2}}$ 。"#) == #"由此可得：$c=\sqrt{a^{2}+b^{2}}$ 。"#)
        #expect(TextAssembler.withMath(#"取 $\text{速 度},x$ 时"#) == #"取 $\text{速 度},x$ 时"#)
    }

    @Test func linesVisionSplitAtAFormulaBecomeOne() {
        let lines = [line("When the discriminant", 96, 270, 320), line("is negative.", 660, 272, 160)]
        let formulas = [formula(#"\Delta=b^{2}-4ac"#, 420, 268, 226, 44)]
        #expect(merged(lines, formulas, pieces: [96: "When the discriminant", 660: "is negative."]) == [
            #"When the discriminant $\Delta=b^{2}-4ac$ is negative."#,
        ])
    }

    @Test func chineseTextKeepsItsPunctuationAgainstAFormula() {
        let lines = [line("斜边为c，则有a2+b2=c2。", 100, 160, 900)]
        let formulas = [formula("a^{2}+b^{2}=c^{2}", 500, 160, 200, 42)]
        #expect(merged(lines, formulas, pieces: [100: "斜边为c，则有", 700: "。"]) == ["斜边为c，则有 $a^{2}+b^{2}=c^{2}$。"])
    }

    @Test func aReadingWithNothingOfAFormulaInItLeavesTheText() {
        let lines = [line("version 2.0, 3.5 GB, (1)", 96, 230, 500)]
        let formulas = [formula("2.0", 250, 230, 40, 40), formula(#"3.5\mathrm{GB}"#, 320, 230, 90, 40), formula("(1)", 540, 230, 30, 40)]
        #expect(!FormulaMerge.plan(lines, formulas: formulas).changes)
    }

    @Test func aPieceTakesTheLinesOwnText() {
        // Read alone, "由此" came back as "田此", and a comma lost its space; the line read whole had both right.
        #expect(FormulaMerge.aligned("。田此可得斜边长度", in: "则有α2+62=C。由此可得斜边长度 C= Va2+62", from: 0)?.text == "。由此可得斜边长度")
        #expect(FormulaMerge.aligned(",each step moves", in: "Given a loss L(0), each step moves the", from: 0)?.text == ", each step moves")
        // From where the last piece ended, and exactly for a character or two.
        let line = "a, b = 1, c"
        let first = FormulaMerge.aligned(",", in: line, from: 0)
        #expect(first?.text == "," && first?.end == 2)
        #expect(FormulaMerge.aligned(",", in: line, from: 2)?.end == 9)
        #expect(FormulaMerge.aligned("x", in: line, from: 0) == nil)
        // Nothing that close: the piece's own reading stands.
        #expect(FormulaMerge.aligned("completely different words", in: "Given a loss L(0), each step", from: 0) == nil)
        // The line's reading ran the formula into the period after it; the piece read alone has it.
        #expect(FormulaMerge.withEnds(of: ". Version 2.0 of the library", on: "Version 2.0 of the library") == ". Version 2.0 of the library")
        #expect(FormulaMerge.withEnds(of: "is negative,", on: "is negative") == "is negative,")
        #expect(FormulaMerge.withEnds(of: ", each step", on: ", each step") == ", each step")
        // A comma read full width is the same comma.
        #expect(FormulaMerge.withEnds(of: "，each step，", on: ", each step,") == ", each step,")
    }

    @Test func aFormulasGarbleDoesNotMakeALineChinese() {
        let lines = [line("For a quadratic L（z）=臺a「Ax the iteration converges", 78, 230, 1434, 63)]
        #expect(FormulaMerge.plan(lines, formulas: [formula(#"L(x)=\frac{1}{2}x^{\top}Ax"#, 817, 230, 249, 53)]).latin)
        let chinese = [line("由此可得斜边长度 C= Va2+62", 78, 230, 1434, 63)]
        #expect(!FormulaMerge.plan(chinese, formulas: [formula(#"c=\sqrt{a^{2}+b^{2}}"#, 817, 230, 249, 53)]).latin)
    }

    @Test func aLineEndingOnAFormulaKeepsItsPeriod() {
        let lines = [line("so n < 2/入max（A）.", 78, 290, 263, 42)]
        let formulas = [formula(#"\eta<2/\lambda_{\max}(A)"#, 74, 285, 263, 47)]
        #expect(merged(lines, formulas) == [#"$\eta<2/\lambda_{\max}(A)$."#])
    }

    @Test func aFormulaWithNoTextBesideItIsALineOfItsOwn() {
        let lines = [line("Notes", 80, 40, 120)]
        let display = formula(#"e^{i\pi}+1=0"#, 400, 300, 200, 60, .display)
        let inline = formula(#"x^{2}"#, 400, 500, 40, 40)
        #expect(merged(lines, [display, inline]) == ["Notes", #"$$e^{i\pi}+1=0$$"#, #"$x^{2}$"#])
    }

    @Test func aFormulaFarAlongTheRowOrOnTheNextLineStaysApart() {
        // Another column on the same row, and the line above a display formula reaching a few pixels into it.
        let lines = [line("left column", 0, 100, 300), line("above it", 400, 160, 300)]
        let display = formula(#"\sum_{i}x_{i}"#, 400, 195, 200, 80, .display)
        let plan = FormulaMerge.plan(lines, formulas: [formula(#"y^{2}"#, 800, 100, 60, 40), display])
        #expect(plan.kept == [0, 1])
        #expect(plan.pieces.isEmpty)
    }

    @Test func verticalLinesAreLeftAlone() {
        var vertical = line("竖排文字", 100, 100, 40, 300)
        vertical.direction = .topToBottom
        #expect(FormulaMerge.plan([vertical], formulas: [formula(#"\alpha^{2}"#, 100, 150, 40, 40)]).kept == [0])
    }

    @Test func plainLaTeXIsWordsAndNumbers() {
        #expect(FormulaMerge.isPlain("2.0"))
        #expect(FormulaMerge.isPlain(#"\mathrm{May}\ 3,2026"#))
        #expect(FormulaMerge.isPlain(#"3.5\,\mathrm{GB}"#))
        #expect(FormulaMerge.isPlain("(1)"))
        // A letter in italic is a variable.
        #expect(!FormulaMerge.isPlain("n"))
        #expect(!FormulaMerge.isPlain("L(x)"))
        #expect(!FormulaMerge.isPlain("a+b"))
        #expect(!FormulaMerge.isPlain("x^{2}"))
        #expect(!FormulaMerge.isPlain(#"\alpha"#))
        #expect(!FormulaMerge.isPlain("a=1"))
        #expect(!FormulaMerge.isPlain(" "))
    }

    @Test func partsAreJoinedAsProseJoinsThem() {
        #expect(FormulaMerge.joined([("where", false), ("$x$", true), ("is", false)]) == "where $x$ is")
        #expect(FormulaMerge.joined([("(", false), ("$x$", true), (").", false)]) == "($x$).")
        #expect(FormulaMerge.joined([("取", false), ("$\\theta=\\pi$", true), ("时", false)]) == "取 $\\theta=\\pi$ 时")
        #expect(FormulaMerge.joined([("中文", false), ("文字", false)]) == "中文文字")
        #expect(FormulaMerge.joined([("斜边为", false), ("$c$,", true), ("则有", false)]) == "斜边为 $c$，则有")
        #expect(FormulaMerge.joined([("for", false), ("$c$,", true), ("then", false)]) == "for $c$, then")
        #expect(FormulaMerge.joined([("斜边为", false), ("$c$,", true), ("，则有", false)]) == "斜边为 $c$，则有")
        #expect(FormulaMerge.joined([("a", false), ("", false), ("b", false)]) == "a b")
    }

    @Test func uncoveredSpansAreWhatTheFormulasLeave() {
        #expect(FormulaMerge.uncovered(0..<100, by: [20..<30, 25..<40, 90..<120]) == [0..<20, 40..<90])
        #expect(FormulaMerge.uncovered(0..<100, by: [-10..<110]) == [])
        #expect(FormulaMerge.uncovered(0..<100, by: []) == [0..<100])
    }

    // MARK: Finding

    @Test func aScreenSizedPictureIsOneTileAndALargeOneSeveral() {
        #expect(FormulaFinder.tiles(width: 1400, height: 900) == [.init(area: CGRect(x: 0, y: 0, width: 1400, height: 900), canvas: CGSize(width: 1400, height: 900))])
        let screen = FormulaFinder.tiles(width: 3024, height: 1964)
        #expect(screen.count == 4)
        #expect(screen.allSatisfy { $0.area.width <= 1800 && $0.area.height <= 1800 })
        #expect(screen.map(\.area).reduce(CGRect.null) { $0.union($1) } == CGRect(x: 0, y: 0, width: 3024, height: 1964))
        // Neighbors reach into each other.
        #expect(screen[0].area.maxX - screen[1].area.minX >= 200)
        // A strip is padded nearer a page's shape.
        let strip = FormulaFinder.tiles(width: 2633, height: 67)
        #expect(strip.count == 2)
        #expect(strip.allSatisfy { $0.canvas.height == ($0.area.width / 2).rounded(.up) && $0.canvas.width == $0.area.width })
        let tall = FormulaFinder.tiles(width: 514, height: 2016)
        #expect(tall.count == 2 && tall[0].canvas.width == (tall[0].area.height / 2).rounded(.up))
    }

    @Test func detectionsAreFormulasFromTheThresholdUp() {
        let layout = FormulaConfiguration.Layout(
            file: "layout.mlpackage", input: "pixel_values", size: 800, logits: "logits", boxes: "boxes",
            classes: ["display": 5, "inline": 15], threshold: 0.5
        )
        // Three queries of 25 classes: a display formula (logit 3), an inline one just under the threshold, text.
        var logits = [Float](repeating: -9, count: 3 * 25)
        logits[0 * 25 + 5] = 3
        logits[1 * 25 + 15] = -0.1
        logits[2 * 25 + 22] = 5
        let boxes: [Float] = [0.5, 0.25, 0.5, 0.125, 0.25, 0.25, 0.125, 0.125, 0.5, 0.5, 1, 1]
        let tile = FormulaFinder.Tile(area: CGRect(x: 100, y: 0, width: 1000, height: 500), canvas: CGSize(width: 1000, height: 500))
        let found = FormulaFinder.regions(logits: logits, boxes: boxes, classes: 25, layout: layout, in: tile)
        #expect(found.count == 1)
        #expect(found.first?.kind == .display)
        #expect(found.first?.box == CGRect(x: 350, y: 93.75, width: 500, height: 62.5))
        // On a padded canvas, a box reaching past the tile is kept within it.
        let padded = FormulaFinder.Tile(area: CGRect(x: 0, y: 0, width: 1000, height: 100), canvas: CGSize(width: 1000, height: 500))
        let cut = FormulaFinder.regions(logits: logits, boxes: [0.5, 0.125, 0.25, 0.25] + boxes.dropFirst(4), classes: 25, layout: layout, in: padded)
        #expect(cut.first?.box == CGRect(x: 375, y: 0, width: 250, height: 100))
    }

    @Test func eachFormulaIsFoundOnce() {
        let display = FormulaFinder.Region(kind: .display, box: CGRect(x: 0, y: 0, width: 400, height: 80), score: 0.9)
        let sameAsInline = FormulaFinder.Region(kind: .inline, box: CGRect(x: 2, y: 1, width: 398, height: 80), score: 0.6)
        let inside = FormulaFinder.Region(kind: .inline, box: CGRect(x: 100, y: 10, width: 100, height: 40), score: 0.95)
        let cutByATile = FormulaFinder.Region(kind: .inline, box: CGRect(x: 500, y: 0, width: 60, height: 40), score: 0.99)
        let whole = FormulaFinder.Region(kind: .inline, box: CGRect(x: 500, y: 0, width: 120, height: 40), score: 0.8)
        let elsewhere = FormulaFinder.Region(kind: .inline, box: CGRect(x: 0, y: 300, width: 50, height: 40), score: 0.7)
        let merged = FormulaFinder.merged([display, sameAsInline, inside, cutByATile, whole, elsewhere])
        #expect(merged.map(\.box) == [
            CGRect(x: 500, y: 0, width: 120, height: 40), CGRect(x: 0, y: 0, width: 400, height: 81), CGRect(x: 0, y: 300, width: 50, height: 40),
        ])
        #expect(merged.map(\.kind) == [.inline, .display, .inline])
    }

    // MARK: End to end, with a pack

    static let environment = ProcessInfo.processInfo.environment

    /// The test pages (Tools/model-packs/layout_pages.py): their formulas found, read, and put into Vision's lines.
    @Test(.enabled(if: environment["OMS_FORMULA_PACK"] != nil))
    func thePagesReadWithTheirFormulas() async throws {
        let folder = URL(filePath: Self.environment["OMS_FORMULA_PACK"]!, directoryHint: .isDirectory)
        let reader = try await FormulaReader.load(from: folder)
        let finder = try await FormulaFinder.load(from: folder)
        let pipeline = VisionPipeline(options: .preferred(["en-US", "zh-Hans"]))
        let expected: [String: [String]] = [
            "page-web": [#"Given a loss $L(\theta)$, each step"#, #"$$\mathrm{M S E}="#, #"prediction $\hat{y}_{i}$ is"#, "Version 2.0 of the library"],
            "page-dark": [#"$ax^{2}+bx+c=0$"#, #"$$x="#, #"discriminant $\Delta=b^{2}-4ac$ is negative"#],
            "page-zh": [#"斜边为 $c$，则有 $a^{2}+b^{2}=c^{2}$。由此"#, #"$$e^{i\theta}="#, #"取 $\theta=\pi$ 时得到 $e^{i\pi}+1=0$，被称为最美的数学公式"#],
        ]
        for (name, wanted) in expected.sorted(by: { $0.key < $1.key }) {
            let url = try #require(Bundle.module.url(forResource: "Resources/Formulas/\(name)", withExtension: "png"))
            let image = try PictureText.image(at: url)
            let started = ContinuousClock.now
            let formulas = try await reader.formulas(in: image, finder: finder)
            let read = ContinuousClock.now
            let lines = try await pipeline.recognize(image).lines
            let merged = await pipeline.lines(lines, with: formulas, in: image)
            let text = TextAssembler.assemble(merged, options: .init())
            print("\(name): \(formulas.count) formulas read in \(read - started), merged in \(ContinuousClock.now - read)\n\(text)\n")
            for piece in wanted {
                #expect(text.contains(piece), "\(name): \(piece)")
            }
        }
    }
}
