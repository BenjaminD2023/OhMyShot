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

    @Test func cloudReadingAndEditedTextSupportTextOnlyTranslation() async {
        let service = Service()
        let defaults = UserDefaults(suiteName: "OCRPanelCloudTests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.translationTarget = "zh-Hant"
        let model = TextRecognitionModel(settings: settings, translator: Translator(), cloud: service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }

        model.readsInCloud = true
        await Self.settle { service.isWaiting }
        service.answer("简体中文第一段\n\n简体中文第二段")
        await Self.settle { model.source == .cloud }
        // Changing the line breaks doesn't touch the cloud's text.
        model.joinLines = true
        #expect(model.text == "简体中文第一段\n\n简体中文第二段")

        // Translating Cloud OCR keeps Cloud mode active and produces a text-only paragraph translation.
        model.translates = true
        await Self.settle { model.translation != nil && !model.isTranslating }
        #expect(model.readsInCloud)
        #expect(model.source == .cloud)
        #expect(model.translation?.isTextOnly == true)
        #expect(model.translation?.image == nil)
        #expect(model.translation?.text == "簡體中文第一段\n簡體中文第二段")

        // Turning off Cloud switches to edited/device text cleanly.
        model.translates = false
        model.readsInCloud = false
        model.textEdited("简体中文修改")
        model.translates = true
        await Self.settle { model.translation != nil && !model.isTranslating }
        #expect(model.translation?.isTextOnly == true)
        #expect(model.translation?.image == nil)
        #expect(model.translation?.text == "簡體中文修改")
        model.translates = false
    }

    @Test func cloudModelRefreshesDynamicallyAndSupportsRereadAfterCompletion() async throws {
        let service = Service()
        let store = Self.store(key: false)
        let model = Self.model(service.cloud(store))
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        #expect(model.cloudModel == nil)

        // Setting a key in Settings makes cloudModel available immediately without reloading the image.
        try store.setKey("k")
        #expect(model.cloudModel != nil)

        model.readsInCloud = true
        await Self.settle { service.isWaiting }
        service.answer("First truncated read", complete: false)
        await Self.settle { model.source == .cloud }
        #expect(model.text == "First truncated read")

        // Re-read works even after a completed or truncated reading.
        model.retryCloudReading()
        await Self.settle { service.isWaiting }
        #expect(service.reads == 2)
        service.answer("Second complete read", complete: true)
        await Self.settle { model.text == "Second complete read" }
        #expect(model.text == "Second complete read")

        store.clearKey()
        #expect(model.cloudModel == nil)
    }

    @Test func pureQRCodeImageCannotCopyEmptyText() async {
        let model = Self.model(nil)
        let qr = OCRCode(payload: "https://example.com", kind: .qr, box: CGRect(x: 10, y: 10, width: 80, height: 80))
        model.load(image: Self.image(), scale: 2, analyze: { _ in
            TextAnalysis(result: OCRResult(lines: [], text: "", duration: .zero), tables: [], codes: [qr])
        })
        await Self.settle { model.phase == .ready }
        #expect(model.codes == [qr])
        #expect(model.text.isEmpty)
        #expect(!model.canCopy)
        model.copyText()
        #expect(!model.copied)
    }

    @Test func confirmDiscardEditsGuardsReplacingEditedText() async {
        let model = Self.model(nil)
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        model.textEdited("My edited notes")
        #expect(model.edited)

        var prompts = 0
        model.confirmDiscardEdits = {
            prompts += 1
            return false
        }
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis([OCRLine(text: "Replacement", box: CGRect(x: 0, y: 0, width: 50, height: 20), confidence: 1)]))
        #expect(prompts == 1)
        #expect(model.text == "My edited notes")
        #expect(model.edited)

        model.confirmDiscardEdits = {
            prompts += 1
            return true
        }
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis([OCRLine(text: "Replacement", box: CGRect(x: 0, y: 0, width: 50, height: 20), confidence: 1)]))
        await Self.settle { model.text == "Replacement" }
        #expect(prompts == 2)
        #expect(!model.edited)
    }

    @Test func asyncSecondReadingRefinerUpdatesLinesAfterVisionShowsImmediately() async {
        let model = Self.model(nil)
        let release = Gate()
        let refinedLine = OCRLine(text: "Refined by L2", box: Self.line.box, confidence: 1)
        model.secondReadingRefiner = { _, _ in
            await release.wait()
            return [refinedLine]
        }
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready }
        // Vision's text is visible immediately before L2 finishes.
        #expect(model.text == "Plan Storage")

        release.open()
        await Self.settle { model.text == "Refined by L2" }
        #expect(model.text == "Refined by L2")
    }

    @Test func seededCloudReadingAvoidsDuplicateRequest() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store(everyPicture: true)))
        let seeded = CloudReading(text: "Seeded from Capture Text", model: "claude", isComplete: true)
        TextRecognitionWindowController.seedNextCloudReading(seeded)
        model.load(image: Self.image(), scale: 2, analyze: Self.analysis())
        await Self.settle { model.phase == .ready && model.source == .cloud }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.text == "Seeded from Capture Text")
        #expect(service.reads == 0)
    }

    @Test func slowSelectionHighlightShowsPreparingStatusAfterDelay() async {
        let original = TextSelectionHighlight.slowNoticeDelay
        TextSelectionHighlight.slowNoticeDelay = .milliseconds(25)
        defer { TextSelectionHighlight.slowNoticeDelay = original }

        let highlight = TextSelectionHighlight()
        highlight.show(CGRect(x: 100, y: 100, width: 160, height: 40))
        #expect(highlight.currentStatus == nil)
        await Self.settle { highlight.currentStatus != nil }
        #expect(highlight.currentStatus?.contains("Esc") == true)
        highlight.hide()
        #expect(highlight.currentStatus == nil)
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

    @Test func cloudReadingRecoversWhenVisionFailsFirst() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store()))
        model.load(image: Self.image(), scale: 2, analyze: { _ in throw OCRError.timedOut })
        await Self.settle { if case .failed = model.phase { true } else { false } }
        guard case .failed = model.phase else { Issue.record("Expected failed phase"); return }

        model.readsInCloud = true
        await Self.settle { service.isWaiting }
        service.answer("Recovered from cloud")
        await Self.settle { model.phase == .ready }
        #expect(model.source == .cloud)
        #expect(model.text == "Recovered from cloud")

        // Turning Cloud off returns to the failed local state; turning it back on restores the cached cloud text.
        model.readsInCloud = false
        guard case .failed = model.phase else { Issue.record("Expected failed phase after toggling off cloud"); return }
        model.readsInCloud = true
        #expect(model.phase == .ready)
        #expect(model.source == .cloud)
        #expect(model.text == "Recovered from cloud")
        #expect(service.reads == 1)
    }

    @Test func visionFailureWhileCloudIsReadingDoesNotHideCloudResult() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store(everyPicture: true)))
        model.load(image: Self.image(), scale: 2, analyze: { _ in throw OCRError.timedOut })
        await Self.settle { service.isWaiting }
        try? await Task.sleep(for: .milliseconds(30))
        // Local Vision failure must not overwrite loading with .failed while Cloud is actively reading.
        #expect(model.phase == .loading)

        service.answer("Read by cloud despite Vision failure")
        await Self.settle { model.phase == .ready }
        #expect(model.source == .cloud)
        #expect(model.text == "Read by cloud despite Vision failure")
    }

    private nonisolated final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiting: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                let immediate = lock.withLock { () -> Bool in
                    if opened { return true }
                    waiting = continuation
                    return false
                }
                if immediate { continuation.resume() }
            }
        }

        func open() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                opened = true
                defer { waiting = nil }
                return waiting
            }
            continuation?.resume()
        }
    }

    @Test func visionFailureAfterCloudSucceededDoesNotOverwriteCloudResult() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store(everyPicture: true)))
        let releaseVision = Gate()
        model.load(image: Self.image(), scale: 2, analyze: { _ in
            await releaseVision.wait()
            throw OCRError.timedOut
        })
        await Self.settle { service.isWaiting }
        service.answer("Fast cloud reading")
        await Self.settle { model.phase == .ready && model.source == .cloud }
        #expect(model.text == "Fast cloud reading")

        // Now let local Vision fail after Cloud already succeeded.
        releaseVision.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.phase == .ready)
        #expect(model.source == .cloud)
        #expect(model.text == "Fast cloud reading")
    }

    @Test func cloudFailureAfterVisionFailureSurfacesFailureInsteadOfStickingOnLoading() async {
        let service = Service()
        let model = Self.model(service.cloud(Self.store(everyPicture: true)))
        model.load(image: Self.image(), scale: 2, analyze: { _ in throw OCRError.timedOut })
        await Self.settle { service.isWaiting }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.phase == .loading)

        service.fail(CloudReadingError.overloaded(nil))
        await Self.settle { if case .failed = model.phase { true } else { false } }
        guard case .failed = model.phase else { Issue.record("Expected failed phase when both Vision and Cloud fail"); return }
    }

    @Test func localAndRemoteModelsUseDistinctSymbols() {
        let localAddresses = [
            "http://localhost:11434/v1",
            "http://127.0.0.1:11434/v1",
            "http://[::1]:11434/v1",
            "http://studio.local:11434/v1",
        ]
        for address in localAddresses {
            let local = CloudModel(kind: .openAICompatible, name: "Ollama", address: address, model: "qwen2.5vl")
            #expect(CloudToggle.symbol(for: local) == "desktopcomputer", "\(address)")
        }
        let remoteAnthropic = CloudModel.Preset.anthropic.makeModel()
        let remoteOpenAI = CloudModel.Preset.openAI.makeModel()
        #expect(CloudToggle.symbol(for: remoteAnthropic) == "cloud")
        #expect(CloudToggle.symbol(for: remoteOpenAI) == "cloud")
    }

    @Test func selectionHighlightStatusCapsulePositionsInsideDisplay() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let capsule = CGSize(width: 220, height: 24)
        // Normal case: centered 10 pt below the selection.
        let middle = CGRect(x: 500, y: 400, width: 200, height: 100)
        let below = TextSelectionHighlight.statusOrigin(capsuleSize: capsule, selection: middle, visibleFrame: visible)
        #expect(below == CGPoint(x: 490, y: 366))

        // Near bottom edge: flips 10 pt above the selection.
        let nearBottom = CGRect(x: 500, y: 10, width: 200, height: 100)
        let above = TextSelectionHighlight.statusOrigin(capsuleSize: capsule, selection: nearBottom, visibleFrame: visible)
        #expect(above == CGPoint(x: 490, y: 120))

        // Near left edge: clamps 6 pt inside the display.
        let nearLeft = CGRect(x: 0, y: 400, width: 60, height: 100)
        let clamped = TextSelectionHighlight.statusOrigin(capsuleSize: capsule, selection: nearLeft, visibleFrame: visible)
        #expect(clamped == CGPoint(x: 6, y: 366))

        // Full-height selection: tucks 10 pt inside the bottom of the selection.
        let fullHeight = CGRect(x: 500, y: 0, width: 200, height: 900)
        let tucked = TextSelectionHighlight.statusOrigin(capsuleSize: capsule, selection: fullHeight, visibleFrame: visible)
        #expect(tucked == CGPoint(x: 490, y: 10))
    }
}
