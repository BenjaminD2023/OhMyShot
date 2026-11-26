import AppKit
import Foundation
import Testing
@testable import OMSAnnotate

/// Draw on Screen's toolbar and keys, without putting a canvas on screen: the bar is the in-place toolbar's size, marks
/// the tool in hand, and lights Undo, Redo, and Clear only when they can act; keys that carry flags of their own still
/// count as plain keys.
@MainActor
struct ScreenSketchTests {
    private func makeController() -> ScreenSketchController {
        ScreenSketchController(defaults: UserDefaults(suiteName: "ohmyshot.tests.sketch.\(UUID().uuidString)")!)
    }

    @Test func theBarIsACapsuleOfRoundChipsMarkingTheToolInHand() {
        let controller = makeController()
        controller.choose(.arrow)
        let bar = SketchToolbarView(controller: controller)
        #expect(bar.fittingSize.height == 42)
        let look = bar.debugLook
        #expect(look.toolsOn == [.arrow])
        #expect(!look.undo && !look.redo && !look.clear && !look.clicksThrough)
    }

    @Test func clickingThroughLeavesNoToolInHandAndChoosingOneDrawsAgain() {
        let controller = makeController()
        let bar = SketchToolbarView(controller: controller)
        controller.setClicksThrough(true)
        bar.refresh()
        #expect(bar.debugLook.toolsOn.isEmpty && bar.debugLook.clicksThrough)
        controller.choose(.pen)
        bar.refresh()
        #expect(bar.debugLook.toolsOn == [.pen] && !bar.debugLook.clicksThrough)
    }

    @Test func forwardDeleteAndTheKeypadsDigitsAreAnsweredAsPlainKeys() throws {
        let controller = makeController()
        let forwardDelete = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{F728}", charactersIgnoringModifiers: "\u{F728}", isARepeat: false, keyCode: 117
        ))
        #expect(controller.handle(forwardDelete))
        let keypadThree = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad], timestamp: 0, windowNumber: 0, context: nil,
            characters: "3", charactersIgnoringModifiers: "3", isARepeat: false, keyCode: 85
        ))
        #expect(controller.handle(keypadThree))
        #expect(controller.tool == .arrow)
    }

    /// A canvas is clear all over, yet a click anywhere on it is its own, not the app's underneath: the window server
    /// would hand clicks on clear pixels through unless the panel says it takes them. A small canvas, for a moment.
    @Test func aClickOnTheClearCanvasIsTheCanvasesOwn() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let frame = CGRect(x: screen.frame.minX + 120, y: screen.frame.minY + 120, width: 60, height: 60)
        let panel = SketchPanel(frame: frame)
        panel.contentView = SketchView(frame: CGRect(origin: .zero, size: frame.size), controller: makeController())
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
            panel.close()
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(NSWindow.windowNumber(at: CGPoint(x: frame.midX, y: frame.midY), belowWindowWithWindowNumber: 0) == panel.windowNumber)
    }

    /// The pen, arrow, box, oval, and counter show the editor's own symbols and names; the laser has its own.
    @Test func theToolsAreTheEditorsOwn() {
        #expect(ScreenSketchController.Tool.pen.symbol == AnnotationTool.pen.symbol)
        #expect(ScreenSketchController.Tool.counter.name == AnnotationTool.counter.name)
        #expect(ScreenSketchController.Tool.highlighter.symbol == AnnotationTool.highlighter.symbol)
        #expect(ScreenSketchController.Tool.text.symbol == AnnotationTool.text.symbol)
        #expect(ScreenSketchController.Tool.laser.mark == nil)
        #expect(ScreenSketchController.Tool.eraser.mark == nil)
    }

    @Test func blackInkIsAvailableAndLineWidthsPersistCycleAndRespondToBracketKeys() throws {
        let suiteName = "ohmyshot.tests.sketch.widths.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let controller = ScreenSketchController(defaults: defaults)
        #expect(ScreenSketchController.colors == [.red, .yellow, .green, .blue, .white, .black])
        controller.choose(.black)
        #expect(controller.color == .black)

        #expect(ScreenSketchController.LineWidth.thin.value == 2.5)
        #expect(ScreenSketchController.LineWidth.medium.value == 4.5)
        #expect(ScreenSketchController.LineWidth.thick.value == 8.0)
        #expect(controller.lineWidth == .medium)

        // ] steps up to thick, [ steps down to medium then thin.
        let rightBracket = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "]", charactersIgnoringModifiers: "]", isARepeat: false, keyCode: 30
        ))
        let leftBracket = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "[", charactersIgnoringModifiers: "[", isARepeat: false, keyCode: 33
        ))
        #expect(controller.handle(rightBracket))
        #expect(controller.lineWidth == .thick)
        #expect(controller.handle(leftBracket))
        #expect(controller.lineWidth == .medium)
        #expect(controller.handle(leftBracket))
        #expect(controller.lineWidth == .thin)
        controller.cycleLineWidth()
        #expect(controller.lineWidth == .medium)
        controller.choose(.thick)

        // Persisted color & line width reload in a fresh controller instance.
        let reloaded = ScreenSketchController(defaults: defaults)
        #expect(reloaded.color == .black)
        #expect(reloaded.lineWidth == .thick)
    }

    @Test func keysSevenThroughNineSelectHighlighterTextAndEraser() throws {
        let controller = makeController()
        let cases: [(String, UInt16, ScreenSketchController.Tool)] = [
            ("7", 26, .highlighter),
            ("8", 28, .text),
            ("9", 25, .eraser),
        ]
        for (char, code, expected) in cases {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: char, charactersIgnoringModifiers: char, isARepeat: false, keyCode: code
            ))
            #expect(controller.handle(event))
            #expect(controller.tool == expected)
        }
    }

    @Test func highlighterDrawsTranslucentWideStrokeWithoutShadow() throws {
        let controller = makeController()
        let view = controller.debugAttachBoard()
        defer { controller.stop() }
        controller.choose(.yellow)
        controller.choose(.thick)
        controller.choose(.highlighter)
        controller.debugDraw(on: 0, from: CGPoint(x: 20, y: 40), to: CGPoint(x: 160, y: 40))
        let mark = try #require(view.marks.first)
        guard case .highlighter(let stroke) = mark.shape else {
            Issue.record("Expected highlighter stroke")
            return
        }
        #expect(stroke.points == [CGPoint(x: 20, y: 40), CGPoint(x: 160, y: 40)])
        #expect(mark.style.color.alpha < 0.5 && mark.style.color.alpha > 0.2)
        #expect(!mark.style.shadow)
        #expect(mark.style.lineWidth > controller.lineWidth.value * 2)
    }

    @Test func inlineTextCommitsOnReturnAndCancelsOnEscapeWithoutStopping() throws {
        let controller = makeController()
        let view = controller.debugAttachBoard()
        defer { controller.stop() }
        controller.choose(.blue)
        controller.choose(.text)

        // Escape cancels inline text editing without ending Draw on Screen.
        view.beginTextEditing(at: CGPoint(x: 60, y: 80))
        #expect(view.isEditingText)
        view.activeTextField?.stringValue = "Cancel me"
        let escape = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        #expect(controller.handle(escape))
        #expect(!view.isEditingText)
        #expect(controller.isActive)
        #expect(view.marks.isEmpty)

        // Return commits a readable .label text Annotation.
        view.beginTextEditing(at: CGPoint(x: 60, y: 80))
        let field = try #require(view.activeTextField)
        field.stringValue = "Look here"
        let handled = view.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(handled)
        #expect(!view.isEditingText)
        let mark = try #require(view.marks.first)
        guard case .text(let block) = mark.shape else {
            Issue.record("Expected text annotation")
            return
        }
        #expect(block.string == "Look here")
        #expect(block.look == .label)
        #expect(mark.style.color == .blue)
    }

    @Test func eraserRemovesMultipleMarksInOneUndoableStroke() throws {
        let controller = makeController()
        let view = controller.debugAttachBoard()
        defer { controller.stop() }
        controller.choose(.pen)
        controller.debugDraw(on: 0, from: CGPoint(x: 40, y: 50), to: CGPoint(x: 80, y: 50))
        controller.debugDraw(on: 0, from: CGPoint(x: 120, y: 50), to: CGPoint(x: 160, y: 50))
        #expect(view.marks.count == 2)

        controller.choose(.eraser)
        controller.debugDraw(on: 0, from: CGPoint(x: 30, y: 50), to: CGPoint(x: 170, y: 50))
        #expect(view.marks.isEmpty)

        // One undo snapshot restores both erased marks.
        controller.undo()
        #expect(view.marks.count == 2)
    }

    @Test func captureChipFollowsCallbackAndClickThroughShowsResumeTooltip() {
        let controller = makeController()
        let bar = SketchToolbarView(controller: controller)
        #expect(!bar.debugHasCaptureChip)

        var captured = 0
        controller.onCapture = { captured += 1 }
        bar.refresh()
        #expect(bar.debugHasCaptureChip)
        controller.capture()
        #expect(captured == 1)

        controller.setClicksThrough(true)
        bar.refresh()
        #expect(bar.debugClickThroughTooltip == String(localized: "Click here or press T to resume drawing", bundle: .module))
    }
}
