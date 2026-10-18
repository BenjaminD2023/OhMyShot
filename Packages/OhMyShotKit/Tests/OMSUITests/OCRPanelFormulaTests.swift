import CoreGraphics
import Foundation
import OMSCore
@testable import OMSOCR
import Testing
@testable import OMSUI

/// The OCR panel's Formulas pane: what it offers, and how the formulas dragged around are read.
struct OCRPanelFormulaTests {
    /// Answers each reading in turn, when the test says so, and remembers the size of each part it was given.
    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<TextReaderTool.Formula?, Never>] = []
        private var _sizes: [CGSize] = []

        var sizes: [CGSize] { lock.withLock { _sizes } }
        var pending: Int { lock.withLock { waiting.count } }

        func read(_ image: CGImage) async -> TextReaderTool.Formula? {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    _sizes.append(CGSize(width: image.width, height: image.height))
                    waiting.append(continuation)
                }
            }
        }

        func answer(_ formula: TextReaderTool.Formula?) {
            let continuation = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
            continuation?.resume(returning: formula)
        }
    }

    private static func image(width: Int = 400, height: Int = 200) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static func model() -> TextRecognitionModel {
        let defaults = UserDefaults(suiteName: "OCRPanelFormulaTests-\(UUID().uuidString)")!
        return TextRecognitionModel(settings: SettingsStore(defaults: defaults), translator: Translator())
    }

    private static func analysis(_ lines: [OCRLine] = []) -> @Sendable (CGImage) async throws -> TextAnalysis {
        { _ in
            TextAnalysis(result: OCRResult(lines: lines, text: lines.map(\.text).joined(separator: "\n"), duration: .zero), tables: [], codes: [])
        }
    }

    /// Lets the model's tasks run until `condition` holds, or a second has gone by.
    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func formulasAreOfferedOnlyWithThePack() async {
        let without = Self.model()
        without.load(image: Self.image(), scale: 2, analyze: Self.analysis([OCRLine(text: "E = mc²", box: CGRect(x: 10, y: 10, width: 80, height: 20), confidence: 1)]))
        await Self.settle { without.phase == .ready }
        #expect(without.panes.isEmpty)

        let with = Self.model()
        let reader = Reader()
        with.load(image: Self.image(), scale: 2, analyze: Self.analysis([OCRLine(text: "E = mc²", box: CGRect(x: 10, y: 10, width: 80, height: 20), confidence: 1)]), readFormula: reader.read)
        await Self.settle { with.phase == .ready }
        #expect(with.panes == [.text, .formulas])
    }

    @Test func anImageWithNoTextStillOffersFormulas() async {
        let model = Self.model()
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis(), readFormula: Reader().read)
        await Self.settle { model.phase == .empty }
        #expect(model.panes == [.text, .formulas])
        model.pane = .formulas
        #expect(model.showsFormulas)
    }

    @Test func translatingHidesThePanes() async {
        let model = Self.model()
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis(), readFormula: Reader().read)
        await Self.settle { model.phase == .empty }
        model.pane = .formulas
        model.translates = true
        #expect(model.panes.isEmpty)
        #expect(!model.showsFormulas)
        model.translates = false
    }

    @Test func formulasAreReadOneAtATimeInTheOrderTheyWereDrawn() async {
        let model = Self.model()
        let reader = Reader()
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis(), readFormula: reader.read)
        model.pane = .formulas
        model.addFormula(CGRect(x: 10, y: 10, width: 100, height: 40))
        model.addFormula(CGRect(x: 200, y: 100, width: 60, height: 30))
        await Self.settle { reader.pending == 1 }
        // The second waits while the first is read: one reader run at a time.
        #expect(reader.sizes == [CGSize(width: 100, height: 40)])
        #expect(model.formulas.map(\.state) == [.reading, .reading])

        reader.answer(TextReaderTool.Formula(latex: #"\frac{a}{b}"#, ending: "end"))
        await Self.settle { reader.sizes.count == 2 && reader.pending == 1 }
        #expect(model.formulas.first?.state == .read(#"\frac{a}{b}"#))
        #expect(reader.sizes.last == CGSize(width: 60, height: 30))
        #expect(model.canCopy)

        reader.answer(TextReaderTool.Formula(latex: "x^{x^{x^{x", ending: "repeats"))
        await Self.settle { model.formulas.last?.state != .reading }
        #expect(model.formulas.last?.state == .notFound)
    }

    @Test func aBoxIsKeptWithinTheImageAndATinyOneIsLeftOut() async {
        let model = Self.model()
        let reader = Reader()
        model.load(image: Self.image(width: 400, height: 200), scale: 2, analyze: Self.analysis(), readFormula: reader.read)
        model.addFormula(CGRect(x: 380, y: 150, width: 100, height: 100))
        model.addFormula(CGRect(x: 10, y: 10, width: 3, height: 30))
        #expect(model.formulas.map(\.box) == [CGRect(x: 380, y: 150, width: 20, height: 50)])
        await Self.settle { reader.pending == 1 }
        #expect(reader.sizes == [CGSize(width: 20, height: 50)])
        reader.answer(nil)
        await Self.settle { model.formulas.first?.state != .reading }
        // A reading that failed is no formula.
        #expect(model.formulas.first?.state == .notFound)
        #expect(!model.canCopy)
    }

    @Test func aFormulaRemovedWhileItIsReadDropsItsAnswerAndTheNextIsRead() async {
        let model = Self.model()
        let reader = Reader()
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis(), readFormula: reader.read)
        model.addFormula(CGRect(x: 0, y: 0, width: 50, height: 50))
        model.addFormula(CGRect(x: 100, y: 0, width: 50, height: 50))
        await Self.settle { reader.pending == 1 }
        let first = model.formulas[0].id
        model.removeFormula(first)
        reader.answer(TextReaderTool.Formula(latex: "a", ending: "end"))
        await Self.settle { reader.sizes.count == 2 }
        #expect(model.formulas.count == 1 && model.formulas[0].state == .reading)
        reader.answer(TextReaderTool.Formula(latex: "b", ending: "end"))
        await Self.settle { model.formulas.first?.state != .reading }
        #expect(model.formulas.map(\.latex) == ["b"])
    }

    @Test func theWholeImageCanBeReadWithoutDragging() {
        let model = Self.model()
        model.load(image: Self.image(width: 300, height: 120), scale: 2, analyze: Self.analysis(), readFormula: Reader().read)
        model.readWholeImageAsFormula()
        #expect(model.formulas.map(\.box) == [CGRect(x: 0, y: 0, width: 300, height: 120)])
    }

    @Test func aNewImageStartsWithNoFormulas() async {
        let model = Self.model()
        let reader = Reader()
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis(), readFormula: reader.read)
        model.pane = .formulas
        model.addFormula(CGRect(x: 0, y: 0, width: 50, height: 50))
        await Self.settle { reader.pending == 1 }
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis(), readFormula: reader.read)
        #expect(model.formulas.isEmpty)
        #expect(model.pane == .text)
        // The old reading's answer lands nowhere.
        reader.answer(TextReaderTool.Formula(latex: "a", ending: "end"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.formulas.isEmpty)
    }

    @Test func withoutThePackNothingIsRead() {
        let model = Self.model()
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        model.addFormula(CGRect(x: 0, y: 0, width: 50, height: 50))
        model.readWholeImageAsFormula()
        #expect(model.formulas.isEmpty)
    }
}
