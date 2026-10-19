import AppKit
import OMSCore
import OMSOCR
import Testing
@testable import OMSUI

struct OCRTextWrappingTests {
    @Test func eachWindowSnapshotsTheDefaultAndKeepsItsOverrideLocal() throws {
        let suite = "OCRTextWrappingTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.textRecognitionWrapsText = false
        let first = TextRecognitionModel(settings: settings, translator: Translator())
        #expect(!first.wrapsText)
        first.wrapsText = true
        #expect(!settings.textRecognitionWrapsText)
        let second = TextRecognitionModel(settings: settings, translator: Translator())
        #expect(!second.wrapsText)
        settings.textRecognitionWrapsText = true
        #expect(!second.wrapsText)
        #expect(TextRecognitionModel(settings: settings, translator: Translator()).wrapsText)
        first.textEdited("A long paragraph with an explicit line break.\n中文与 English remain unchanged.")
        first.selection = NSRange(location: 2, length: 8)
        let text = first.text
        let revision = first.revision
        first.wrapsText = false
        #expect(first.text == text && first.revision == revision && first.edited)
        #expect(first.selection == NSRange(location: 2, length: 8))
        #expect(!first.joinLines)
    }

    @Test func wrappingReflowsWithoutChangingTextAttributesSelectionOrUndo() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        scrollView.scrollerStyle = .legacy
        scrollView.hasVerticalScroller = true
        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 12, height: 14)
        textView.font = .systemFont(ofSize: 13)
        textView.allowsUndo = true
        scrollView.documentView = textView
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer { window.close() }
        let text = String(repeating: "A long recognized sentence 中文 mixed with English. ", count: 12) + "\n\tcode keeps its tab and newline"
        textView.string = text
        textView.setSelectedRange(NSRange(location: 6, length: 12))
        textView.textStorage?.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 0, length: 1))
        var undoWasCalled = false
        textView.undoManager?.registerUndo(withTarget: textView) { _ in undoWasCalled = true }
        let attributed = textView.attributedString()
        let container = try #require(textView.textContainer)
        let layout = try #require(textView.layoutManager)
        func fragments() -> Int {
            layout.ensureLayout(for: container)
            var count = 0
            layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { _, _, _, _, _ in count += 1 }
            return count
        }

        OCRTextWrapping.apply(true, to: scrollView)
        let wrappedFragments = fragments()
        #expect(wrappedFragments > 2)
        OCRTextWrapping.apply(false, to: scrollView)
        #expect(fragments() == 2)
        #expect(scrollView.hasHorizontalScroller && textView.frame.width > scrollView.contentSize.width)
        OCRTextWrapping.apply(true, to: scrollView)
        #expect(fragments() == wrappedFragments)
        #expect(!scrollView.hasHorizontalScroller)
        #expect(textView.frame.width <= scrollView.contentSize.width)
        #expect(textView.attributedString().isEqual(to: attributed))
        #expect(textView.selectedRange() == NSRange(location: 6, length: 12))
        #expect(textView.undoManager?.canUndo == true)
        textView.undoManager?.undo()
        #expect(undoWasCalled)
    }
}
