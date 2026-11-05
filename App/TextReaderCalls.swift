import CoreGraphics
import Foundation
import ImageIO
import OMSCore
import OMSOCR
import OMSUI
import OSLog
import UniformTypeIdentifiers

/// Capture Text's and the OCR panel's readings in the text reader beside the app: the formula pack's, the VLM pack's,
/// and the second reading's (Docs/ocr.md › L2 beside L1, › The formula pack, › The VLM pack). Each hands the reader the
/// picture in a file of its own and removes it once read.
extension TextCaptureCoordinator {
    /// The formula the pack reads in `image`, in a run of the text reader, or nil when the reader couldn't read it.
    @concurrent
    nonisolated static func formula(in image: CGImage, pack: URL, helper: URL) async -> TextReaderTool.Formula? {
        guard let file = readerPicture(image, in: "Formula Readings") else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            return try await TextReaderTool.formula(ofPictureAt: file, pack: pack, helper: helper)
        } catch {
            Log.capture.error("Reading a formula failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The formulas the formula pack reads and the tables and charts the VLM pack reads in `image`, in a run of the text
    /// reader (Docs/ocr.md › Formulas among text, › The VLM pack), the VLM reading for `seconds` at most; none when it
    /// can't, or in a picture too large to look in. `found` is told how many there are to read.
    @concurrent
    nonisolated static func elements(
        in image: CGImage, formulas: URL?, vlm: URL?, seconds: Double, helper: URL,
        found: (@Sendable (TextRecognitionWindowController.Elements.Counts) -> Void)? = nil
    ) async -> TextRecognitionWindowController.Elements.Found {
        guard formulas != nil || vlm != nil, LayoutFinder.finds(width: image.width, height: image.height),
              let file = readerPicture(image, in: "Formula Readings")
        else { return .init() }
        defer { try? FileManager.default.removeItem(at: file) }
        let counted: (@Sendable (TextReaderTool.Found) -> Void)? = found.map { found in
            { @Sendable counts in found(.init(formulas: counts.formulas, tables: counts.tables)) }
        }
        var pressure: MemoryPressure?
        #if DEBUG
        // debug/memory-pressure: what the reader takes the system's memory pressure to be.
        pressure = UserDefaults.standard.string(forKey: "debugMemoryPressure").flatMap(MemoryPressure.init(name:))
        #endif
        do {
            let read = try await TextReaderTool.elements(
                ofPictureAt: file, formulas: formulas, vlm: vlm, seconds: seconds, pressure: pressure, helper: helper, found: counted
            )
            if read.tablesLeft > 0 {
                Log.capture.notice("Left \(read.tablesLeft, privacy: .public) tables and charts as Vision read them: the system is short of memory for the VLM pack")
            }
            return .init(
                formulas: read.formulas.map { formula in
                    FormulaMerge.Formula(kind: formula.kind == .display ? .display : .inline, box: formula.box, latex: formula.latex)
                },
                tables: read.tables.map { table in
                    TableMerge.Table(kind: table.kind == .chart ? .chart : .table, box: table.box, rows: table.rows, isWhole: table.whole)
                }
            )
        } catch {
            if !Task.isCancelled { Log.capture.error("Finding formulas and tables failed: \(String(describing: error), privacy: .public)") }
            return .init()
        }
    }

    /// What a merge of tables did, in numbers: how many were taken, and why each other was left.
    nonisolated static func log(_ merge: TableMerge.Merged, of tables: [TableMerge.Table], in surface: String, after elapsed: Duration) {
        let refusals = merge.refused.map { "\(tables[$0.index].kind.rawValue) \($0.refusal.rawValue)" }.joined(separator: ", ")
        let cut = merge.cutRows > 0 ? ", \(merge.cutRows) rows the picture's edge cut left as Vision read them" : ""
        Log.capture.notice("\(surface, privacy: .public) took \(merge.taken.count, privacy: .public) of \(tables.count, privacy: .public) tables and charts read with the VLM pack\(refusals.isEmpty ? "" : " (left: \(refusals))", privacy: .public)\(cut, privacy: .public), \(String(describing: elapsed), privacy: .public) after Vision's reading")
    }

    /// `image` as a TIFF for the text reader, in `folderName` in the temporary directory: uncompressed, written and read
    /// in a few milliseconds, where PNG takes a tenth of a second for a large picture. Nil, with nothing left behind, when
    /// it can't be written; the caller removes it once it is read.
    private nonisolated static func readerPicture(_ image: CGImage, in folderName: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appending(path: folderName, directoryHint: .isDirectory)
        let file = folder.appending(path: "\(UUID().uuidString).tiff")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.tiff.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return file
    }

    /// How long the panel waits for the second reading once Vision's is done. A pack whose models are compiled answers
    /// in about half a second (Docs/ocr.md › L2 beside L1); compiling them takes 11 s.
    nonisolated static let secondReadingWait: Duration = .seconds(3)

    /// The lines the pack reads in `image`, in a run of the text reader, or nil when it can't read them or hasn't
    /// answered within `secondReadingWait`. The run is not stopped when the wait ends: by then it is most likely
    /// compiling the pack's models for the Neural Engine (the first read after an install or a system update), and
    /// stopped, it would start over on every panel.
    @concurrent
    nonisolated static func secondReading(of image: CGImage, with pack: TextReaderPack, helper: URL) async -> [OCRLine]? {
        guard let file = readerPicture(image, in: "Second Readings") else { return nil }
        let reading = Task.detached(priority: .userInitiated) { () -> [TextReaderTool.Line]? in
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                return try await TextReaderTool.lines(ofPictureAt: file, pack: pack.folder, helper: helper)
            } catch {
                Log.capture.error("The second reading failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        // Whichever comes first: the reader's answer (nil when it failed), or the end of the wait (nil).
        guard case .success(let lines)? = await first(reading, within: secondReadingWait) else {
            // Also when the panel stopped waiting (closed, or read again).
            if !Task.isCancelled { Log.capture.notice("The second reading didn't answer in time; Vision's reading is shown alone") }
            return nil
        }
        return lines?.map { OCRLine(text: $0.text, box: $0.box, confidence: $0.confidence) }
    }
}
