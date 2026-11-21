import AppKit
import Foundation

/// What a Copy Text came to.
public enum TextCopy: Equatable, Sendable {
    /// The text is on the clipboard: this many characters, spaces and line breaks included.
    case copied(characters: Int)
    /// The picture holds no text to copy.
    case noText
    /// Something else was copied while the picture was read, which a reading that ends later never replaces; nothing
    /// is said.
    case superseded

    /// What a card's notice, or the Copied reading by the pointer, says; nil when nothing is said.
    var message: String? {
        switch self {
        case .copied(let characters): String(localized: "Copied \(characters) characters", bundle: .module)
        case .noText: String(localized: "No text found", bundle: .module)
        case .superseded: nil
        }
    }
}

/// Copy Text, from a Quick Access card or Capture History: reads a picture's text and puts it on the clipboard. A
/// reading that ends after a newer one began, or after anything else was copied, copies nothing, so a slow reading
/// never replaces what was copied since.
public final class TextCopier {
    private let pasteboard: NSPasteboard
    private let read: (URL) async -> String?
    private var latest: UUID?

    /// - Parameters:
    ///   - pasteboard: the clipboard; tests write to one of their own.
    ///   - read: a picture file's text as Capture Text puts it together, or nil when it has none.
    public init(pasteboard: NSPasteboard = .general, read: @escaping (URL) async -> String?) {
        self.pasteboard = pasteboard
        self.read = read
    }

    public func copyText(ofPictureAt url: URL) async -> TextCopy {
        let reading = UUID()
        latest = reading
        let changeCount = pasteboard.changeCount
        let text = await read(url)
        guard latest == reading, pasteboard.changeCount == changeCount, !Task.isCancelled else { return .superseded }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .noText }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return .copied(characters: text.count)
    }
}
