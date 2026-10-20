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

    /// Return in a field sets the typed width and gives the keyboard back to the frame, capturing nothing; the next
    /// Return captures the area at that width.
    @Test func returnInAFieldSetsTheTypedSizeAndTheNextOneCaptures() throws {
        let (view, window, _) = try typing("800")
        var taken: CGRect?
        view.onChoose = { _, area in taken = area }
        _ = view.debugAct("return")
        #expect(taken == nil)
        #expect(view.area.width == 400)
        #expect(window.firstResponder === view)
        _ = view.debugAct("return")
        #expect(taken?.width == 400)
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

    @Test func hidingTheBarCommitsATypedSizeAndReturnsTheKeyboard() throws {
        let (view, window, _) = try typing("800")
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.debugHideBar()
        #expect(view.debugBarState.isHidden)
        #expect(view.area.width == 400)
        #expect(window.firstResponder === view)
        _ = view.debugAct("h")
        #expect(!view.debugBarState.isHidden)
        #expect(view.barSummary.hasPrefix("800 × "))
    }
}

/// Toolbar placement is independent of the framed capture area and survives the area's adjustments.
@MainActor
struct CaptureToolbarSetupTests {
    private static let display = DisplayInfo(
        id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        pixelSize: CGSize(width: 2880, height: 1800), backingScale: 2, maximumPotentialEDR: 1
    )
    private static let area = CGRect(x: 500, y: 300, width: 300, height: 150)

    @Test func aHiddenToolbarStaysHiddenWhenSelectionSetupOpens() {
        let view = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: true, toolbarHidden: true)
        #expect(view.debugBarState.isHidden)
        _ = view.debugAct("h")
        #expect(!view.debugBarState.isHidden)
    }

    @Test func movedToolbarKeepsItsPositionWithoutChangingTheCapture() {
        let view = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: true)
        let initial = view.debugBarState.frame
        view.debugMoveBar(by: CGVector(dx: 20, dy: 30))
        let moved = view.debugBarState.frame
        #expect(moved.origin == CGPoint(x: initial.minX + 20, y: initial.minY - 30))
        #expect(view.area == Self.area)
        _ = view.debugAct("right")
        #expect(view.area == Self.area.offsetBy(dx: 1, dy: 0))
        #expect(view.debugBarState.frame == moved)
        view.debugMoveBar(by: CGVector(dx: 10000, dy: -10000))
        #expect(view.bounds.insetBy(dx: 8, dy: 8).contains(view.debugBarState.frame))
        #expect(view.debugBarState.frame.maxX == view.bounds.maxX - 8)
        #expect(view.debugBarState.frame.maxY == view.bounds.maxY - 8)
        view.debugMoveBar(by: CGVector(dx: -10000, dy: 10000))
        #expect(view.debugBarState.frame.origin == CGPoint(x: 8, y: 8))
    }

    @Test func hiddenToolbarLetsItsFormerAreaBeSelectedAndHRestoresIt() throws {
        let view = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: true)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        view.debugMoveBar(by: CGVector(dx: 20, dy: 0))
        let bar = view.debugBarState.frame
        let start = CGPoint(x: bar.midX, y: bar.midY)
        view.debugHideBar()
        #expect(view.hitTest(start) === view)
        #expect(view.debugBarState.isHidden)
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        view.mouseDown(with: try mouse(.leftMouseDown, at: start))
        let end = CGPoint(x: start.x + 80, y: start.y + 40)
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: end))
        view.mouseUp(with: try mouse(.leftMouseUp, at: end))
        #expect(view.area.size == CGSize(width: 80, height: 40))
        #expect(view.debugBarState.isHidden)
        _ = view.debugAct("h")
        #expect(!view.debugBarState.isHidden && view.debugBarState.frame == bar)
    }

    @Test func movingTheGripReportsWindowDeltasAndEndsWithACursorRefresh() throws {
        let handle = CaptureBarHandle()
        let image = try #require(handle.subviews.compactMap { $0 as? NSImageView }.first?.image)
        #expect(image.size.width > 0 && image.size.height > 0)
        var moves: [(CGVector, CGPoint, Bool)] = []
        handle.onMove = { moves.append(($0, $1, handle.isDragging)) }
        defer { handle.onMove = nil }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        handle.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 10, y: 20)))
        handle.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: 35, y: 50)))
        handle.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 35, y: 50)))
        #expect(moves.count == 3)
        let movement = try #require(moves.dropFirst().first)
        #expect(movement.0 == CGVector(dx: 25, dy: 30) && movement.1 == CGPoint(x: 35, y: 50))
        #expect(movement.2 && !handle.isDragging)
        #expect(moves.last?.0 == .zero && moves.last?.2 == false)
    }
}

/// Capture Area's size control: All-In-One's frame with only Capture, the size, and the shape on its bar.
@MainActor
struct AreaSizeControlTests {
    private static let display = DisplayInfo(
        id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 1600, height: 1200),
        backingScale: 2, maximumPotentialEDR: 1
    )
    private static let area = CGRect(x: 100, y: 200, width: 300, height: 150)

    /// Takes the keys the frame passes on, so none reaches the end of the chain and beeps.
    private final class PassedOn: NSResponder {
        var keys = 0

        override func keyDown(with event: NSEvent) {
            keys += 1
        }
    }

    private func control(ratio: AspectRatio? = nil) -> (view: AllInOneSetupView, chose: () -> [(AllInOneChoice, CGRect)], passedOn: PassedOn) {
        let view = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: false, kind: .sizing, ratio: ratio)
        let passedOn = PassedOn()
        view.nextResponder = passedOn
        var chose: [(AllInOneChoice, CGRect)] = []
        view.onChoose = { chose.append(($0, $1)) }
        return (view, { chose }, passedOn)
    }

    @Test func itsBarOffersCaptureAlone() {
        let sizing = control().view
        #expect(sizing.barChoiceCount == 1)
        let allInOne = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: false)
        #expect(allInOne.barChoiceCount > 5)
    }

    @Test func returnCapturesTheAreaAsItIs() {
        let (view, chose, _) = control()
        _ = view.debugAct("return")
        #expect(chose().map(\.0) == [.screenshot(nil)] && chose().first?.1 == Self.area)
    }

    /// The letters and Command-C and -S take an area every other way; here they do nothing but pass on.
    @Test func allInOnesOtherKeysAreNotItsOwn() {
        let (view, chose, passedOn) = control()
        for key in ["e", "p", "u", "o", "s", "r", "f", "cmd-c", "cmd-s"] {
            _ = view.debugAct(key)
        }
        #expect(chose().isEmpty)
        #expect(passedOn.keys == 7)
        #expect(view.area == Self.area)
    }

    @Test func theArrowsMoveAndResizeItAsAllInOnesDo() {
        let (view, _, _) = control()
        _ = view.debugAct("right")
        #expect(view.area == Self.area.offsetBy(dx: 1, dy: 0))
        _ = view.debugAct("opt-right")
        #expect(view.area.width == Self.area.width + 1)
    }

    /// A shape kept when it opens shows on the bar, is not forced on the area, and holds a typed width.
    @Test func aShapeKeptShowsAndHoldsATypedWidth() {
        let (view, _, _) = control(ratio: AspectRatio(width: 16, height: 9))
        #expect(view.ratio == AspectRatio(width: 16, height: 9))
        #expect(view.area == Self.area)
        #expect(view.barSummary == "600 × 300 16:9")
        _ = view.debugAct("width=640")
        #expect(view.barSummary == "640 × 360 16:9")
        #expect(view.area.width == 320 && view.area.height == 180)
    }

    @Test func aSizeTypedOnItsOwnLeavesTheShapeFree() {
        let (view, _, _) = control()
        #expect(view.barSummary == "600 × 300 any")
        _ = view.debugAct("size=800x400")
        #expect(view.area.size == CGSize(width: 400, height: 200))
        #expect(view.ratio == nil)
    }

    /// A key as the window delivers it to its first responder.
    private func send(_ keyCode: UInt16, _ characters: String, to window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
        try #require(window.firstResponder).keyDown(with: event)
    }

    /// The frame, in a window that is never shown, with the keyboard as Capture Area gives it.
    private func opened() -> (view: AllInOneSetupView, window: NSWindow, chose: () -> [(AllInOneChoice, CGRect)]) {
        let (view, chose, _) = control()
        let window = NSWindow(contentRect: Self.display.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        window.makeFirstResponder(view)
        return (view, window, chose)
    }

    /// Opened from Capture Area, the keyboard stays with the frame, so Return captures at once, as the drag would have.
    @Test func theKeysStayWithTheFrameWhenItOpens() throws {
        let (view, window, chose) = opened()
        #expect(window.firstResponder === view)
        try send(36, "\r", to: window)
        #expect(chose().map(\.0) == [.screenshot(nil)] && chose().first?.1 == Self.area)
    }

    @Test func escapeCancelsAtOnce() throws {
        let (view, window, _) = opened()
        var cancelled = false
        view.onCancel = { cancelled = true }
        try send(53, "\u{1b}", to: window)
        #expect(cancelled)
    }

    /// Tab goes to the width to type it. Return there sets the size typed and gives the keys back to the frame; the next
    /// Return captures what was typed.
    @Test func tabGoesToTheWidthAndReturnThereOnlySetsTheSize() throws {
        let (view, window, chose) = opened()
        try send(48, "\t", to: window)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("800", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(chose().isEmpty && window.firstResponder === view)
        #expect(view.area.width == 400 && view.area.height == Self.area.height)
        try send(36, "\r", to: window)
        #expect(chose().map(\.0) == [.screenshot(nil)] && chose().first?.1.width == 400)
    }

    /// A shape chosen on the chip is the one Shift keeps from now on; Any Shape leaves what Shift keeps alone.
    @Test func aShapeChosenOnTheChipIsTheOneShiftKeeps() {
        let (view, _, _) = control()
        var kept: [AspectRatio] = []
        view.onShapeKept = { kept.append($0) }
        _ = view.debugAct("ratio=16:9")
        _ = view.debugAct("ratio=any")
        _ = view.debugAct("ratio=1:1")
        #expect(kept == [AspectRatio(width: 16, height: 9), .square])
        // All-In-One's own chip keeps a shape for its area alone.
        let allInOne = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: false)
        allInOne.onShapeKept = { kept.append($0) }
        _ = allInOne.debugAct("ratio=4:3")
        #expect(kept.count == 2)
    }

    @Test func escapeCancels() {
        let view = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: false, kind: .sizing)
        var cancelled = false
        view.onCancel = { cancelled = true }
        _ = view.debugAct("escape")
        #expect(cancelled)
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
