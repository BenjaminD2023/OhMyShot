import AppKit
import CoreGraphics
import Foundation

public extension NSPasteboard.PasteboardType {
    /// Encoded `[Annotation]` JSON for copying and pasting marks within and across editor windows.
    static let ohMyShotAnnotations = NSPasteboard.PasteboardType("app.ohmyshot.annotations")
}

/// Encodes and decodes annotations on `NSPasteboard` for Cut/Copy/Paste within and across editor
/// windows, assigning fresh identifiers and clamping pasted positions inside the target canvas.
nonisolated public enum AnnotationPasteboard {
    /// Default offset applied when pasting marks, in pixels.
    public static let pasteOffset: CGFloat = 16

    public static func encode(_ marks: [Annotation]) throws -> Data {
        try JSONEncoder().encode(marks)
    }

    public static func decode(_ data: Data) throws -> [Annotation] {
        try JSONDecoder().decode([Annotation].self, from: data)
    }

    @MainActor
    public static func hasAnnotations(on pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.availableType(from: [.ohMyShotAnnotations]) != nil
    }

    @MainActor
    @discardableResult
    public static func write(_ marks: [Annotation], to pasteboard: NSPasteboard = .general) -> Bool {
        guard !marks.isEmpty, let data = try? encode(marks) else { return false }
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: .ohMyShotAnnotations)
    }

    @MainActor
    public static func read(from pasteboard: NSPasteboard = .general) -> [Annotation]? {
        guard let data = pasteboard.data(forType: .ohMyShotAnnotations),
              let marks = try? decode(data),
              !marks.isEmpty
        else { return nil }
        return marks
    }

    /// Prepares `marks` for insertion into `document`: assigns fresh UUIDs, shifts by `offset` pixels,
    /// clamps the pasted group inside `document.canvas` when it would land outside (such as pasting from
    /// a larger capture into a smaller window), and advances counter numbers sequentially.
    public static func preparedForPaste(
        _ marks: [Annotation],
        into document: AnnotationDocument,
        offset: CGSize = CGSize(width: pasteOffset, height: pasteOffset)
    ) -> [Annotation] {
        guard !marks.isEmpty else { return [] }
        let scale = document.scale
        let canvas = document.canvas.standardized
        var moved = marks.map { mark -> Annotation in
            var copy = mark.translated(by: offset)
            copy.id = UUID()
            return copy
        }
        let combined = moved
            .map { $0.bounds(scale: scale) }
            .filter { !$0.isNull && !$0.isEmpty }
            .reduce(CGRect.null) { $0.union($1) }
        if !combined.isNull, canvas.width > 0, canvas.height > 0 {
            var dx: CGFloat = 0
            var dy: CGFloat = 0
            if combined.width <= canvas.width {
                if combined.maxX > canvas.maxX { dx = canvas.maxX - combined.maxX }
                if combined.minX + dx < canvas.minX { dx = canvas.minX - combined.minX }
            } else {
                dx = canvas.midX - combined.midX
            }
            if combined.height <= canvas.height {
                if combined.maxY > canvas.maxY { dy = canvas.maxY - combined.maxY }
                if combined.minY + dy < canvas.minY { dy = canvas.minY - combined.minY }
            } else {
                dy = canvas.midY - combined.midY
            }
            if dx != 0 || dy != 0 {
                moved = moved.map { $0.translated(by: CGSize(width: dx, height: dy)) }
            }
        }
        var running = document
        for index in moved.indices {
            if case .counter(var counter) = moved[index].shape {
                counter.value = running.nextCounterValue(for: counter.numbering)
                moved[index].shape = .counter(counter)
            }
            running.items.append(moved[index])
        }
        return moved
    }
}
