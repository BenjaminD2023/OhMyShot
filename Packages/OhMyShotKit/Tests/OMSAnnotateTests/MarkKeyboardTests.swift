import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// The marks reached from the keyboard and by VoiceOver: Tab and Shift-Tab through them, 1 to 9 and [ ] for their
/// style, each mark an element of its own, and the keys listed where a sighted person looks. Nothing is shown.
@MainActor
struct MarkKeyboardTests {
    private let scratch = ScratchDefaults()

    private func makeCanvas(tool: AnnotationTool? = .select, items: [Annotation] = [], defaults: UserDefaults? = nil) throws -> (AnnotationCanvasView, AnnotationSession, NSWindow) {
        let context = try #require(CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let session = AnnotationSession(image: try #require(context.makeImage()), scale: 1, tool: tool, defaults: defaults ?? scratch.make())
        var document = session.document
        document.items = items
        session.commit(document, actionName: "Add")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvasView(session: session)
        canvas.contentInsets = NSEdgeInsetsZero
        canvas.frame = try #require(window.contentView).bounds
        window.contentView?.addSubview(canvas)
        window.makeFirstResponder(canvas)
        canvas.layoutSubtreeIfNeeded()
        return (canvas, session, window)
    }

    private func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
    }

    private var tab: NSEvent { get throws { try key("\t", keyCode: 48) } }

    private func arrow(_ x: CGFloat, color: RGBA = .red) -> Annotation {
        Annotation(shape: .arrow(Arrow(start: CGPoint(x: x, y: 20), end: CGPoint(x: x + 30, y: 60))), style: Style(color: color))
    }

    private func marks(_ canvas: AnnotationCanvasView) -> [MarkElement] {
        (canvas.accessibilityChildren() ?? []).compactMap { $0 as? MarkElement }
    }

    @Test func tabStepsThroughTheMarksInDrawingOrderThenLetsTheKeyboardGo() throws {
        let items = [arrow(20), arrow(120), arrow(220)]
        let (canvas, session, window) = try makeCanvas(items: items)
        defer { window.close() }

        for item in items {
            canvas.keyDown(with: try tab)
            #expect(session.selection == [item.id])
        }
        // Past the last, nothing stays selected and the key is the window's, to move on from the canvas.
        #expect(!canvas.selectAdjacentMark(backward: false))
        #expect(session.selection.isEmpty)

        canvas.keyDown(with: try key("\t", keyCode: 48, modifiers: .shift))
        #expect(session.selection == [items[2].id])
        canvas.keyDown(with: try key("\t", keyCode: 48, modifiers: .shift))
        #expect(session.selection == [items[1].id])
    }

    @Test func tabWithNoMarksLeavesAtOnceAndPutsAToolDownWhenThereAreSome() throws {
        let (empty, emptySession, emptyWindow) = try makeCanvas()
        defer { emptyWindow.close() }
        #expect(!empty.selectAdjacentMark(backward: false))
        #expect(emptySession.selection.isEmpty)

        let item = arrow(20)
        let defaults = scratch.make()
        defaults.set("pen", forKey: "annotation.tool")
        let (canvas, session, window) = try makeCanvas(tool: nil, items: [item], defaults: defaults)
        defer { window.close() }
        #expect(session.tool == .pen)
        canvas.keyDown(with: try tab)
        #expect(session.tool == .select && session.selection == [item.id])
        // Put down as a tool is after its mark: the next editor still opens with it.
        #expect(defaults.string(forKey: "annotation.tool") == "pen")
    }

    /// Zoomed in away from the mark Tab picks up, the picture moves to show it.
    @Test func tabBringsAMarkOutOfViewIntoIt() throws {
        let far = Annotation(shape: .rectangle(Box(rect: CGRect(x: 360, y: 160, width: 30, height: 30))), style: Style())
        let (canvas, session, window) = try makeCanvas(items: [far])
        defer { window.close() }
        canvas.zoomToActualSize()
        canvas.zoomIn()
        canvas.zoomIn()
        session.select([far.id])
        let before = try #require(canvas.selectionFrame)
        #expect(!canvas.bounds.contains(before))
        session.select([])

        canvas.keyDown(with: try tab)

        let after = try #require(canvas.selectionFrame)
        #expect(canvas.bounds.contains(after))
    }

    /// 1 to 9 choose the capsule's colors in its order, for the selected mark or the tool in hand; with neither they
    /// do nothing.
    @Test func digitsChooseTheCapsulesColors() throws {
        let item = arrow(20)
        let (canvas, session, window) = try makeCanvas(items: [item])
        defer { window.close() }

        canvas.keyDown(with: try key("2", keyCode: 19))
        #expect(session.document.item(item.id)?.style.color == .red)

        session.select([item.id])
        canvas.keyDown(with: try key("2", keyCode: 19))
        #expect(session.document.item(item.id)?.style.color == .orange)
        canvas.keyDown(with: try key("8", keyCode: 28))
        #expect(session.document.item(item.id)?.style.color == .white)

        // The highlighter's capsule leads with the marker yellow.
        session.select([])
        session.tool = .highlighter
        canvas.keyDown(with: try key("1", keyCode: 18))
        #expect(session.settings(for: .highlighter).color == .marker)
        #expect(canvas.keyedColors.first == .marker)
    }

    /// The ninth is the first color kept, after the eight inks, as the capsule numbers its chips.
    @Test func theNinthColorIsTheFirstKept() {
        let kept = RGBA(red: 32.0 / 255, green: 64.0 / 255, blue: 128.0 / 255)
        let colors = StyleCapsule.keyedColors(for: .arrow, settings: .defaults(for: .arrow), saved: [kept, .black])
        #expect(colors == StyleCapsule.palette + [kept])
        var blur = ToolSettings.defaults(for: .redact)
        blur.redaction = .blur
        #expect(StyleCapsule.keyedColors(for: .redact, settings: blur, saved: [kept]).isEmpty)
        #expect(StyleCapsule.keyedColors(for: .spotlight, settings: .defaults(for: .spotlight), saved: []).isEmpty)
    }

    /// [ and ] step through the capsule's sizes, the width or for text the type size, and stop at the ends.
    @Test func bracketsStepTheSize() throws {
        let line = arrow(20)
        let text = Annotation(shape: .text(TextBlock(origin: CGPoint(x: 200, y: 40), string: "Fix this", fontSize: 20)), style: Style())
        let (canvas, session, window) = try makeCanvas(items: [line, text])
        defer { window.close() }
        session.select([line.id])
        let width = { session.document.item(line.id)?.style.lineWidth }
        #expect(width() == 4)
        canvas.keyDown(with: try key("]", keyCode: 30))
        #expect(width() == 6)
        canvas.keyDown(with: try key("]", keyCode: 30))
        canvas.keyDown(with: try key("]", keyCode: 30))
        #expect(width() == 10)
        canvas.keyDown(with: try key("[", keyCode: 33))
        #expect(width() == 6)

        session.select([text.id])
        canvas.keyDown(with: try key("[", keyCode: 33))
        guard case .text(let block) = session.document.item(text.id)?.shape else { Issue.record("not text"); return }
        #expect(block.fontSize == 14)
    }

    /// At either end of the capsule's sizes a size between its steps stays as it is: [ on a 3 pt line, whose chosen chip is
    /// 2 pt, and ] on a 12 pt one, past the last.
    @Test func bracketsLeaveASizeBetweenStepsAtTheEnds() throws {
        var thin = arrow(20)
        thin.style.lineWidth = 3
        var thick = arrow(120)
        thick.style.lineWidth = 12
        let (canvas, session, window) = try makeCanvas(items: [thin, thick])
        defer { window.close() }

        session.select([thin.id])
        canvas.keyDown(with: try key("[", keyCode: 33))
        #expect(session.document.item(thin.id)?.style.lineWidth == 3)
        session.select([thick.id])
        canvas.keyDown(with: try key("]", keyCode: 30))
        #expect(session.document.item(thick.id)?.style.lineWidth == 12)
        canvas.keyDown(with: try key("[", keyCode: 33))
        #expect(session.document.item(thick.id)?.style.lineWidth == 6)
    }

    /// A digit from the keypad chooses its color as one from the number row does, and a bracket typed with Option, as
    /// layouts such as German type it, steps the size rather than choosing the color of the digit under it.
    @Test func keypadDigitsAndOptionBracketsAreStyleKeys() throws {
        let line = arrow(20)
        let (canvas, session, window) = try makeCanvas(items: [line])
        defer { window.close() }
        session.select([line.id])

        canvas.keyDown(with: try key("2", keyCode: 84, modifiers: .numericPad))
        #expect(session.document.item(line.id)?.style.color == StyleCapsule.palette[1])

        let optionBracket = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil,
            characters: "[", charactersIgnoringModifiers: "5", isARepeat: false, keyCode: 23
        ))
        canvas.keyDown(with: optionBracket)
        #expect(session.document.item(line.id)?.style.lineWidth == 2)
        #expect(session.document.item(line.id)?.style.color == StyleCapsule.palette[1])
    }

    /// Past the last mark, and before the first, Tab reaches the window, whose keyDown moves the keyboard to the next control.
    /// A mark to pick up keeps it. (The window here is never key, in a test process that is not the active app, so AppKit
    /// moves nothing itself; what is checked is that the canvas lets the key go to the window and that there is a next
    /// control for the window to move to.)
    @Test func tabPastTheEndsGoesOnToTheWindow() throws {
        let context = try #require(CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let session = AnnotationSession(image: try #require(context.makeImage()), scale: 1, tool: .select, defaults: scratch.make())
        let item = arrow(20)
        var document = session.document
        document.items = [item]
        session.commit(document, actionName: "Add")
        let window = KeyRecordingWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 230), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let canvas = AnnotationCanvasView(session: session)
        canvas.contentInsets = NSEdgeInsetsZero
        canvas.frame = CGRect(x: 0, y: 30, width: 400, height: 200)
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 80, height: 22))
        window.contentView?.addSubview(canvas)
        window.contentView?.addSubview(field)
        canvas.nextKeyView = field
        field.nextKeyView = canvas
        window.makeFirstResponder(canvas)

        canvas.keyDown(with: try tab)
        #expect(session.selection == [item.id] && window.tabs == 0)
        canvas.keyDown(with: try tab)
        #expect(session.selection.isEmpty && window.tabs == 1)
        canvas.keyDown(with: try key("\t", keyCode: 48, modifiers: .shift))
        #expect(session.selection == [item.id] && window.tabs == 1)
        canvas.keyDown(with: try key("\t", keyCode: 48, modifiers: .shift))
        #expect(session.selection.isEmpty && window.tabs == 2)
        #expect(canvas.nextValidKeyView === field && canvas.previousValidKeyView === field)
    }

    /// Each mark is a layout item VoiceOver names, frames where it is drawn, selects as a click would, and deletes.
    @Test func eachMarkIsANamedElementThatSelectsAndDeletes() throws {
        let items = [
            arrow(20),
            Annotation(shape: .text(TextBlock(origin: CGPoint(x: 120, y: 40), string: "Fix\nthis")), style: Style()),
            Annotation(shape: .counter(Counter(center: CGPoint(x: 250, y: 100), value: 3)), style: Style()),
            Annotation(shape: .redaction(Redaction(rect: CGRect(x: 300, y: 120, width: 60, height: 30), method: .solid)), style: Style()),
        ]
        let (canvas, session, window) = try makeCanvas(tool: .arrow, items: items)
        defer { window.close() }

        let elements = marks(canvas)
        #expect(elements.map(\.id) == items.map(\.id))
        #expect(elements.map { $0.accessibilityLabel() } == ["Arrow, Red", "Text: Fix this", "Counter 3", "Redaction"])
        #expect(elements.allSatisfy { $0.accessibilityRole() == .layoutItem })
        let frame = elements[3].accessibilityFrame()
        #expect(abs(frame.width - 60) < 0.5 && abs(frame.height - 30) < 0.5)

        elements[1].setAccessibilitySelected(true)
        #expect(session.tool == .select && session.selection == [items[1].id])
        #expect(elements[1].isAccessibilitySelected() && elements[1].isAccessibilityFocused())
        #expect(elements[2].accessibilityPerformPress())
        #expect(session.selection == [items[2].id])
        #expect((canvas.accessibilitySelectedChildren() as? [MarkElement])?.map(\.id) == [items[2].id])

        let delete = try #require(elements[0].accessibilityCustomActions()?.first)
        #expect(delete.name == "Delete")
        _ = (delete.target as AnyObject?)?.perform(delete.selector)
        #expect(session.document.items.map(\.id) == Array(items.dropFirst()).map(\.id))
        // The others keep their elements, so VoiceOver keeps its place.
        #expect(marks(canvas).map(ObjectIdentifier.init) == elements.dropFirst().map(ObjectIdentifier.init))
    }

    /// The capsule's chips name their keys in their tooltips, as the tools' chips do.
    @Test func theCapsuleChipsNameTheirKeys() throws {
        let saved = SavedColors(defaults: scratch.make())
        saved.add(RGBA(red: 32.0 / 255, green: 64.0 / 255, blue: 128.0 / 255))
        let capsule = StyleCapsule()
        capsule.savedColors = saved
        capsule.show(kind: .arrow, settings: .defaults(for: .arrow), hasSelection: false)
        func walk(_ view: NSView) -> [CapsuleChip] { (view as? CapsuleChip).map { [$0] } ?? view.subviews.flatMap(walk) }
        let chips = walk(capsule)
        func tip(_ label: String) -> String? { chips.first { $0.accessibilityLabel() == label }?.toolTip }
        #expect(tip("Red") == "Red (1)")
        #expect(tip("White") == "White (8)")
        #expect(tip("Saved Color") == "Saved Color (9)")
        #expect(tip("4 points") == "4 pt\n[ and ] go a size down or up.")
    }

    /// The rail's menu lists the keys after the tools, the colors with their numbers.
    @Test func theRailMenuListsTheKeys() throws {
        let (canvas, _, window) = try makeCanvas()
        defer { window.close() }
        let rail = ToolRail()
        rail.keyedColors = { [.red, .orange] }
        rail.markTarget = canvas
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let menu = try #require(rail.menu(for: event))
        let titled = Dictionary(menu.items.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(titled["Select Next Mark"]?.keyEquivalent == "\t")
        #expect(titled["Select Previous Mark"]?.keyEquivalentModifierMask == .shift)
        #expect(titled["Smaller"]?.keyEquivalent == "[" && titled["Larger"]?.keyEquivalent == "]")
        let colors = try #require(titled["Color"]?.submenu)
        #expect(colors.items.map(\.title) == ["Red", "Orange"] && colors.items.map(\.keyEquivalent) == ["1", "2"])
        // Sent to the canvas itself, which a rail chip holding the keys has no responder chain to.
        let keyed = ["Select Next Mark", "Select Previous Mark", "Smaller", "Larger"].compactMap { titled[$0] } + colors.items
        #expect(keyed.count == 6 && keyed.allSatisfy { $0.target === canvas })
    }

    /// In place the canvas is the same, so its keys are too.
    @Test func theKeysWorkInPlace() throws {
        let context = try #require(CGContext(
            data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let annotator = InPlaceAnnotationView(
            frame: try #require(context.makeImage()), scale: 2, size: CGSize(width: 400, height: 300),
            selection: CGRect(x: 80, y: 40, width: 200, height: 150), actions: .init(copy: { _ in }, save: { _ in }, openInEditor: { _ in }, cancel: {})
        )
        let item = Annotation(shape: .rectangle(Box(rect: CGRect(x: 200, y: 100, width: 40, height: 40))), style: Style())
        var document = annotator.session.document
        document.items = [item]
        annotator.session.commit(document, actionName: "Add")

        annotator.canvas.keyDown(with: try tab)
        #expect(annotator.session.selection == [item.id])
        annotator.canvas.keyDown(with: try key("5", keyCode: 23))
        #expect(annotator.session.document.item(item.id)?.style.color == .blue)
        #expect(marks(annotator.canvas).map { $0.accessibilityLabel() } == ["Rectangle, Blue"])
    }
}

/// A window that counts the Tabs that reach it, which its own keyDown turns into a move to the next control.
private final class KeyRecordingWindow: NSWindow {
    var tabs = 0

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 { tabs += 1 }
        super.keyDown(with: event)
    }
}
