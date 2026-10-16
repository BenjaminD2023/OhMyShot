import AppKit
import OMSCore
import Testing
@testable import OMSCapture

/// All-In-One's framed area: every way to take it by key, and the arrows that adjust it.
@MainActor
struct AllInOneSetupTests {
    /// A 2× display 800 × 600 points with its bottom-left corner at the origin.
    private static let display = DisplayInfo(
        id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 1600, height: 1200),
        backingScale: 2, maximumPotentialEDR: 1
    )
    private static let area = CGRect(x: 100, y: 200, width: 300, height: 150)

    /// What `actions` chose, in order, and whether one cancelled.
    private func run(_ actions: [String], offersUpload: Bool = true) -> (chose: [(AllInOneChoice, CGRect)], cancelled: Bool, view: AllInOneSetupView) {
        let view = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: offersUpload)
        var chose: [(AllInOneChoice, CGRect)] = []
        var cancelled = false
        view.onChoose = { chose.append(($0, $1)) }
        view.onCancel = { cancelled = true }
        for action in actions { _ = view.debugAct(action) }
        return (chose, cancelled, view)
    }

    @Test func returnCapturesTheArea() {
        let result = run(["return"])
        #expect(result.chose.map(\.0) == [.screenshot(nil)])
        #expect(result.chose.first?.1 == Self.area)
    }

    @Test func commandCAndCommandSCopyAndSave() {
        #expect(run(["cmd-c"]).chose.map(\.0) == [.screenshot(.copy)])
        #expect(run(["cmd-s"]).chose.map(\.0) == [.screenshot(.save)])
    }

    @Test func lettersTakeTheAreaEveryOtherWay() {
        let expected: [String: AllInOneChoice] = [
            "e": .screenshot(.annotate), "p": .screenshot(.pin), "u": .screenshot(.upload), "o": .text, "s": .scroll, "r": .record,
        ]
        for (letter, choice) in expected {
            let result = run([letter])
            #expect(result.chose.map(\.0) == [choice], "\(letter)")
            #expect(result.chose.first?.1 == Self.area, "\(letter)")
        }
    }

    @Test func fTakesTheWholeDisplay() {
        let result = run(["f"])
        #expect(result.chose.map(\.0) == [.screenshot(nil)])
        #expect(result.chose.first?.1 == Self.display.frame)
    }

    @Test func withoutADestinationUploadIsNotOffered() {
        #expect(run(["u"], offersUpload: false).chose.isEmpty)
    }

    /// The arrows move the area a point (y up in global space, so down lowers it), ten with Shift; with Option the
    /// right arrow widens it.
    @Test func theArrowsMoveAndResizeTheArea() {
        #expect(run(["right"]).view.area == Self.area.offsetBy(dx: 1, dy: 0))
        #expect(run(["shift-down"]).view.area == Self.area.offsetBy(dx: 0, dy: -10))
        let widened = run(["opt-right"]).view.area
        #expect(widened.minX == Self.area.minX && widened.width == Self.area.width + 1 && widened.maxY == Self.area.maxY)
    }

    /// A size typed in pixels (the display is 2×) keeps the area's top-left corner.
    @Test func aTypedSizeSetsTheAreaFromItsTopLeft() {
        let view = run(["size=800x400"]).view
        #expect(view.area == CGRect(x: 100, y: 150, width: 400, height: 200))
        #expect(view.barSummary == "800 × 400 any")
    }

    @Test func aShapeKeptReshapesTheAreaAndFollowsATypedWidth() {
        let square = run(["ratio=1:1"]).view
        #expect(square.area == CGRect(x: 100, y: 125, width: 300, height: 300))
        #expect(square.barSummary == "600 × 600 1:1")
        let wide = run(["ratio=16:9", "width=640"]).view
        #expect(wide.area.width == 320 && wide.area.height == 180)
        #expect(wide.barSummary == "640 × 360 16:9")
        let free = run(["ratio=16:9", "ratio=free"]).view
        #expect(free.ratio == nil && free.barSummary.hasSuffix("any"))
    }

    /// Larger than the display, a typed size is cut to it, and a shape kept stays kept.
    @Test func aTypedSizePastTheDisplayStaysOnItInShape() {
        let view = run(["ratio=1:1", "width=4000"]).view
        #expect(Self.display.frame.contains(view.area))
        #expect(view.area.width == view.area.height)
    }

    /// While a size is typed, Command-C is the field's: nothing is captured.
    @Test func commandCWhileTypingIsTheFields() throws {
        let view = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: true)
        var chose: [AllInOneChoice] = []
        view.onChoose = { choice, _ in chose.append(choice) }
        let window = NSWindow(contentRect: Self.display.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        _ = view.debugAct("tab")
        #expect(window.firstResponder is NSText)
        _ = view.debugAct("cmd-c")
        #expect(chose.isEmpty)
    }

    /// A view in an unshown window with a size typed in its width field, not yet set.
    private func typing(_ text: String) throws -> (view: AllInOneSetupView, window: NSWindow, editor: NSTextView) {
        let view = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: true)
        let window = NSWindow(contentRect: Self.display.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        _ = view.debugAct("tab")
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        return (view, window, editor)
    }

    /// Capturing while a width is typed takes the typed width: the click or the key sets it first.
    @Test func capturingWhileTypingTakesTheTypedSize() throws {
        let (view, window, _) = try typing("800")
        var taken: CGRect?
        view.onChoose = { _, area in taken = area }
        _ = view.debugAct("return")
        #expect(taken?.width == 400)
        #expect(window.firstResponder === view)
    }

    /// A width past the display is cut to it, and the field then shows what the area took.
    @Test func aTypedSizeTheAreaCannotTakeShowsWhatItTook() throws {
        let (view, _, _) = try typing("9999")
        _ = view.debugAct("return")
        #expect(view.area.maxX <= Self.display.frame.maxX)
        #expect(view.barSummary.hasPrefix("1600 × "))
    }

    @Test func fullWidthDigitsAreTaken() {
        #expect(AreaSizeFields.digits(in: "１２０0px") == "1200")
    }

    @Test func escapeCancels() {
        let result = run(["escape"])
        #expect(result.cancelled && result.chose.isEmpty)
    }
}

/// The bar before an area: how it is chosen and what it is for are two marks, and the second can be let go.
@MainActor
struct AllInOneBarTests {
    @Test func theWindowAndThePurposeAreMarkedTogether() {
        let bar = AllInOneBar()
        bar.showModes(true)
        bar.select(.window)
        bar.markPurpose(.text)
        #expect(bar.onChoices == [.window, .text])
        bar.select(.area)
        #expect(bar.onChoices == [.area, .text])
        bar.markPurpose(nil)
        #expect(bar.onChoices == [.area])
    }

    @Test func aPurposeIsNeverHowAnAreaIsChosen() {
        let bar = AllInOneBar()
        bar.select(.area)
        bar.select(.text)
        #expect(bar.onChoices == [.area])
    }
}
