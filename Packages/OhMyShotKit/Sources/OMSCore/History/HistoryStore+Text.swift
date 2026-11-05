import Foundation

/// The text read in each screenshot, kept beside it for searching the history (`HistoryText`, `HistoryTextReader`).
extension HistoryStore {
    /// The text read in the capture, for searching the history (`HistoryText`). Not `.json`, so listing the
    /// history never takes it for a record.
    public func textURL(for item: HistoryItem) -> URL {
        directory.appending(path: "\(item.fileName).text")
    }

    /// The capture's file as it is now, to tell later whether text read from it still belongs to it; nil
    /// when the file is gone.
    public func stamp(of item: HistoryItem) -> HistoryText.Stamp? {
        let values = try? fileURL(for: item).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values?.fileSize, let modified = values?.contentModificationDate else { return nil }
        return HistoryText.Stamp(size: size, modified: modified.timeIntervalSinceReferenceDate)
    }

    /// The text read in the capture as it is now; nil when none was read, or it was read from a picture
    /// since replaced (marked up, or put back as taken).
    public func text(of item: HistoryItem) -> String? {
        keptText(of: item)?.text
    }

    /// The text kept beside the capture, if it was read from the picture as it is now.
    private func keptText(of item: HistoryItem) -> HistoryText? {
        guard let data = try? Data(contentsOf: textURL(for: item)),
              let kept = try? JSONDecoder().decode(HistoryText.self, from: data),
              kept.version == HistoryText.version, kept.stamp == stamp(of: item)
        else { return nil }
        return kept
    }

    /// Keeps `text`, read from the capture's file when it was `stamp`, with `reading` the model pack read beside Vision
    /// (nil: none); if the file has changed since, the text is kept but counts as not read.
    public func setText(_ text: String, of item: HistoryItem, readFrom stamp: HistoryText.Stamp, reading: String? = nil) throws {
        let kept = HistoryText(version: HistoryText.version, stamp: stamp, text: text, reading: reading)
        try JSONEncoder().encode(kept).write(to: textURL(for: item), options: .atomic)
    }

    /// The screenshots among `items` whose text has not been read from their picture as it is now, and, with `reading`
    /// a model pack the reader has (`TextReaderPack.reading`), those read without it whose text holds Chinese or
    /// Japanese: the pack reads those better. Recordings have no text to read.
    public func needingText(_ items: [HistoryItem], reading: String? = nil) -> [HistoryItem] {
        items.filter { item in
            guard item.kind == .screenshot else { return false }
            guard let kept = keptText(of: item) else { return true }
            guard let reading, kept.reading != reading else { return false }
            return HistoryText.mayReadBetter(kept.text)
        }
    }
}
