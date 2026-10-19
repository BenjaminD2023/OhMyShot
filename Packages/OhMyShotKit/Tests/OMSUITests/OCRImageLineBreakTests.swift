import AppKit
import Foundation
import OMSCore
@testable import OMSOCR
import Testing
@testable import OMSUI

@MainActor
struct OCRImageLineBreakTests {
    private static func image() -> CGImage {
        let context = CGContext(
            data: nil, width: 400, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private static func line(_ text: String, x: CGFloat = 10, y: CGFloat, width: CGFloat? = nil, wraps: Bool? = nil) -> OCRLine {
        OCRLine(
            text: text, box: CGRect(x: x, y: y, width: width ?? CGFloat(text.count) * 10, height: 20),
            confidence: 1, wrapsToNextLine: wraps
        )
    }

    private static let prose = [
        line("This sentence continues onto", y: 10, width: 300),
        line("the next image line.", y: 36, width: 210),
        line("新的一段从这里开始", y: 90, width: 300),
        line("并在下一行继续。", y: 116, width: 220),
    ]
    private static let kept = "This sentence continues onto\nthe next image line.\n新的一段从这里开始\n并在下一行继续。"
    private static let joined = "This sentence continues onto the next image line.\n新的一段从这里开始并在下一行继续。"

    /// Supplies recognized image rows at fixed pixel coordinates; no OCR service is involved.
    private static func load(_ model: TextRecognitionModel, lines: [OCRLine] = prose) async throws {
        model.load(image: image(), scale: 1) { _ in
            TextAnalysis(result: OCRResult(lines: lines, text: lines.map(\.text).joined(separator: "\n"), duration: .zero), tables: [], codes: [])
        }
        for _ in 0..<200 where model.phase == .loading {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.phase == .ready)
    }

    @Test func changingTheWindowChoiceRebuildsActualNewlinesAndLeavesDisplayWrappingIndependent() async throws {
        let suite = "OCRImageLineBreakTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = TextRecognitionModel(settings: settings, translator: Translator(), pasteboard: pasteboard)
        defer { model.unload() }
        try await Self.load(model)
        #expect(model.text == Self.kept && !model.joinLines)
        model.copyShown()
        #expect(pasteboard.string(forType: .string) == Self.kept)

        model.joinLines = true
        #expect(model.text == Self.joined)
        #expect(model.lineRanges.count == Self.prose.count)
        model.wrapsText.toggle()
        #expect(model.text == Self.joined && settings.textRecognitionKeepsLineBreaks)
        model.copyText()
        #expect(pasteboard.string(forType: .string) == Self.joined)
        model.joinLines = false
        #expect(model.text == Self.kept)
        model.copyShown()
        #expect(pasteboard.string(forType: .string) == Self.kept)
    }

    @Test func temporaryOverridesStayWithTheirWindowAndNewWindowsSnapshotTheSavedDefault() async throws {
        let suite = "OCRImageLineBreakTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.textRecognitionKeepsLineBreaks = false
        let first = TextRecognitionModel(settings: settings, translator: Translator())
        defer { first.unload() }
        try await Self.load(first)
        #expect(first.text == Self.joined)
        first.joinLines = false
        #expect(first.text == Self.kept && !settings.textRecognitionKeepsLineBreaks)

        let second = TextRecognitionModel(settings: settings, translator: Translator())
        defer { second.unload() }
        try await Self.load(second)
        #expect(second.text == Self.joined)
        settings.textRecognitionKeepsLineBreaks = true
        #expect(second.joinLines && !first.joinLines)

        let reopened = TextRecognitionModel(settings: settings, translator: Translator())
        defer { reopened.unload() }
        try await Self.load(reopened)
        #expect(reopened.text == Self.kept)
        try await Self.load(first)
        #expect(first.text == Self.kept && !first.joinLines)
    }

    @Test func codeKeepsItsLinesEvenWhenTheSavedDefaultJoinsProse() async throws {
        let suite = "OCRImageLineBreakTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.textRecognitionKeepsLineBreaks = false
        let model = TextRecognitionModel(settings: settings, translator: Translator())
        defer { model.unload() }
        try await Self.load(model, lines: [
            Self.line("func run() {", y: 10, wraps: true),
            Self.line("return nil", x: 50, y: 36, wraps: true),
            Self.line("}", y: 62),
        ])
        #expect(model.isCode && model.joinLines)
        #expect(model.text == "func run() {\n    return nil\n}")
        model.joinLines = false
        #expect(model.text == "func run() {\n    return nil\n}")
    }
}
