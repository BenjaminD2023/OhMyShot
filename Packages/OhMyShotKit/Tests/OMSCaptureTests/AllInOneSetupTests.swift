import OMSDesign
import AppKit
import OMSCore
import OMSDesign
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
    private func run(_ actions: [String], offersUpload: Bool = true) -> (chose: [(AllInOneChoice, CGRect, Bool)], cancelled: Bool, view: AllInOneSetupView) {
        let view = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: offersUpload)
        var chose: [(AllInOneChoice, CGRect, Bool)] = []
        var cancelled = false
        view.onChoose = { chose.append(($0, $1, $2)) }
        view.onCancel = { cancelled = true }
        for action in actions { _ = view.debugAct(action) }
        return (chose, cancelled, view)
    }

    @Test func returnCapturesTheArea() {
        let result = run(["return"])
        #expect(result.chose.map(\.0) == [.screenshot(nil)])
        #expect(result.chose.first?.1 == Self.area)
    }

    @Test func selectedWindowsKeepRoundedSetupChrome() {
        let front = CGRect(x: 100, y: 200, width: 300, height: 150)
        let back = CGRect(x: 180, y: 260, width: 220, height: 140)
        let view = AllInOneSetupView(
            display: Self.display, area: front.union(back), offersUpload: true, windowFrames: [front, back]
        )
        view.layoutSubtreeIfNeeded()
        let path = view.chrome.selectionPath
        #expect(path != nil)
        let expected = AreaFrame.local(front, on: Self.display).union(AreaFrame.local(back, on: Self.display))
        #expect(path?.boundingBox == expected)
        let localFront = AreaFrame.local(front, on: Self.display)
        #expect(path?.contains(CGPoint(x: localFront.minX, y: localFront.minY)) == false)
        #expect(path?.contains(CGPoint(x: localFront.midX, y: localFront.minY)) == true)
        #expect(view.chrome.showsHandles == false)
    }

    @Test func boundaryNudgeThatLeavesTheAreaUnchangedKeepsWindowChrome() {
        let area = CGRect(x: Self.display.frame.minX, y: Self.area.minY, width: 300, height: 150)
        let view = AllInOneSetupView(display: Self.display, area: area, offersUpload: true, windowFrames: [area])
        #expect(view.chrome.selectionPath != nil)
        _ = view.debugAct("left")
        #expect(view.area.minX == Self.display.frame.minX)
        #expect(view.chrome.selectionPath != nil)
    }

    @Test func overlappingRoundedWindowsUseAUnionCutout() throws {
        let front = CGPath.continuousRoundedRect(CGRect(x: 100, y: 100, width: 200, height: 150), radius: 12)
        let back = CGPath.continuousRoundedRect(CGRect(x: 180, y: 140, width: 180, height: 130), radius: 12)
        let union = try #require(SelectionChromeView.unionPath([front, back]))
        #expect(union.contains(CGPoint(x: 190, y: 150)))
        #expect(union.contains(CGPoint(x: 120, y: 120)))
        #expect(union.contains(CGPoint(x: 340, y: 250)))
        #expect(!union.contains(CGPoint(x: 90, y: 90)))
        let disjoint = CGPath.continuousRoundedRect(CGRect(x: 400, y: 400, width: 80, height: 60), radius: 12)
        let all = try #require(SelectionChromeView.unionPath([front, disjoint]))
        #expect(all.contains(CGPoint(x: 120, y: 120)))
        #expect(all.contains(CGPoint(x: 420, y: 420)))
        #expect(!all.contains(CGPoint(x: 300, y: 300)))
        let single = try #require(SelectionChromeView.unionPath([front]))
        #expect(single.contains(CGPoint(x: 120, y: 120)))
        #expect(!single.contains(CGPoint(x: 90, y: 90)))
        #expect(SelectionChromeView.unionPath([]) == nil)
    }

    @Test func editingSelectedWindowsTurnsTheirOutlineIntoAnAreaFrame() {
        let front = CGRect(x: 100, y: 200, width: 300, height: 150)
        let view = AllInOneSetupView(display: Self.display, area: front, offersUpload: true, windowFrames: [front])
        #expect(view.chrome.selectionPath != nil)
        _ = view.debugAct("right")
        #expect(view.chrome.selectionPath == nil)
        #expect(view.chrome.showsHandles)
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
        #expect(result.chose.first?.2 == true)
        #expect(run(["return"]).chose.first?.2 == false)
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

    @Test func aRatioMatchingTheAreaRefreshesTheChipWithoutLosingWindowChrome() {
        let area = CGRect(x: 100, y: 200, width: 300, height: 200)
        let view = AllInOneSetupView(display: Self.display, area: area, offersUpload: true, windowFrames: [area])
        #expect(view.barSummary == "600 × 400 any")
        #expect(view.chrome.selectionPath != nil)

        _ = view.debugAct("ratio=3:2")

        #expect(view.area == area)
        #expect(view.barSummary == "600 × 400 3:2")
        #expect(view.chrome.selectionPath != nil)
    }

    @Test func offDisplayWindowFramesAreIgnoredInRoundedSetupChrome() {
        let onDisplay = CGRect(x: 100, y: 200, width: 300, height: 150)
        let offDisplay = CGRect(x: 900, y: 200, width: 300, height: 150)
        let view = AllInOneSetupView(
            display: Self.display, area: onDisplay, offersUpload: true, windowFrames: [onDisplay, offDisplay]
        )
        view.layoutSubtreeIfNeeded()
        #expect(view.chrome.selectionPath?.boundingBox == AreaFrame.local(onDisplay, on: Self.display))
        #expect(view.chrome.showsHandles == false)

        let onlyOffDisplay = AllInOneSetupView(
            display: Self.display, area: onDisplay, offersUpload: true, windowFrames: [offDisplay]
        )
        onlyOffDisplay.layoutSubtreeIfNeeded()
        #expect(onlyOffDisplay.chrome.selectionPath == nil)
        #expect(onlyOffDisplay.chrome.showsHandles == true)
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
        view.onChoose = { choice, _, _ in chose.append(choice) }
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
        view.onChoose = { _, area, _ in taken = area }
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

    @Test func deleteBackspaceSpaceAndWLeaveAreaSetup() {
        let cases: [(String, AllInOneSetupView.ExitTarget)] = [
            ("backspace", .area),
            ("delete", .area),
            ("space", .window),
            ("w", .windowPicker),
        ]
        for (action, expected) in cases {
            let view = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: true)
            var chose: [AllInOneChoice] = []
            var exited: [AllInOneSetupView.ExitTarget] = []
            var cancelled = false
            view.onChoose = { choice, _, _ in chose.append(choice) }
            view.onReturnToSelection = { exited.append($0) }
            view.onCancel = { cancelled = true }
            _ = view.debugAct(action)
            #expect(exited == [expected], "\(action)")
            #expect(chose.isEmpty && !cancelled, "\(action)")
        }
    }

    /// While typing a size in the fields, Backspace, Space, and W stay in the field instead of leaving setup.
    @Test func typingInSizeFieldsDoesNotLeaveSetupOnBackspaceSpaceOrW() throws {
        let (view, window, _) = try typing("640")
        var exited: [AllInOneSetupView.ExitTarget] = []
        view.onReturnToSelection = { exited.append($0) }
        #expect(window.firstResponder is NSText)
        _ = view.debugAct("backspace")
        _ = view.debugAct("space")
        _ = view.debugAct("w")
        #expect(exited.isEmpty)
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
        #expect(view.chrome.avoiding == moved)
        #expect(view.chrome.toolbarFrame == moved)
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
        #expect(view.chrome.avoiding.isNull)
        #expect(view.chrome.toolbarFrame.isNull)
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
        #expect(!view.debugBarState.isHidden)
        // The size fields now fit their digits, so a smaller area can shrink the bar; its dragged position stays.
        #expect(view.debugBarState.frame.origin == bar.origin)
        #expect(view.debugBarState.frame.height == bar.height)
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
        view.onChoose = { choice, area, _ in chose.append((choice, area)) }
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

    @Test func sizingControlIgnoresAllInOneExitKeys() {
        let (view, chose, passedOn) = control()
        var exited: [AllInOneSetupView.ExitTarget] = []
        view.onReturnToSelection = { exited.append($0) }
        for key in ["backspace", "delete", "space", "w"] {
            _ = view.debugAct(key)
        }
        #expect(exited.isEmpty && chose().isEmpty && passedOn.keys == 4)
    }

    @Test func annotateSizingBarShowsAnnotateWhileCaptureSizingShowsCapture() {
        let capture = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: false, kind: .sizing, annotates: false)
        let annotate = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: false, kind: .sizing, annotates: true)
        #expect(capture.primaryActionTitle == "Capture")
        #expect(annotate.primaryActionTitle == "Annotate")
    }
}

/// Shared `AreaSetupView` behaviors across All-In-One, Recording, and Scrolling setups (`U-05`, `M-04`, `U-23`).
@MainActor
struct AreaSetupSharedBehaviorTests {
    private static let display = DisplayInfo(
        id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 1600, height: 1200),
        backingScale: 2, maximumPotentialEDR: 1
    )
    private static let area = CGRect(x: 100, y: 200, width: 300, height: 150)

    private func keyEvent(_ keyCode: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
    }

    private func mouseEvent(_ type: NSEvent.EventType, in view: NSView, atFlipped point: CGPoint) throws -> NSEvent {
        let location = view.convert(point, to: nil)
        return try #require(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    /// `U-05`: Pressing Escape or right-clicking during a move or resize adjustment restores the original area
    /// instead of keeping the partial drag; right-clicking while idle cancels setup.
    @Test func escapeAndRightClickRestoreOriginalAreaDuringMoveAndResize() throws {
        let view = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: false)
        var cancelled = 0
        view.onCancel = { cancelled += 1 }
        let localStart = AreaFrame.local(Self.area, on: Self.display)

        // Move drag cancelled with Escape restores `Self.area`.
        let inside = CGPoint(x: localStart.midX, y: localStart.midY)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, atFlipped: inside))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, atFlipped: CGPoint(x: inside.x + 80, y: inside.y + 40)))
        #expect(view.adjustment != nil && view.area != Self.area)
        view.keyDown(with: try keyEvent(53, characters: "\u{1b}"))
        #expect(view.adjustment == nil && view.area == Self.area && cancelled == 0)

        // Resize drag (bottom-right corner) cancelled with right-click restores `Self.area`.
        let corner = CGPoint(x: localStart.maxX, y: localStart.maxY)
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view, atFlipped: corner))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: view, atFlipped: CGPoint(x: corner.x + 60, y: corner.y + 50)))
        #expect(view.adjustment != nil && view.area != Self.area)
        view.rightMouseDown(with: try mouseEvent(.rightMouseDown, in: view, atFlipped: corner))
        #expect(view.adjustment == nil && view.area == Self.area && cancelled == 0)

        // Right-click while not adjusting cancels setup.
        view.rightMouseDown(with: try mouseEvent(.rightMouseDown, in: view, atFlipped: inside))
        #expect(cancelled == 1)
    }

    /// `M-04` + `U-23`: RecordingSetupView supports arrow-key nudge/resize, Tab pixel size editing, and updates
    /// `bar.recordsWindow` when dragging a new area over a `.window` target.
    @Test func recordingSetupSupportsNudgeTabSizingAndWindowToAreaSync() throws {
        let view = RecordingSetupView(display: Self.display, target: .area(Self.area), choices: RecordingChoices())
        let window = NSWindow(contentRect: Self.display.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        window.makeFirstResponder(view)
        view.layoutSubtreeIfNeeded()

        // Arrow-key nudge and Shift/Option variants work via inherited AreaSetupView.nudge.
        view.keyDown(with: try keyEvent(124)) // right (+1 pt)
        #expect(view.target == .area(Self.area.offsetBy(dx: 1, dy: 0)))
        view.keyDown(with: try keyEvent(125, modifiers: .shift)) // shift-down (-10 pt in y-up global space)
        #expect(view.target == .area(Self.area.offsetBy(dx: 1, dy: -10)))
        view.keyDown(with: try keyEvent(124, modifiers: .option)) // option-right (+1 pt width)
        if case .area(let resized) = view.target {
            #expect(resized.width == Self.area.width + 1)
        } else {
            Issue.record("Expected .area target after Option-Right")
        }

        // Tab opens on-demand pixel size capsule and typing sets the area size.
        #expect(!view.isEditingSize)
        view.keyDown(with: try keyEvent(48, characters: "\t"))
        #expect(view.isEditingSize)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("800", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(!view.isEditingSize && window.firstResponder === view)
        if case .area(let typed) = view.target {
            #expect(typed.width == 400)
        } else {
            Issue.record("Expected .area target after typing width")
        }

        // U-23: Starting from a `.window` target and dragging a new area switches `bar.recordsWindow` to false.
        let winTarget = WindowTarget(id: 9, frame: CGRect(x: 100, y: 100, width: 200, height: 200), ownerName: "Safari", title: "Docs")
        let windowSetup = RecordingSetupView(display: Self.display, target: .window(winTarget), choices: RecordingChoices())
        #expect(windowSetup.bar.recordsWindow)
        windowSetup.mouseDown(with: try mouseEvent(.leftMouseDown, in: windowSetup, atFlipped: CGPoint(x: 450, y: 100)))
        windowSetup.mouseDragged(with: try mouseEvent(.leftMouseDragged, in: windowSetup, atFlipped: CGPoint(x: 650, y: 300)))
        windowSetup.mouseUp(with: try mouseEvent(.leftMouseUp, in: windowSetup, atFlipped: CGPoint(x: 650, y: 300)))
        #expect(!windowSetup.bar.recordsWindow)
        if case .area = windowSetup.target {} else {
            Issue.record("Expected target to switch from .window to .area after dragging outside")
        }
    }

    /// `M-04`: ScrollingSetupView supports arrow-key nudge/resize and Tab pixel size editing.
    @Test func scrollingSetupSupportsArrowNudgeAndTabPixelSizing() throws {
        let view = ScrollingSetupView(display: Self.display, area: Self.area)
        let window = NSWindow(contentRect: Self.display.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        window.makeFirstResponder(view)
        view.layoutSubtreeIfNeeded()

        view.keyDown(with: try keyEvent(124))
        #expect(view.area == Self.area.offsetBy(dx: 1, dy: 0))
        view.keyDown(with: try keyEvent(124, modifiers: .option))
        #expect(view.area.width == Self.area.width + 1)

        view.keyDown(with: try keyEvent(48, characters: "\t"))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("640", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(view.area.width == 320 && window.firstResponder === view)
        #expect(view.barSizeSummary.hasPrefix("640 × "))
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

    /// Measure follows Record among All-In-One's modes, which Capture Area's bar leaves out.
    @Test func measureFollowsRecordAmongTheModes() {
        let bar = AllInOneBar()
        bar.showModes(true)
        #expect(bar.shownChoices == [.area, .window, .fullscreen, .text, .scroll, .record, .measure, .cancel])
        bar.showModes(false)
        #expect(bar.shownChoices == [.area, .window, .fullscreen, .cancel])
    }

    /// Area, Window, and Screen name their letters as the modes do; A and F only in All-In-One, where they choose them.
    @Test func theTooltipsNameTheLetters() {
        let bar = AllInOneBar()
        bar.showModes(true)
        bar.usesWindowPreview(true, takesW: true)
        #expect(bar.help(for: .area) == "Drag to capture an area (A)")
        #expect(bar.help(for: .window) == "All Windows (W) · Space selects on screen")
        #expect(bar.help(for: .fullscreen) == "Capture this whole screen (F)")
        #expect(bar.help(for: .text) == "Drag over text to copy it (O)")
        // All-In-One's Text and Scrolling point at a window with W as with Space; the tools on their own take Space.
        bar.usesWindowPreview(false, takesW: true)
        #expect(bar.help(for: .window) == "Click a window to capture it (W or Space)")
        bar.usesWindowPreview(false, takesW: false)
        #expect(bar.help(for: .window) == "Click a window to capture it (Space)")
        bar.showModes(false)
        #expect(bar.help(for: .area) == "Drag to capture an area")
        #expect(bar.help(for: .fullscreen) == "Capture this whole screen")
    }

    @Test func aPurposeIsNeverHowAnAreaIsChosen() {
        let bar = AllInOneBar()
        bar.select(.area)
        bar.select(.text)
        #expect(bar.onChoices == [.area])
    }

    /// The frame looks for codes in the area on a frozen screen, and puts a chip over each, in the frame's points; a
    /// live screen, or Settings saying no, look for none.
    @Test func aFrozenFrameShowsChipsOverTheCodesInItsArea() async throws {
        // A 2× display 800 × 600 points, and an area on it 300 × 150 points.
        let display = DisplayInfo(
            id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 1600, height: 1200),
            backingScale: 2, maximumPotentialEDR: 1
        )
        let area = CGRect(x: 100, y: 200, width: 300, height: 150)
        let context = try #require(CGContext(
            data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        let frame = CapturedFrame(image: try #require(context.makeImage()), hdrImage: nil, displayID: display.id, frame: display.frame)
        let asked = Asked()
        let finder = CodeFinder(isOn: { true }, find: { picture in
            await asked.note(CGSize(width: picture.width, height: picture.height))
            return [FoundCode(payload: "https://example.com", isMatrix: true, box: CGRect(x: 40, y: 20, width: 100, height: 100))]
        })
        for frozen in [true, false] {
            let overlay = OverlayView(display: display)
            defer { overlay.clear() }
            overlay.show(frame, frozen: frozen)
            overlay.enterAnnotation()
            let view = AllInOneSetupView(display: display, area: area, offersUpload: true)
            overlay.addSubview(view)
            view.codeFinder = finder
            view.refreshCodes()
            for _ in 0..<100 where view.codeChips.shownPayloads.isEmpty && frozen {
                try await Task.sleep(for: .milliseconds(10))
            }
            if frozen {
                #expect(view.codeChips.shownPayloads == ["https://example.com"])
                // The area, 300 × 150 points at 2×, is what was looked at; the box comes back in the frame's points:
                // the area's top-left (100, 250 from the display's top) plus half the box's pixels.
                #expect(await asked.sizes.last == CGSize(width: 600, height: 300))
                let chip = try #require(view.codeChips.debugChipFrames.first)
                #expect(chip.midX == 100 + 70 && chip.midY == 250 + 10)
            } else {
                #expect(view.codeChips.shownPayloads.isEmpty)
            }
        }
        #expect(await asked.sizes.count >= 1)
    }

    /// ? in the framed area shows the frame's own keys on the overlay; Escape puts them away without cancelling, and an
    /// arrow puts them away and still moves the area.
    @Test func questionMarkShowsTheFramesKeys() {
        let display = DisplayInfo(
            id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 1600, height: 1200),
            backingScale: 2, maximumPotentialEDR: 1
        )
        let area = CGRect(x: 100, y: 200, width: 300, height: 150)
        let overlay = OverlayView(display: display)
        defer { overlay.clear() }
        let view = AllInOneSetupView(display: display, area: area, offersUpload: false)
        var cancelled = false
        view.onCancel = { cancelled = true }
        overlay.addSubview(view)
        _ = view.debugAct("?")
        #expect(overlay.showsKeys)
        #expect(overlay.debugKeys == Sentences.split(view.accessibilityHelp() ?? "").joined(separator: "\n"))
        _ = view.debugAct("escape")
        #expect(!overlay.showsKeys && !cancelled)
        _ = view.debugAct("?")
        _ = view.debugAct("right")
        #expect(!overlay.showsKeys)
        #expect(view.area == area.offsetBy(dx: 1, dy: 0))
        // Gone with the frame.
        _ = view.debugAct("?")
        view.removeFromSuperview()
        #expect(!overlay.showsKeys)
    }
}

/// The sizes of the pictures a finder was asked about.
private actor Asked {
    var sizes: [CGSize] = []
    func note(_ size: CGSize) { sizes.append(size) }
}
