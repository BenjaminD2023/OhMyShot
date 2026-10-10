import CoreGraphics
import Foundation
import Vision

/// Finds sensitive text in a picture, for redaction suggestions. It reads the picture twice at once: with
/// the Latin model, which reads email addresses, keys, and numbers most faithfully, and with the Chinese
/// one, for names and addresses written in Chinese, the reading the highlighter's lines are found in too.
/// Each match gets its own box from Vision, so covering it leaves the rest of its line readable. All of it
/// stays on this Mac.
public struct SensitiveTextScanner: Sendable {
    public init() {}

    public func scan(_ image: CGImage) async throws -> [SensitiveText] {
        try await scan(TextRecognition(image))
    }

    /// Scans what `recognition` reads: a reading it has made already, or is making for something else, is
    /// not made again. Throws when neither reading could be made.
    @concurrent
    public func scan(_ recognition: TextRecognition) async throws -> [SensitiveText] {
        async let latin = attempt(in: recognition, by: .latin)
        async let chinese = attempt(in: recognition, by: .chinese)
        // One reading failing (a model's first use running past the timeout) still leaves the other's.
        let (latinFound, chineseFound) = await (latin, chinese)
        try Task.checkCancellation()
        if case .failure(let error) = latinFound, case .failure = chineseFound { throw error }
        return Self.combined(latin: (try? latinFound.get()) ?? [], chinese: (try? chineseFound.get()) ?? [])
    }

    private func attempt(in recognition: TextRecognition, by model: TextRecognition.Model) async -> Result<[SensitiveText], any Error> {
        do {
            return .success(try await find(in: recognition, by: model))
        } catch {
            return .failure(error)
        }
    }

    /// The two readings as one. Names and addresses come from the Chinese reading only: the Latin model
    /// reads Chinese as Latin nonsense (a line of Chinese came back as two capital-letter "words" the name
    /// tagger took for a person), and the Chinese reading reads English names and addresses as well.
    static func combined(latin: [SensitiveText], chinese: [SensitiveText]) -> [SensitiveText] {
        merged(latin.filter { $0.kind != .name && $0.kind != .address } + chinese)
    }

    private func find(in recognition: TextRecognition, by model: TextRecognition.Model) async throws -> [SensitiveText] {
        let observations = try await recognition.lines(by: model)
        let image = recognition.image
        let size = CGSize(width: image.width, height: image.height)
        var found: [SensitiveText] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string
            for match in SensitiveTextFinder.matches(in: line) {
                // The whole line's box when Vision cannot place the match within it: covering too much is
                // the safe side.
                let box = candidate.boundingBox(for: match.range).map { $0.boundingBox.toImageCoordinates(size, origin: .upperLeft) }
                    ?? observation.boundingBox.toImageCoordinates(size, origin: .upperLeft)
                found.append(SensitiveText(kind: match.kind, box: Self.fitted(box, in: image), text: String(line[match.range])))
            }
        }
        return found
    }

    /// Vision's box for part of a line is loose by a few pixels at either end, reaching into the gap before
    /// the word or clipping its first glyph: its ends moved to the ink, so a cover over it neither nicks the
    /// label beside it ("Mail:") nor leaves an edge of a glyph showing. Left as it is where the background
    /// is too busy to tell ink from it.
    static func fitted(_ box: CGRect, in image: CGImage) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // How far an end may move outward, onto a glyph Vision clipped.
        let reach = (box.height * 0.5).rounded()
        let region = box.insetBy(dx: -reach, dy: 0).integral.intersection(bounds)
        guard !region.isNull, region.width >= 4, region.height >= 4, let part = image.cropping(to: region) else { return box }
        let width = Int(region.width), height = Int(region.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return box }
        // Clear parts read as white.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return box }
        let pixels = data.assumingMemoryBound(to: UInt8.self), stride = context.bytesPerRow
        // The line's middle, clear of the lines above and below.
        let top = height * 15 / 100
        let rows = top..<max(height * 85 / 100, top + 1)
        // The background is the most common shade.
        var histogram = [Int](repeating: 0, count: 32)
        for row in rows {
            for column in 0..<width { histogram[Int(pixels[row * stride + column]) >> 3] += 1 }
        }
        let background = (histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0) * 8 + 4
        let ink = (0..<width).map { column in
            rows.contains { abs(Int(pixels[$0 * stride + column]) - background) > 48 }
        }
        guard ink.filter({ $0 }).count < width * 9 / 10 else { return box }
        let first = max(0, min(width - 1, Int((box.minX - region.minX).rounded(.down))))
        let last = max(first, min(width - 1, Int((box.maxX - region.minX).rounded(.up)) - 1))
        guard let firstInk = (first...last).first(where: { ink[$0] }), let lastInk = (first...last).last(where: { ink[$0] }) else { return box }
        var left = firstInk, right = lastInk
        // An end on a glyph moves out to the glyph's edge.
        if left == first { while left > 0, ink[left - 1] { left -= 1 } }
        if right == last { while right < width - 1, ink[right + 1] { right += 1 } }
        return CGRect(x: region.minX + CGFloat(left), y: box.minY, width: CGFloat(right - left + 1), height: box.height)
    }

    /// One suggestion for each stretch of text: matches from the two readings that overlap by more than half
    /// of the smaller are one, kept as the first reading's kind over both boxes, so no sliver of the text
    /// is left out.
    static func merged(_ found: [SensitiveText]) -> [SensitiveText] {
        var kept: [SensitiveText] = []
        for item in found {
            if let index = kept.firstIndex(where: { overlap($0.box, item.box) > 0.5 }) {
                kept[index].box = kept[index].box.union(item.box)
            } else {
                kept.append(item)
            }
        }
        return kept
    }

    /// How much of the smaller rectangle the two share.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        guard !shared.isNull, shared.width > 0, shared.height > 0 else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? shared.width * shared.height / smaller : 0
    }
}
