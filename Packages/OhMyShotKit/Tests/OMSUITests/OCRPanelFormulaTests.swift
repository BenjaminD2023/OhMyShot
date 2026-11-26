import AppKit
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

    @Test func translationKeepsVisionTableCellsAfterTableMerge() async {
        let rows = [
            OCRLine(text: "Region Q1", box: CGRect(x: 10, y: 40, width: 200, height: 20), confidence: 1),
            OCRLine(text: "North 1,240", box: CGRect(x: 10, y: 70, width: 200, height: 20), confidence: 1),
        ]
        let visionTable = OCRTable(rows: [["Region Q1"], ["North 1,240"]], cellBoxes: [[rows[0].box], [rows[1].box]])
        let analyze: @Sendable (CGImage) async throws -> TextAnalysis = { _ in
            TextAnalysis(result: OCRResult(lines: rows, text: "", duration: .zero), tables: [visionTable], codes: [])
        }
        let table = TableMerge.Table(kind: .table, box: CGRect(x: 8, y: 36, width: 210, height: 58), rows: [["Region", "Q1"], ["North", "1,240"]], isWhole: true)
        let elements = TextRecognitionWindowController.Elements(
            read: { _, found in
                found(.init(formulas: 0, tables: 1))
                return .init(tables: [table])
            },
            merge: { lines, _, _ in lines }
        )
        let model = Self.model()
        model.load(image: Self.image(), scale: 2, analyze: analyze, elements: elements)
        await Self.settle { model.beingRead == nil && model.lines.contains(where: \.isTableRow) }
        // Display/copy lines use the VLM table rows, while translation keeps Vision's cell lines so tables can translate.
        let allTableRows = model.lines.allSatisfy(\.isTableRow)
        let translationHasTableRow = model.translationLines.contains(where: \.isTableRow)
        #expect(allTableRows)
        #expect(model.translationLines == rows)
        #expect(!translationHasTableRow)
    }

    @Test func translationEmptyReasonsDistinguishFormulasTablesVerticalAndCode() {
        func makeTranslation(_ skips: [TranslationUnit.Skip]) -> TextRecognitionModel.Translation {
            let units = skips.enumerated().map { index, skip in
                TranslationUnit(lines: [index], text: "item", box: .zero, skip: skip)
            }
            return TextRecognitionModel.Translation(
                choice: "zh-Hans",
                outcome: Translator.Outcome(target: Locale.Language(identifier: "zh-Hans")),
                units: units,
                text: "",
                translated: [],
                image: nil
            )
        }
        #expect(TranslationPane.emptyReason(for: makeTranslation([.code])) == .code)
        #expect(TranslationPane.emptyReason(for: makeTranslation([.formula])) == .formula)
        #expect(TranslationPane.emptyReason(for: makeTranslation([.formula, .figures])) == .formula)
        #expect(TranslationPane.emptyReason(for: makeTranslation([.table])) == .table)
        #expect(TranslationPane.emptyReason(for: makeTranslation([.table, .figures])) == .table)
        #expect(TranslationPane.emptyReason(for: makeTranslation([.vertical])) == .vertical)
        #expect(TranslationPane.emptyReason(for: makeTranslation([.link, .figures])) == .other)
        #expect(TranslationPane.emptyReason(for: makeTranslation([.code, .formula])) == .other)
    }

    @Test func visionPipelineConfiguredAndTextRecognitionRespectExplicitLanguages() {
        let korean = VisionPipeline.Options.configured(["ko-KR", "en-US"])
        #expect(korean.primaryLanguages.map(\.minimalIdentifier) == ["ko", "en"])
        #expect(korean.fallbackLanguages.map { $0.map(\.minimalIdentifier) } == [["en"]])

        let russianFrench = VisionPipeline.Options.configured(["ru-RU", "fr-FR"])
        #expect(russianFrench.primaryLanguages.map(\.minimalIdentifier) == ["ru", "fr"])
        #expect(russianFrench.fallbackLanguages.map { $0.map(\.minimalIdentifier) } == [["fr", "en"], ["en"]])

        let englishOnly = VisionPipeline.Options.configured(["en-US"])
        #expect(englishOnly.primaryLanguages.map(\.minimalIdentifier) == ["en"])
        #expect(englishOnly.fallbackLanguages.isEmpty)

        let automatic = VisionPipeline.Options.configured([], fallback: ["ja-JP", "en-US"])
        #expect(automatic.primaryLanguages.map(\.minimalIdentifier) == ["ja", "en"])

        let parsed = TextRecognition.parsedLanguages(["ar-SA", "en-US", "ar-SA", "  "])
        #expect(TextRecognition.resolvedLanguages(for: .chinese, configured: parsed).map { $0.languageCode?.identifier } == ["ar", "en"])
        #expect(TextRecognition.resolvedLanguages(for: .latin, configured: parsed).map { $0.languageCode?.identifier } == ["en"])
        #expect(TextRecognition.resolvedLanguages(for: .chinese, configured: []).map { $0.languageCode?.identifier } == ["zh", "en"])
    }

    @Test func formulaDelimiterFormatsCopiedFormulasAndText() async throws {
        let suite = "OCRPanelFormulaDelimiter-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let model = TextRecognitionModel(settings: settings, translator: Translator(), pasteboard: pasteboard)
        let mathLine = OCRLine(text: "$e^{i\\pi}+1=0$", box: CGRect(x: 10, y: 60, width: 200, height: 40), confidence: 1, math: .inline)
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis([Self.line, mathLine]))
        await Self.settle { model.phase == .ready }
        #expect(model.text == "Euler wrote\n$e^{i\\pi}+1=0$")

        settings.formulaDelimiter = .displayDollar
        model.copyText()
        #expect(pasteboard.string(forType: .string) == "Euler wrote\n$$e^{i\\pi}+1=0$$")

        settings.formulaDelimiter = .inlineParen
        model.copyText()
        #expect(pasteboard.string(forType: .string) == #"Euler wrote"# + "\n" + #"\(e^{i\pi}+1=0\)"#)

        model.copyFormula(#"\frac{a}{b}"#)
        #expect(pasteboard.string(forType: .string) == #"\(\frac{a}{b}\)"#)

        // Pure-formula content respects `.raw` cleanly without leaving delimiters.
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis([mathLine]))
        await Self.settle { model.phase == .ready && model.lines.count == 1 }
        settings.formulaDelimiter = .raw
        model.copyText()
        #expect(pasteboard.string(forType: .string) == #"e^{i\pi}+1=0"#)
    }

    @Test func inlineTableCellEditingUpdatesTSVAndCSVExports() async throws {
        let suite = "OCRPanelTableEdit-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let model = TextRecognitionModel(settings: SettingsStore(defaults: defaults), translator: Translator(), pasteboard: pasteboard)
        let table = OCRTable(rows: [["Region", "Q1"], ["North", "100"]])
        let line = Self.line
        let analyze: @Sendable (CGImage) async throws -> TextAnalysis = { _ in
            TextAnalysis(result: OCRResult(lines: [line], text: line.text, duration: .zero), tables: [table], codes: [])
        }
        model.load(image: Self.image(), scale: 2, analyze: analyze)
        await Self.settle { model.phase == .ready && !model.tables.isEmpty }

        model.updateTableCell(row: 1, column: 1, value: "1,240 \"net\"")
        #expect(model.currentTable?.rows == [["Region", "Q1"], ["North", "1,240 \"net\""]])

        model.copyTable(as: .tsv)
        #expect(pasteboard.string(forType: .string) == "Region\tQ1\nNorth\t1,240 \"net\"")

        model.copyTable(as: .csv)
        #expect(pasteboard.string(forType: .string) == "Region,Q1\r\nNorth,\"1,240 \"\"net\"\"\"")
    }

    @Test func imageRotationAndAreaCropReAnalyzeAndRestoreFullImage() async {
        let model = Self.model()
        let analyze: @Sendable (CGImage) async throws -> TextAnalysis = { img in
            let text = "\(img.width)x\(img.height)"
            let line = OCRLine(text: text, box: CGRect(x: 0, y: 0, width: 40, height: 12), confidence: 1)
            return TextAnalysis(result: OCRResult(lines: [line], text: text, duration: .zero), tables: [], codes: [])
        }
        model.freshAnalyzer = { analyze }
        model.load(image: Self.image(width: 400, height: 200), scale: 2, analyze: analyze)
        await Self.settle { model.phase == .ready && model.text == "400x200" }
        #expect(!model.isCropped)

        // Rotating 90° clockwise transposes dimensions and re-runs OCR.
        model.rotateImage(clockwise: true)
        await Self.settle { model.phase == .ready && model.text == "200x400" }
        #expect(model.image?.width == 200 && model.image?.height == 400)
        #expect(!model.isCropped)

        // Cropping to a sub-region sets isCropped, preserves fullImage, and re-runs OCR on the cropped pixels.
        model.cropImage(to: CGRect(x: 20, y: 30, width: 100, height: 80))
        await Self.settle { model.phase == .ready && model.text == "100x80" }
        #expect(model.isCropped)
        #expect(model.image?.width == 100 && model.image?.height == 80)
        #expect(model.fullImage?.width == 200 && model.fullImage?.height == 400)

        // Restoring full image brings back the full rotated image and clears isCropped.
        model.restoreFullImage()
        await Self.settle { model.phase == .ready && model.text == "200x400" }
        #expect(!model.isCropped)
        #expect(model.image?.width == 200 && model.image?.height == 400)
    }

    @Test func structuredQRCodeActionsCopyPasswordAndAllowOnlySafeSchemes() throws {
        let suite = "OCRPanelCodes-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        let model = TextRecognitionModel(settings: SettingsStore(defaults: defaults), translator: Translator(), pasteboard: pasteboard)
        let wifi = OCRCode(payload: "WIFI:T:WPA;S:Lab;P:p\\;ss;;", kind: .qr, box: .zero)
        let wifiAction = try #require(model.action(for: wifi))
        #expect(wifiAction.symbol == "key")
        wifiAction.perform()
        #expect(pasteboard.string(forType: .string) == "p;ss")

        let openWifi = OCRCode(payload: "WIFI:T:nopass;S:Guest;;", kind: .qr, box: .zero)
        #expect(model.action(for: openWifi) == nil)

        #expect(model.action(for: OCRCode(payload: "https://example.com", kind: .qr, box: .zero))?.symbol == "arrow.up.forward.app")
        #expect(model.action(for: OCRCode(payload: "mailto:hi@example.com", kind: .qr, box: .zero))?.symbol == "envelope")
        #expect(model.action(for: OCRCode(payload: "tel:+15550100", kind: .qr, box: .zero))?.symbol == "phone.arrow.up.right")
        #expect(model.action(for: OCRCode(payload: "javascript:alert(1)", kind: .qr, box: .zero)) == nil)
    }
}
