import CoreGraphics
import Foundation
import ImageIO
import MLX

/// The VLM pack in its folder: the model (`config.json`, `model.safetensors`), its tokens (`vocabulary.json`), and each
/// task's prompt, tokenized when the pack was made (`prompts.json`, {"ocr": {"before": […], "after": […]}, …}).
public final class PaddleOCRVLReader {
    /// What the model is asked to read a picture as. Its own prompts.
    public enum Task: String, Codable, Sendable, CaseIterable {
        /// "OCR:": the text, line by line.
        case ocr
        /// "Table Recognition:": a table, in OTSL tags.
        case table
        /// "Formula Recognition:": a formula, in LaTeX.
        case formula
        /// "Chart Recognition:": a chart's data, as a table.
        case chart
    }

    public struct Reading: Sendable {
        public var text: String
        public var tokens: Int
        public var ending: PaddleOCRVL.Ending
    }

    public enum Failure: Error {
        case noPrompt(Task)
        case unreadableImage
    }

    let model: PaddleOCRVL
    let vocabulary: PaddleOCRVLTokens
    let prompts: [String: PaddleOCRVL.Prompt]

    init(model: PaddleOCRVL, vocabulary: PaddleOCRVLTokens, prompts: [String: PaddleOCRVL.Prompt]) {
        self.model = model
        self.vocabulary = vocabulary
        self.prompts = prompts
    }

    public static func load(from folder: URL) throws -> PaddleOCRVLReader {
        // MLX keeps the GPU buffers a reading lets go of for the next to reuse, without bound: three readings in one
        // process had grown the footprint by 4 GB. A little is kept, and the rest let go after each reading.
        Memory.cacheLimit = 256 << 20
        let model = try PaddleOCRVL.load(from: folder)
        let vocabulary = try PaddleOCRVLTokens(contentsOf: folder.appending(path: "vocabulary.json"))
        let prompts = try JSONDecoder().decode(
            [String: PaddleOCRVL.Prompt].self, from: Data(contentsOf: folder.appending(path: "prompts.json")))
        return PaddleOCRVLReader(model: model, vocabulary: vocabulary, prompts: prompts)
    }

    /// `image` read as `task`, up to `maximum` tokens or until `deadline`.
    public func read(_ image: CGImage, task: Task, maximum: Int = 2048, deadline: ContinuousClock.Instant? = nil) throws -> Reading {
        guard let prompt = prompts[task.rawValue] else { throw Failure.noPrompt(task) }
        let picture = try PaddleOCRVLPicture(image)
        let (tokens, ending) = model.read(picture, prompt: prompt, maximum: maximum) {
            deadline.map { ContinuousClock.now >= $0 } ?? false
        }
        Memory.clearCache()
        return Reading(text: vocabulary.text(tokens), tokens: tokens.count, ending: ending)
    }

    /// Whether a `width` × `height` region is read: one the model would shrink to less than half its size (more than four
    /// times its 1 MP), a tall spreadsheet, say, it couldn't read the text of; that stays as Vision reads it.
    public static func reads(width: CGFloat, height: CGFloat) -> Bool {
        width >= 8 && height >= 8 && width * height <= CGFloat(PaddleOCRVLPicture.maximumPixels * 4)
    }

    /// `region` of `image` (its pixels, top-left origin) read as `task`, with 8 pixels more on each side the image has:
    /// the layout model boxes a table tight to its outer lines. Nil for a region not read (`reads`).
    public func read(_ image: CGImage, region: CGRect, task: Task, maximum: Int = 2048, deadline: ContinuousClock.Instant? = nil) throws -> Reading? {
        let crop = region.insetBy(dx: -8, dy: -8).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !crop.isNull, Self.reads(width: crop.width, height: crop.height), let part = image.cropping(to: crop) else { return nil }
        return try read(part, task: task, maximum: maximum, deadline: deadline)
    }

    /// The picture in `file` read as `task`.
    public func read(fileAt file: URL, task: Task, maximum: Int = 2048, deadline: ContinuousClock.Instant? = nil) throws -> Reading {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw Failure.unreadableImage }
        return try read(image, task: task, maximum: maximum, deadline: deadline)
    }
}
