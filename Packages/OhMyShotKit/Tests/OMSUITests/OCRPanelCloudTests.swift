import CoreGraphics
import Foundation
@testable import OMSCore
@testable import OMSOCR
import Testing
@testable import OMSUI

/// Reading with a cloud model in the OCR panel: only when asked, after the person agreed to the service, kept apart
/// from this Mac's reading, and stopped by a new picture.
struct OCRPanelCloudTests {
    /// Answers each reading when the test says so.
    private nonisolated final class Service: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: CheckedContinuation<CloudReading, any Error>?
        private var _reads: [String] = []

        /// The models read with, in order.
        var reads: [String] { lock.withLock { _reads } }
        var isWaiting: Bool { lock.withLock { waiting != nil } }

        @MainActor func cloud(_ store: CloudModelStore) -> TextRecognitionWindowController.Cloud {
            .init(store: store) { [self] _, model, progress in
                progress(12)
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        lock.withLock {
                            _reads.append(model.name)
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

    private static func store(agreed: Bool = true, models: Int = 1) -> CloudModelStore {
        let defaults = UserDefaults(suiteName: "OCRPanelCloudTests-\(UUID().uuidString)")!
        let store = CloudModelStore(defaults: defaults, secrets: InMemorySecretStore())
        for preset in [CloudModel.Preset.anthropic, .qwen].prefix(models) {
            let model = preset.makeModel()
            try? store.save(model, key: "k")
            if agreed { store.agree(model) }
        }
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

    @Test func withoutAModelThePanelOffersNothing() async {
        let model = Self.model(nil)
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        #expect(!model.offersCloud)
        let empty = Self.model(Service().cloud(Self.store(models: 0)))
        empty.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        #expect(!empty.offersCloud)
    }

    @Test func aReadingIsShownApartFromThisMacsAndBothCanBeSeen() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        #expect(model.offersCloud)
        #expect(service.reads.isEmpty)

        model.readInCloud(with: model.cloudModels[0])
        await Self.settle { service.isWaiting }
        #expect(service.reads == ["Claude"])
        await Self.settle { model.cloud == .reading(model.cloudModels[0], characters: 12) }
        #expect(model.text == "Plan Storage")

        service.answer("| Plan | Storage |\n|---|---|\n| Pro | 1 TB |")
        await Self.settle { model.source == .cloud }
        #expect(model.text == "| Plan | Storage |\n|---|---|\n| Pro | 1 TB |")
        #expect(model.lineRanges.isEmpty)
        #expect(model.tables == [OCRTable(rows: [["Plan", "Storage"], ["Pro", "1 TB"]])])
        #expect(model.panes == [.text, .table])

        model.show(.device)
        #expect(model.text == "Plan Storage")
        #expect(model.tables.isEmpty)
        #expect(model.panes.isEmpty)
        model.show(.cloud)
        #expect(model.text.hasPrefix("| Plan"))
        // Turned back, nothing is sent again.
        #expect(service.reads == ["Claude"])
    }

    @Test func theFirstPictureToAServiceWaitsForThePersonsYes() async {
        let service = Service()
        let store = Self.store(agreed: false)
        let model = Self.model(service.cloud(store))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        let claude = model.cloudModels[0]
        model.readInCloud(with: claude)
        #expect(model.askingToSend == claude)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(service.reads.isEmpty)
        #expect(model.cloud == .idle)

        model.agreeAndSend(claude)
        await Self.settle { service.isWaiting }
        #expect(service.reads == ["Claude"])
        #expect(store.isAgreed(claude))
        #expect(model.askingToSend == nil)
    }

    @Test func aNewPictureStopsTheReadingAndNothingCarriesOver() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        model.readInCloud(with: model.cloudModels[0])
        await Self.settle { service.isWaiting }

        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        // The request was cancelled: the service saw it go.
        await Self.settle { !service.isWaiting }
        #expect(!service.isWaiting)
        #expect(model.cloud == .idle)
        #expect(model.source == .device)
        await Self.settle { model.phase == .ready }
        #expect(model.text == "Plan Storage")
        // The next picture isn't sent by itself.
        try? await Task.sleep(for: .milliseconds(20))
        #expect(service.reads == ["Claude"])
    }

    @Test func cancellingLeavesThisMacsReading() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        model.readInCloud(with: model.cloudModels[0])
        await Self.settle { service.isWaiting }
        model.cancelCloudReading()
        await Self.settle { !service.isWaiting }
        #expect(model.cloud == .idle)
        #expect(model.text == "Plan Storage")
    }

    @Test func aFailureSaysWhyAndKeepsThisMacsReading() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        let claude = model.cloudModels[0]
        model.readInCloud(with: claude)
        await Self.settle { service.isWaiting }
        service.fail(CloudReadingError.keyRejected("invalid x-api-key"))
        await Self.settle { if case .failed = model.cloud { true } else { false } }
        #expect(model.cloud == .failed(claude, message: CloudReadingError.keyRejected("invalid x-api-key").localizedDescription, canRetry: false))
        #expect(model.source == .device)
        #expect(model.text == "Plan Storage")
    }

    @Test func handwritingVisionMissedComesFromTheCloud() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis([]))
        await Self.settle { model.phase == .empty }
        #expect(model.offersCloud)
        model.readInCloud(with: model.cloudModels[0])
        await Self.settle { service.isWaiting }
        service.answer("Dear Ann,\nsee you Tuesday.")
        await Self.settle { model.phase == .ready }
        #expect(model.source == .cloud)
        #expect(model.text == "Dear Ann,\nsee you Tuesday.")
    }

    @Test func anEmptyAnswerLeavesThisMacsReadingShown() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        model.readInCloud(with: model.cloudModels[0])
        await Self.settle { service.isWaiting }
        service.answer("")
        await Self.settle { if case .read = model.cloud { true } else { false } }
        #expect(model.source == .device)
        model.show(.cloud)
        #expect(model.source == .device)
    }

    @Test func translationAndTheCloudsReadingTakeTurns() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        model.translates = true
        model.readInCloud(with: model.cloudModels[0])
        #expect(!model.translates)
        await Self.settle { service.isWaiting }
        service.answer("Plan Storage, read in the cloud")
        await Self.settle { model.source == .cloud }
        // Changing the line breaks doesn't touch the cloud's text.
        model.joinLines = true
        #expect(model.text == "Plan Storage, read in the cloud")
        model.translates = false
    }

    @Test func formulasReadLaterGoIntoThisMacsTextOnly() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        let formula = FormulaMerge.Formula(kind: .display, box: CGRect(x: 10, y: 60, width: 200, height: 40), latex: "x^2")
        let formulas = TextRecognitionWindowController.Formulas(
            read: { _, found in
                found(1)
                try? await Task.sleep(for: .milliseconds(150))
                return [formula]
            },
            merge: { lines, formulas, _ in lines + formulas.map { OCRLine(text: "$\($0.latex)$", box: $0.box, confidence: 1, math: .display) } }
        )
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis(), formulas: formulas)
        await Self.settle { model.phase == .ready }
        model.readInCloud(with: model.cloudModels[0])
        await Self.settle { service.isWaiting }
        service.answer("Plan Storage\n$$x^2$$")
        await Self.settle { model.source == .cloud }
        await Self.settle { model.formulasBeingRead == nil && model.lines.count == 2 }
        #expect(model.text == "Plan Storage\n$$x^2$$")
        model.show(.device)
        #expect(model.text == "Plan Storage\n$x^2$")
    }

    @Test func theModelUsedLastIsOfferedFirst() async {
        let service = Service()
        let store = Self.store(models: 2)
        let model = Self.model(service.cloud(store))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        #expect(model.cloudModels.map(\.name) == ["Claude", "Qwen"])
        model.readInCloud(with: model.cloudModels[1])
        await Self.settle { service.isWaiting }
        service.answer("x")
        await Self.settle { model.source == .cloud }
        #expect(model.cloudModels.map(\.name) == ["Qwen", "Claude"])
    }
}
