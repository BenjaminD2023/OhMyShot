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

    /// The pen, arrow, box, oval, and counter show the editor's own symbols and names; the laser has its own.
    @Test func theToolsAreTheEditorsOwn() {
        #expect(ScreenSketchController.Tool.pen.symbol == AnnotationTool.pen.symbol)
        #expect(ScreenSketchController.Tool.counter.name == AnnotationTool.counter.name)
        #expect(ScreenSketchController.Tool.laser.mark == nil)
    }
}
