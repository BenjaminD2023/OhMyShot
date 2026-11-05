import Foundation
import OMSCore
import OMSDesign
import OMSOCR
import OSLog

/// The model packs the text reader reads with beside Vision, and the text reader inside the app that runs them: which
/// packs are installed now, their models compiled as each is installed, and what Core ML made of them tidied away once
/// they are gone.
final class TextReaderPacks {
    /// The text reader inside the app and the packs installed for it, as a reading is about to start.
    struct Installed: Sendable {
        /// The text reader.
        let helper: URL
        /// The pack L2 reads with beside L1, nil while it isn't installed.
        let second: TextReaderPack?
        /// The formula pack's folder, nil while it isn't installed.
        let formula: URL?
        /// The VLM pack's folder, nil while it isn't installed.
        let vlm: URL?
    }

    /// The model packs the build offers; reads nothing until Settings shows them.
    private(set) lazy var center: ModelPackCenter = {
        let store = ModelPackStore.standard()
        let center = ModelPackCenter(store: store, downloader: ModelPackDownloader(store: store))
        // Said aloud, as uploads are: a download outlives the Settings window it started in.
        center.onInstalled = { [weak self] pack, folder in
            VoiceOver.announce(String(localized: "“\(pack.name)” installed"))
            self?.packInstalled(pack, in: folder)
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

    /// The text reader and the packs installed now; nil while the reader isn't in the app.
    var installed: Installed? {
        guard let helper else { return nil }
        return Installed(helper: helper, second: secondReading, formula: formula, vlm: vlm)
    }

    /// The model pack L2 reads with beside L1 (Docs/ocr.md › L2 beside L1), when it is installed: the OCR panel and the
    /// history's search read Chinese and Japanese with it.
    var secondReading: TextReaderPack? {
        let pack = ModelPackCatalog.ppocrV6Small
        // The merge's revision too: text kept from earlier rules is read again.
        return center.installedFolder(of: pack).map {
            TextReaderPack(folder: $0, reading: "\(pack.id)/\(pack.version)/merge-\(SecondReading.revision)")
        }
    }

    /// The formula pack, when it is installed: Capture Formula reads with it (Docs/ocr.md › The formula pack), and its
    /// entries show only then; the text Capture Text, the OCR panel, and Recognize Text in Image read holds each formula
    /// as LaTeX (Docs/ocr.md › Formulas among text).
    var formula: URL? {
        center.installedFolder(of: ModelPackCatalog.ppFormulaNetPlusL)
    }

    /// The VLM pack, when it is installed: the text Capture Text, the OCR panel, and Recognize Text in Image read holds
    /// the tables and charts in the picture a row a line, as PaddleOCR-VL reads them (Docs/ocr.md › The VLM pack).
    var vlm: URL? {
        center.installedFolder(of: ModelPackCatalog.paddleOCRVL)
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
                Log.modelPacks.error("Tidying the text reader's Core ML cache failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A pack just installed: its models are compiled now, in the background, rather than on the first reading someone
    /// waits on. The L2 pack's compile for the Neural Engine (11 s), then the history's Chinese and Japanese captures
    /// are read again with it; the formula pack's for the CPU (under a second).
    private func packInstalled(_ pack: ModelPack, in folder: URL) {
        guard let helper else { return }
        if pack.id == ModelPackCatalog.ppFormulaNetPlusL.id {
            Task {
                let started = ContinuousClock.now
                do {
                    try await TextReaderTool.warm(formula: folder, helper: helper)
                    Log.modelPacks.notice("Warmed \(pack.id, privacy: .public) in \(String(describing: ContinuousClock.now - started), privacy: .public)")
                } catch {
                    Log.modelPacks.error("Warming \(pack.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
            return
        }
        guard pack.id == ModelPackCatalog.ppocrV6Small.id else { return }
        Task { [weak self] in
            let started = ContinuousClock.now
            do {
                try await TextReaderTool.warm(pack: folder, helper: helper)
                Log.modelPacks.notice("Warmed \(pack.id, privacy: .public) in \(String(describing: ContinuousClock.now - started), privacy: .public)")
            } catch {
                Log.modelPacks.error("Warming \(pack.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            self?.secondReadingWarmed?()
        }
    }
}
