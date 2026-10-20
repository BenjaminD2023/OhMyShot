import CoreGraphics
import Foundation
import OMSCore
@testable import OMSOCR
import Testing
@testable import OMSUI

/// Formulas in the OCR panel's text: found and read beside Vision's reading, then put into the lines as LaTeX.
struct OCRPanelFormulaTests {
    /// Answers the reading when the test says so, after saying how many it found; puts each formula in as a line of its
    /// own, as `$…$`.
    private nonisolated final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<[FormulaMerge.Formula], Never>?
        private var _reads = 0
        private var _merged: [[OCRLine]] = []

        var reads: Int { lock.withLock { _reads } }
        var isWaiting: Bool { lock.withLock { waiting != nil } }
        /// The lines each merge was given.
        var merged: [[OCRLine]] { lock.withLock { _merged } }

        var formulas: TextRecognitionWindowController.Elements {
            .init(
                read: { [self] _, found in
                    found(.init(formulas: 1, tables: 0))
                    let formulas = await withCheckedContinuation { continuation in
                        lock.withLock {
                            _reads += 1
                            waiting = continuation
                        }
                    }
                    return .init(formulas: formulas)
                },
                merge: { [self] lines, formulas, _ in
                    lock.withLock { _merged.append(lines) }
                    return lines + formulas.map { OCRLine(text: "$\($0.latex)$", box: $0.box, confidence: 1, math: .inline) }
                }
            )
        }

        func answer(_ formulas: [FormulaMerge.Formula]) {
            let continuation = lock.withLock {
                defer { waiting = nil }
                return waiting
            }
            continuation?.resume(returning: formulas)
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

    private static let line = OCRLine(text: "Euler wrote", box: CGRect(x: 10, y: 10, width: 120, height: 20), confidence: 1)
    private static let formula = FormulaMerge.Formula(kind: .display, box: CGRect(x: 10, y: 60, width: 200, height: 40), latex: #"e^{i\pi}+1=0"#)

    /// Lets the model's tasks run until `condition` holds, or a second has gone by.
    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func formulasComeIntoTheTextOnceRead() async {
        let model = Self.model()
        let reader = Reader()
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis([Self.line]), elements: reader.formulas)
        // The reading starts with the image, beside Vision's.
        await Self.settle { model.phase == .ready && reader.isWaiting && model.beingRead != nil }
        #expect(model.text == "Euler wrote")
        #expect(model.beingRead == .init(formulas: 1, tables: 0))
        #expect(model.panes.isEmpty)

        reader.answer([Self.formula])
        await Self.settle { model.beingRead == nil && model.lines.count == 2 }
        #expect(reader.merged == [[Self.line]])
        #expect(model.text == "Euler wrote\n$e^{i\\pi}+1=0$")
        // The formula's line is outlined on the image as any other.
        #expect(model.lineRanges.count == 2)
    }

    @Test func noFormulasLeaveTheTextAsItWas() async {
        let model = Self.model()
        let reader = Reader()
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis([Self.line]), elements: reader.formulas)
        await Self.settle { reader.isWaiting && model.phase == .ready }
        let revision = model.revision
        reader.answer([])
        await Self.settle { model.beingRead == nil }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(reader.merged.isEmpty)
        #expect(model.revision == revision)
        #expect(model.text == "Euler wrote")
    }

    @Test func anImageWithNoTextButAFormulaHasText() async {
        let model = Self.model()
        let reader = Reader()
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis(), elements: reader.formulas)
        await Self.settle { model.phase == .empty && model.beingRead != nil }
        reader.answer([Self.formula])
        await Self.settle { model.phase == .ready }
        #expect(model.text == "$e^{i\\pi}+1=0$")
    }

    @Test func editsStayAndRevertBringsTheFormulas() async {
        let model = Self.model()
        let reader = Reader()
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis([Self.line]), elements: reader.formulas)
        await Self.settle { reader.isWaiting && model.phase == .ready }
        model.textEdited("Euler wrote, as I recall")
        reader.answer([Self.formula])
        await Self.settle { model.beingRead == nil && model.lines.count == 2 }
        #expect(model.text == "Euler wrote, as I recall")
        #expect(model.edited)
        model.revert()
        #expect(model.text == "Euler wrote\n$e^{i\\pi}+1=0$")
    }

    @Test func aNewImageDropsTheLastOnesFormulas() async {
        let model = Self.model()
        let first = Reader()
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis([Self.line]), elements: first.formulas)
        await Self.settle { first.isWaiting && model.phase == .ready }
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        #expect(model.beingRead == nil)
        // The old reading's answer lands nowhere.
        first.answer([Self.formula])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(first.merged.isEmpty)
        #expect(model.text.isEmpty)
        #expect(model.beingRead == nil)
    }

    @Test func aTableReadLaterTakesVisionsLinesAndTable() async {
        let rows = [
            OCRLine(text: "Region Q1", box: CGRect(x: 10, y: 40, width: 200, height: 20), confidence: 1),
            OCRLine(text: "North 1,240", box: CGRect(x: 10, y: 70, width: 200, height: 20), confidence: 1),
        ]
        let visionTable = OCRTable(rows: [["Region Q1"], ["North 1,240"]], cellBoxes: [[rows[0].box], [rows[1].box]])
        let lines = [Self.line] + rows
        let analyze: @Sendable (CGImage) async throws -> TextAnalysis = { _ in
            TextAnalysis(result: OCRResult(lines: lines, text: "", duration: .zero), tables: [visionTable], codes: [])
        }
        let table = TableMerge.Table(kind: .table, box: CGRect(x: 8, y: 36, width: 210, height: 58), rows: [["Region", "Q1"], ["North", "1,240"]], isWhole: true)
        let elements = TextRecognitionWindowController.Elements(
            read: { _, found in
                found(.init(formulas: 0, tables: 1))
                try? await Task.sleep(for: .milliseconds(100))
                return .init(tables: [table])
            },
            merge: { lines, _, _ in lines }
        )
        let model = Self.model()
        model.load(image: Self.image(), scale: 2, analyze: analyze, elements: elements)
        await Self.settle { model.phase == .ready && model.beingRead != nil }
        #expect(model.beingRead == .init(formulas: 0, tables: 1))
        #expect(model.tables == [visionTable])
        await Self.settle { model.beingRead == nil && model.text.contains("\t") }
        #expect(model.text == "Euler wrote\nRegion\tQ1\nNorth\t1,240")
        #expect(model.tables == [OCRTable(rows: table.rows)])
    }

    @Test func withoutThePackNothingIsRead() async {
        let model = Self.model()
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis([Self.line]))
        await Self.settle { model.phase == .ready }
        #expect(model.beingRead == nil)
        #expect(model.text == "Euler wrote")
    }
}
