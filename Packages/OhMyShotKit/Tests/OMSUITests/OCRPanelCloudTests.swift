import CoreGraphics
import Foundation
@testable import OMSCore
@testable import OMSOCR
import Testing
@testable import OMSUI

/// Reading with the cloud model in the OCR panel: the toolbar's Read with, or every picture while Settings says so;
/// kept apart from this Mac's reading, and stopped by a new picture or by turning it off.
struct OCRPanelCloudTests {
    /// Answers each reading when the test says so.
    private nonisolated final class Service: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<CloudReading, any Error>?
        private var _reads = 0

        var reads: Int { lock.withLock { _reads } }
        var isWaiting: Bool { lock.withLock { waiting != nil } }

        @MainActor func cloud(_ store: CloudModelStore) -> TextRecognitionWindowController.Cloud {
            .init(store: store) { [self] _, _, progress in
                progress(12)
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        lock.withLock {
                            _reads += 1
                            waiting = continuation
                        }
                    }
                } onCancel: {
                    self.fail(CancellationError())
                }
            }
        }

        func answer(_ text: String, complete: Bool = true) {
            take()?.resume(returning: CloudReading(text: text, model: "served-model", isComplete: complete, inputTokens: 100, outputTokens: 20))
        }

        func fail(_ error: any Error) {
            take()?.resume(throwing: error)
        }

        private func take() -> CheckedContinuation<CloudReading, any Error>? {
            lock.withLock {
                defer { waiting = nil }
                return waiting
            }
        }
    }

    private static func image() -> CGImage {
        let context = CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        return context.makeImage()!
    }

    private static func store(everyPicture: Bool = false, key: Bool = true) -> CloudModelStore {
        let defaults = UserDefaults(suiteName: "OCRPanelCloudTests-\(UUID().uuidString)")!
        let store = CloudModelStore(defaults: defaults, secrets: InMemorySecretStore())
        store.choose(.anthropic)
        if key { try? store.setKey("k") }
        store.readsInPanel = everyPicture
        return store
    }

    private static func model(_ cloud: TextRecognitionWindowController.Cloud?) -> TextRecognitionModel {
        let defaults = UserDefaults(suiteName: "OCRPanelCloudTests-\(UUID().uuidString)")!
        return TextRecognitionModel(settings: SettingsStore(defaults: defaults), translator: Translator(), cloud: cloud)
    }

    private static func analysis(_ lines: [OCRLine] = [line]) -> @Sendable (CGImage) async throws -> TextAnalysis {
        { _ in
            TextAnalysis(result: OCRResult(lines: lines, text: lines.map(\.text).joined(separator: "\n"), duration: .zero), tables: [], codes: [])
        }
    }

    private static let line = OCRLine(text: "Plan Storage", box: CGRect(x: 10, y: 10, width: 120, height: 20), confidence: 1)

    private static func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func withoutAUsableModelThereIsNoReadWith() async {
        let none = Self.model(nil)
        none.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        #expect(none.cloudModel == nil)
        // Set up but without its key: it can't read, so it isn't offered.
        let keyless = Self.model(Service().cloud(Self.store(key: false)))
        keyless.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        #expect(keyless.cloudModel == nil)
        keyless.readsInCloud = true
        #expect(!keyless.readsInCloud)
    }

    @Test func readWithShowsTheModelsTextAndOffShowsThisMacsAgain() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        #expect(model.cloudModel?.name == "Claude")
        #expect(service.reads == 0)

        model.readsInCloud = true
        await Self.settle { service.isWaiting }
        #expect(service.reads == 1)
        await Self.settle { model.cloud == .reading(characters: 12) }
        // This Mac's text stays until the model's comes.
        #expect(model.text == "Plan Storage")

        service.answer("| Plan | Storage |\n|---|---|\n| Pro | 1 TB |")
        await Self.settle { model.source == .cloud }
        #expect(model.text == "| Plan | Storage |\n|---|---|\n| Pro | 1 TB |")
        #expect(model.lineRanges.isEmpty)
        #expect(model.tables == [OCRTable(rows: [["Plan", "Storage"], ["Pro", "1 TB"]])])
        #expect(model.panes == [.text, .table])

        model.readsInCloud = false
        #expect(model.text == "Plan Storage")
        #expect(model.tables.isEmpty)
        model.readsInCloud = true
        #expect(model.text.hasPrefix("| Plan"))
        // Turned on again, nothing is sent again.
        #expect(service.reads == 1)
    }

    @Test func everyPictureIsReadWhenSettingsSaysSo() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store(everyPicture: true)))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        #expect(model.readsInCloud)
        await Self.settle { service.isWaiting && model.phase == .ready }
        #expect(model.text == "Plan Storage")
        service.answer("Plan Storage, read in the cloud")
        await Self.settle { model.source == .cloud }
        #expect(model.text == "Plan Storage, read in the cloud")

        // The next picture is read too, and the last one's reading is gone.
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { service.isWaiting && model.phase == .ready }
        #expect(service.reads == 2)
        #expect(model.source == .device)
        #expect(model.text == "Plan Storage")
    }

    @Test func aNewPictureStopsTheReadingAndIsntSentByItself() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        model.readsInCloud = true
        await Self.settle { service.isWaiting }

        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        // The request was cancelled: the service saw it go.
        await Self.settle { !service.isWaiting }
        #expect(!service.isWaiting)
        #expect(model.cloud == .idle)
        #expect(!model.readsInCloud)
        await Self.settle { model.phase == .ready }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(service.reads == 1)
    }

    @Test func turningItOffStopsTheReading() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        model.readsInCloud = true
        await Self.settle { service.isWaiting }
        model.readsInCloud = false
        await Self.settle { !service.isWaiting }
        #expect(model.cloud == .idle)
        #expect(model.text == "Plan Storage")
        // On again, it reads again.
        model.readsInCloud = true
        await Self.settle { service.isWaiting }
        #expect(service.reads == 2)
    }

    @Test func aFailureSaysWhyAndKeepsThisMacsText() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        model.readsInCloud = true
        await Self.settle { service.isWaiting }
        service.fail(CloudReadingError.overloaded(nil))
        await Self.settle { if case .failed = model.cloud { true } else { false } }
        #expect(model.cloud == .failed(message: CloudReadingError.overloaded(nil).localizedDescription, canRetry: true))
        #expect(model.source == .device)
        #expect(model.text == "Plan Storage")
        model.retryCloudReading()
        await Self.settle { service.isWaiting }
        #expect(service.reads == 2)
    }

    @Test func handwritingVisionMissedComesFromTheCloud() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis([]))
        await Self.settle { model.phase == .empty }
        model.readsInCloud = true
        await Self.settle { service.isWaiting }
        service.answer("Dear Ann,\nsee you Tuesday.")
        await Self.settle { model.phase == .ready }
        #expect(model.source == .cloud)
        #expect(model.text == "Dear Ann,\nsee you Tuesday.")
    }

    @Test func anEmptyAnswerLeavesThisMacsTextShown() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        model.readsInCloud = true
        await Self.settle { service.isWaiting }
        service.answer("")
        await Self.settle { if case .read = model.cloud { true } else { false } }
        #expect(model.readsInCloud)
        #expect(model.source == .device)
        #expect(model.text == "Plan Storage")
    }

    @Test func translationAndTheCloudTakeTurns() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        model.translates = true
        model.readsInCloud = true
        #expect(!model.translates)
        await Self.settle { service.isWaiting }
        service.answer("Plan Storage, read in the cloud")
        await Self.settle { model.source == .cloud }
        // Changing the line breaks doesn't touch the cloud's text.
        model.joinLines = true
        #expect(model.text == "Plan Storage, read in the cloud")
        model.translates = true
        #expect(!model.readsInCloud)
        #expect(model.source == .device)
        model.translates = false
    }

    @Test func formulasReadLaterGoIntoThisMacsTextOnly() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        let formula = FormulaMerge.Formula(kind: .display, box: CGRect(x: 10, y: 60, width: 200, height: 40), latex: "x^2")
        let formulas = TextRecognitionWindowController.Elements(
            read: { _, found in
                found(.init(formulas: 1, tables: 0))
                try? await Task.sleep(for: .milliseconds(150))
                return .init(formulas: [formula])
            },
            merge: { lines, formulas, _ in lines + formulas.map { OCRLine(text: "$\($0.latex)$", box: $0.box, confidence: 1, math: .display) } }
        )
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis(), elements: formulas)
        await Self.settle { model.phase == .ready }
        model.readsInCloud = true
        await Self.settle { service.isWaiting }
        service.answer("Plan Storage\n$$x^2$$")
        await Self.settle { model.source == .cloud }
        await Self.settle { model.beingRead == nil && model.lines.count == 2 }
        #expect(model.text == "Plan Storage\n$$x^2$$")
        model.readsInCloud = false
        #expect(model.text == "Plan Storage\n$x^2$")
    }
}
