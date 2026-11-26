import CoreGraphics
import Foundation
import ImageIO
import OMSCore
import OMSDesign
import OMSOCR
import OSLog
import UniformTypeIdentifiers

/// The model packs the text reader reads with beside Vision, and the text reader inside the app that runs them: which
/// packs are installed now, their models compiled as each is installed, and what Core ML made of them tidied away once
/// they are gone.
final class TextReaderPacks {
    /// The text reader inside the app and the packs installed for it, as a reading is about to start.
    struct Installed: Sendable {
        /// The text reader.
        let helper: URL
        /// The pack L2 reads with beside L1, nil while it isn't installed or disabled.
        let second: TextReaderPack?
        /// The formula pack's folder, nil while it isn't installed or disabled.
        let formula: URL?
        /// The VLM pack's folder, nil while it isn't installed or disabled.
        let vlm: URL?
    }

    /// Whether a pack is enabled by the user in Settings; defaults to true.
    var isPackEnabled: (String) -> Bool = { _ in true }

    /// The model packs the build offers; reads nothing until Settings shows them.
    private(set) lazy var center: ModelPackCenter = {
        let store = ModelPackStore.standard()
        let mirror: @Sendable () -> String? = { UserDefaults.standard.string(forKey: "modelPackMirrorURL") }
        let center = ModelPackCenter(
            store: store,
            downloader: ModelPackDownloader(store: store, customMirror: mirror),
            customMirror: mirror
        )
        center.prepareInstalled = { [weak self] pack, folder in
            await self?.preparePack(pack, in: folder)
        }
        // Said aloud, as uploads are: a download outlives the Settings window it started in.
        center.onInstalled = { [weak self] pack, _ in
            VoiceOver.announce(String(localized: "“\(pack.name)” installed"))
            if pack.id == ModelPackCatalog.ppocrV6Small.id {
                self?.secondReadingWarmed?()
            }
        }
        center.onFailed = { pack, _ in
            VoiceOver.announce(String(localized: "“\(pack.name)” couldn’t download"))
        }
        center.onRemoved = { [weak self] in self?.tidyReaderCache() }
        return center
    }()

    /// The L2 pack was just installed and its models compiled (or failed to be): the history's Chinese and Japanese
    /// captures can be read again with it.
    var secondReadingWarmed: (() -> Void)?

    /// The text reader inside the app, for readings someone waits on.
    var helper: URL? { Bundle.main.url(forAuxiliaryExecutable: "OhMyShot Text Reader") }

    /// The text reader and the packs installed and enabled now; nil while the reader isn't in the app.
    var installed: Installed? {
        guard let helper else { return nil }
        return Installed(helper: helper, second: secondReading, formula: formula, vlm: vlm)
    }

    /// The model pack L2 reads with beside L1 (Docs/ocr.md › L2 beside L1), when installed and enabled:
    /// Capture Text (when enabled), the OCR panel, Shortcuts, and the history's search read Chinese and Japanese with it.
    var secondReading: TextReaderPack? {
        let pack = ModelPackCatalog.ppocrV6Small
        guard isPackEnabled(pack.id) else { return nil }
        // The merge's revision too: text kept from earlier rules is read again.
        return center.installedFolder(of: pack).map {
            TextReaderPack(folder: $0, reading: "\(pack.id)/\(pack.version)/merge-\(SecondReading.revision)")
        }
    }

    /// The formula pack, when installed and enabled: Capture Formula reads with it (Docs/ocr.md › The formula pack), and its
    /// entries show only then; the text Capture Text, the OCR panel, and Recognize Text in Image read holds each formula
    /// as LaTeX (Docs/ocr.md › Formulas among text).
    var formula: URL? {
        let pack = ModelPackCatalog.ppFormulaNetPlusL
        guard isPackEnabled(pack.id) else { return nil }
        return center.installedFolder(of: pack)
    }

    /// The VLM pack, when installed and enabled: the text Capture Text, the OCR panel, and Recognize Text in Image read holds
    /// the tables and charts in the picture a row a line, as PaddleOCR-VL reads them (Docs/ocr.md › The VLM pack).
    var vlm: URL? {
        let pack = ModelPackCatalog.paddleOCRVL
        guard isPackEnabled(pack.id) else { return nil }
        return center.installedFolder(of: pack)
    }

    /// Installed pack files went: what Core ML made of them in the reader's cache, about 350 MB for the formula pack,
    /// goes too (Docs/perf.md › M6 — Formulas in the panel).
    private func tidyReaderCache() {
        guard let helper else { return }
        Task {
            do {
                let removed = try await TextReaderTool.tidy(helper: helper)
                Log.modelPacks.notice("Tidied the text reader's Core ML cache: \(removed, privacy: .public) entries removed")
            } catch {
                Log.modelPacks.error("Tidying the text reader's Core ML cache failed: \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Compiles a newly downloaded pack's Core ML models while `ModelPackCenter` shows `.preparing`:
    /// L2 for the Neural Engine, Formula for CPU, and VLM's `layout.mlpackage` without loading the full MLX weights.
    private func preparePack(_ pack: ModelPack, in folder: URL) async {
        guard let helper else { return }
        let started = ContinuousClock.now
        do {
            switch pack.id {
            case ModelPackCatalog.ppFormulaNetPlusL.id:
                try await TextReaderTool.warm(formula: folder, helper: helper)
            case ModelPackCatalog.ppocrV6Small.id:
                try await TextReaderTool.warm(pack: folder, helper: helper)
            case ModelPackCatalog.paddleOCRVL.id:
                try await Self.warmVLMLayout(in: folder, helper: helper)
            default:
                return
            }
            Log.modelPacks.notice("Warmed \(pack.id, privacy: .public) in \(String(describing: ContinuousClock.now - started), privacy: .public)")
        } catch {
            Log.modelPacks.error("Warming \(pack.id, privacy: .public) failed: \(Log.kind(of: error), privacy: .public), \(String(describing: error), privacy: .private)")
        }
    }

    /// Pre-compiles `layout.mlpackage` inside the VLM pack by running a tiny blank image with `.critical`
    /// memory pressure, which runs Core ML layout compilation while skipping the 2.6 GB VLM weights.
    @concurrent
    private nonisolated static func warmVLMLayout(in folder: URL, helper: URL) async throws {
        guard let context = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage() else { return }
        let file = FileManager.default.temporaryDirectory.appending(path: "OhMyShot-warm-layout-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        _ = try await TextReaderTool.elements(ofPictureAt: file, vlm: folder, seconds: nil, pressure: .critical, helper: helper, timeout: .seconds(120))
    }
}
