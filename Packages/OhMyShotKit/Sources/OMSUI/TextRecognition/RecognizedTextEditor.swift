import AppKit
import OMSOCR
import SwiftUI

/// The editable text of the OCR panel: an `NSTextView`, so input methods, undo, Find, and services behave
/// as everywhere else on the Mac. The selection follows the model both ways, detected links can be
/// clicked, and a text the model replaces (switching line breaks) is a single undoable change.
struct RecognizedTextEditor: NSViewRepresentable {
    let model: TextRecognitionModel

    /// Body text, a little more open than the default: lines that mix Chinese and Latin sit tight.
    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.15
        return style
    }()

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ActivityTrackingTextView(frame: .zero)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 14)
        textView.defaultParagraphStyle = Self.paragraphStyle
        textView.typingAttributes[.paragraphStyle] = Self.paragraphStyle
        // Recognized text is the source of truth here; the system must not "correct" it.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.setAccessibilityLabel(String(localized: "Recognized text", bundle: .module))
        textView.onActivityChange = { [model] active in model.editorIsActive = active }
        context.coordinator.textView = textView
        context.coordinator.apply(model.text, undoable: false)
        context.coordinator.appliedRevision = model.revision
        context.coordinator.appliedFocusRequest = model.focusRequest
        OCRTextWrapping.apply(model.wrapsText, to: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = coordinator.textView else { return }
        OCRTextWrapping.apply(model.wrapsText, to: scrollView)
        let body = NSFont.preferredFont(forTextStyle: .body)
        let font: NSFont = model.isCode ? .monospacedSystemFont(ofSize: body.pointSize, weight: .regular) : body
        coordinator.isCode = model.isCode
        if textView.font != font {
            textView.font = font
            textView.typingAttributes[.font] = font
            coordinator.styleTables(force: true)
        }
        if coordinator.appliedRevision != model.revision {
            coordinator.apply(model.text, undoable: coordinator.appliedRevision != nil)
            coordinator.appliedRevision = model.revision
        }
        coordinator.styleLinks(model.items)
        let length = (textView.string as NSString).length
        let location = min(model.selection.location, length)
        let selection = NSRange(location: location, length: min(model.selection.length, length - location))
        if textView.selectedRange() != selection, !coordinator.isReportingSelection {
            coordinator.isApplyingSelection = true
            textView.setSelectedRange(selection)
            textView.scrollRangeToVisible(selection)
            coordinator.isApplyingSelection = false
        }
        // A line picked on the image: the text takes focus, so its selection is live and ⌘C copies it.
        // Deferred: focus changes report back to the model, which must not change during an update.
        if coordinator.appliedFocusRequest != model.focusRequest {
            coordinator.appliedFocusRequest = model.focusRequest
            Task { @MainActor [weak textView, weak coordinator] in
                guard let textView, let coordinator, textView.window?.makeFirstResponder(textView) == true else { return }
                // The highlight was drawn before focus arrived; drawing it again shows it as active.
                coordinator.isApplyingSelection = true
                textView.setSelectedRange(textView.selectedRange())
                textView.setNeedsDisplay(textView.visibleRect)
                coordinator.isApplyingSelection = false
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: TextRecognitionModel
        weak var textView: NSTextView?
        var appliedRevision: Int?
        var appliedFocusRequest = 0
        /// The links last styled, so the text storage is only touched when they change.
        var styledItems: [DetectedItem]?
        var isApplyingText = false
        var isApplyingSelection = false
        var isReportingSelection = false
        /// Code keeps the default stops: its tabs line up what the code's author lined up.
        var isCode = false
        /// The table blocks last styled, so the text storage is only touched when they change.
        private var styledTables: [TableTabStops.Block]?

        init(model: TextRecognitionModel) {
            self.model = model
        }

        /// Replaces the whole text; undoable, so switching line breaks never loses an edit for good.
        func apply(_ text: String, undoable: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            isApplyingText = true
            defer { isApplyingText = false }
            // New characters carry no link attributes: style them afresh.
            styledItems = nil
            let whole = NSRange(location: 0, length: storage.length)
            if undoable {
                guard textView.shouldChangeText(in: whole, replacementString: text) else { return }
                storage.replaceCharacters(in: whole, with: text)
                textView.didChangeText()
            } else {
                textView.string = text
            }
            storage.addAttribute(.paragraphStyle, value: textView.defaultParagraphStyle ?? .default, range: NSRange(location: 0, length: storage.length))
            styleTables(force: true)
        }

        /// Gives a table's rows stops as wide as its columns (`TableTabStops`), again after each edit, since an edit can
        /// widen a cell or end a row. Left alone while an input method is composing, as links are.
        func styleTables(force: Bool = false) {
            guard let textView, let storage = textView.textStorage, let font = textView.font, !textView.hasMarkedText() else { return }
            let blocks = isCode ? [] : TableTabStops.blocks(in: textView.string, font: font)
            guard force || blocks != styledTables else { return }
            styledTables = blocks
            TableTabStops.apply(blocks, base: textView.defaultParagraphStyle ?? RecognizedTextEditor.paragraphStyle, to: storage)
        }

        /// Links, mail addresses, phone numbers, and addresses become clickable; dates stay plain text.
        /// Left alone while an input method is composing: editing the storage then can cut the composition.
        func styleLinks(_ items: [DetectedItem]) {
            guard let textView, let storage = textView.textStorage, !textView.hasMarkedText(), items != styledItems else { return }
            styledItems = items
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.removeAttribute(.link, range: whole)
            for item in items where NSMaxRange(item.range) <= storage.length {
                if let url = item.url { storage.addAttribute(.link, value: url, range: item.range) }
            }
            storage.endEditing()
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingText, let textView else { return }
            styleTables()
            model.textEdited(textView.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingSelection, !isApplyingText, let textView else { return }
            isReportingSelection = true
            model.selection = textView.selectedRange()
            isReportingSelection = false
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL else { return false }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}

/// A text view that reports whether it draws its selection as active: first responder in the key
/// window. The panel colors the boxes on the image to match.
final class ActivityTrackingTextView: NSTextView {
    var onActivityChange: ((Bool) -> Void)?
    private var hasFocus = false
    private var isActive = false
    private var observers: [NSObjectProtocol] = []

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        hasFocus = true
        report()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        hasFocus = false
        report()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            })
        }
        report()
    }

    private func report() {
        let active = hasFocus && window?.isKeyWindow == true
        guard active != isActive else { return }
        isActive = active
        // Never from inside a SwiftUI update, where focus can change.
        let callback = onActivityChange
        Task { @MainActor in callback?(active) }
    }
}

/// The translation in the OCR panel: selectable but not editable, in the editor's type, with Find, its
/// links underlined as in the editor and its translated parts marked as in the target language, so
/// VoiceOver reads them in that language's voice.
struct TranslatedTextView: NSViewRepresentable {
    let text: String
    let translated: [NSRange]
    let language: String
    var wrapsText = true

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(frame: .zero)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 14)
        textView.font = .preferredFont(forTextStyle: .body)
        textView.defaultParagraphStyle = RecognizedTextEditor.paragraphStyle
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.setAccessibilityLabel(String(localized: "Translation", bundle: .module))
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        OCRTextWrapping.apply(wrapsText, to: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        OCRTextWrapping.apply(wrapsText, to: scrollView)
        guard let textView = scrollView.documentView as? NSTextView, let storage = textView.textStorage, textView.string != text else { return }
        textView.string = text
        TableTabStops.apply(TableTabStops.blocks(in: text, font: textView.font ?? .preferredFont(forTextStyle: .body)), base: RecognizedTextEditor.paragraphStyle, to: storage)
        storage.beginEditing()
        for range in translated where NSMaxRange(range) <= storage.length {
            storage.addAttribute(.accessibilityLanguage, value: language, range: range)
        }
        for item in TextDetector.items(in: text) where NSMaxRange(item.range) <= storage.length {
            if let url = item.url { storage.addAttribute(.link, value: url, range: item.range) }
        }
        storage.endEditing()
    }
}

/// Changes only native text layout. Text storage, selection, undo, and marked text stay in place.
enum OCRTextWrapping {
    static func apply(_ wraps: Bool, to scrollView: NSScrollView) {
        guard let textView = scrollView.documentView as? NSTextView, let container = textView.textContainer else { return }
        let scrollsHorizontally = !wraps
        let resizing: NSView.AutoresizingMask = wraps ? [.width] : []
        guard container.widthTracksTextView != wraps || textView.isHorizontallyResizable != scrollsHorizontally
                || scrollView.hasHorizontalScroller != scrollsHorizontally || textView.autoresizingMask != resizing else { return }
        scrollView.hasHorizontalScroller = scrollsHorizontally
        textView.isHorizontallyResizable = scrollsHorizontally
        textView.autoresizingMask = resizing
        container.widthTracksTextView = wraps
        if wraps {
            textView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: textView.frame.height))
            container.containerSize = NSSize(
                width: max(0, scrollView.contentSize.width - 2 * textView.textContainerInset.width),
                height: CGFloat.greatestFiniteMagnitude
            )
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.sizeToFit()
        if wraps {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.contentView.bounds.minY))
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
