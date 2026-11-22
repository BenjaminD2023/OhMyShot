import AppKit
import OMSCore
import Testing
@testable import OMSCapture

/// B on a framed area: fitted to the edges of what it holds on a frozen screen, and put back by B again or ⌘Z.
@MainActor
struct AreaFitTests {
    /// A 2× display 800 × 600 points with its bottom-left corner at the origin.
    private static let display = DisplayInfo(
        id: 1, name: "Test", frame: CGRect(x: 0, y: 0, width: 800, height: 600), pixelSize: CGSize(width: 1600, height: 1200),
        backingScale: 2, maximumPotentialEDR: 1
    )
    /// A dark card 100 × 60 points on the white screen, in global points.
    private static let card = CGRect(x: 150, y: 260, width: 100, height: 60)
    /// An area around the card: 600 × 300 pixels, small enough to be looked at at once.
    private static let area = CGRect(x: 100, y: 200, width: 300, height: 150)

    /// The frozen screen: white, with `card` (global points) in near black.
    private static func frame(card: CGRect = card) throws -> CapturedFrame {
        let context = try #require(CGContext(
            data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        // The context is y up from the display's bottom-left corner, as global space is here, at 2 pixels a point.
        context.setFillColor(CGColor(gray: 0.15, alpha: 1))
        context.fill(CGRect(x: card.minX * 2, y: card.minY * 2, width: card.width * 2, height: card.height * 2))
        return CapturedFrame(image: try #require(context.makeImage()), hdrImage: nil, displayID: display.id, frame: display.frame)
    }

    /// A frame of `area` on an overlay showing `frame`, held still unless `frozen` is false.
    private func setup(
        area: CGRect = area, frame: CapturedFrame, frozen: Bool = true, kind: AllInOneSetupView.Kind = .allInOne, ratio: AspectRatio? = nil
    ) -> (overlay: OverlayView, view: AllInOneSetupView) {
        let overlay = OverlayView(display: Self.display)
        overlay.show(frame, frozen: frozen)
        let view = AllInOneSetupView(display: Self.display, area: area, offersUpload: false, kind: kind, ratio: ratio)
        overlay.addSubview(view)
        return (overlay, view)
    }

    private func waitForFit(_ view: AllInOneSetupView) async throws {
        for _ in 0..<500 where view.isFittingToContent {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!view.isFittingToContent)
    }

    @Test func bFitsAFrozenAreaToWhatItHoldsAndBAgainPutsItBack() throws {
        let (overlay, view) = setup(frame: try Self.frame())
        defer { overlay.clear() }
        _ = view.debugAct("b")
        #expect(view.area == Self.card)
        _ = view.debugAct("b")
        #expect(view.area == Self.area)
        // And again: a fit put back can be made once more.
        _ = view.debugAct("b")
        #expect(view.area == Self.card)
    }

    @Test func commandZPutsBackTheAreaAsDrawnOnce() throws {
        let (overlay, view) = setup(frame: try Self.frame())
        defer { overlay.clear() }
        _ = view.debugAct("b")
        _ = view.debugAct("cmd-z")
        #expect(view.area == Self.area)
        // Nothing is left to put back: the area stays.
        _ = view.debugAct("cmd-z")
        #expect(view.area == Self.area)
    }

    /// Moved or resized after the fit, the area is the person's own again: ⌘Z leaves it, and B looks at it anew rather
    /// than putting back the area drawn before.
    @Test func anAreaChangedAfterTheFitIsNotPutBack() throws {
        let (overlay, view) = setup(frame: try Self.frame())
        defer { overlay.clear() }
        _ = view.debugAct("b")
        _ = view.debugAct("opt-right")
        let resized = CGRect(x: Self.card.minX, y: Self.card.minY, width: Self.card.width + 1, height: Self.card.height)
        #expect(view.area == resized)
        _ = view.debugAct("cmd-z")
        #expect(view.area == resized)
        _ = view.debugAct("b")
        #expect(view.area != Self.area)
    }

    /// The live screen has no frame to read: B changes nothing, and the help doesn't name it.
    @Test func aLiveScreenHasNothingToFitAndItsHelpLeavesBOut() throws {
        let frozen = setup(frame: try Self.frame())
        defer { frozen.overlay.clear() }
        frozen.view.begin()
        #expect(frozen.view.accessibilityHelp()?.hasSuffix(AllInOneSetupView.fitHelp) == true)

        let live = setup(frame: try Self.frame(), frozen: false)
        defer { live.overlay.clear() }
        live.view.begin()
        #expect(live.view.accessibilityHelp()?.contains(AllInOneSetupView.fitHelp) == false)
        _ = live.view.debugAct("b")
        #expect(live.view.area == Self.area)
    }

    /// Nudged away and back to where the fit left it, the area was still changed by the person: ⌘Z leaves it.
    @Test func anAreaMovedAwayAndBackIsNotPutBack() throws {
        let (overlay, view) = setup(frame: try Self.frame())
        defer { overlay.clear() }
        _ = view.debugAct("b")
        _ = view.debugAct("left")
        _ = view.debugAct("right")
        #expect(view.area == Self.card)
        _ = view.debugAct("cmd-z")
        #expect(view.area == Self.card)
    }

    /// A remembered area on another display starts before that display's frame arrives: B joins the help with it.
    @Test func theHelpNamesBOnceTheFrozenFrameArrives() throws {
        let overlay = OverlayView(display: Self.display)
        defer { overlay.clear() }
        let view = AllInOneSetupView(display: Self.display, area: Self.area, offersUpload: false)
        overlay.addSubview(view)
        view.begin()
        #expect(view.accessibilityHelp()?.contains(AllInOneSetupView.fitHelp) == false)
        overlay.show(try Self.frame(), frozen: true)
        #expect(view.accessibilityHelp()?.hasSuffix(AllInOneSetupView.fitHelp) == true)
    }

    /// The fit stays inside the area framed: off center in a kept square, the square is moved in from the frame's edge
    /// rather than reaching past it.
    @Test func aFitNeverReachesPastTheAreaFramed() throws {
        let post = CGRect(x: 110, y: 210, width: 20, height: 80)
        let square = CGRect(x: 100, y: 200, width: 100, height: 100)
        let (overlay, view) = setup(area: square, frame: try Self.frame(card: post), kind: .sizing, ratio: AspectRatio(width: 1, height: 1))
        defer { overlay.clear() }
        _ = view.debugAct("b")
        #expect(view.area == CGRect(x: 100, y: 210, width: 80, height: 80))
    }

    /// An area framed smaller than the smallest area has no fit that stays inside it.
    @Test func anAreaSmallerThanTheSmallestStaysAsDrawn() throws {
        let dot = CGRect(x: 200, y: 280, width: 6, height: 6)
        let tight = CGRect(x: 195, y: 275, width: 14, height: 14)
        let (overlay, view) = setup(area: tight, frame: try Self.frame(card: dot))
        defer { overlay.clear() }
        _ = view.debugAct("b")
        #expect(view.area == tight)
    }

    /// ⌘Z goes to the frame as a key equivalent, past the keys ? showed: they go as it puts the area back.
    @Test func commandZPutsTheKeysAwayAsItPutsTheAreaBack() throws {
        let (overlay, view) = setup(frame: try Self.frame())
        defer { overlay.clear() }
        _ = view.debugAct("b")
        overlay.toggleKeys(view.accessibilityHelp() ?? "")
        #expect(overlay.showsKeys)
        let undo = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "z",
            charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6
        ))
        #expect(overlay.performKeyEquivalent(with: undo))
        #expect(!overlay.showsKeys && view.area == Self.area)
    }

    @Test func anAreaWithNoEdgesInsideStaysAsDrawn() throws {
        let blank = CGRect(x: 450, y: 100, width: 200, height: 100)
        let (overlay, view) = setup(area: blank, frame: try Self.frame())
        defer { overlay.clear() }
        _ = view.debugAct("b")
        #expect(view.area == blank)
        // No fit stands, so ⌘Z has nothing to put back either.
        _ = view.debugAct("cmd-z")
        #expect(view.area == blank)
    }

    /// Capture Area's size control fits too, keeping the shape it keeps: the least square that holds the card, centered
    /// on it.
    @Test func aKeptShapeHoldsAroundTheContent() throws {
        let square = CGRect(x: 130, y: 210, width: 160, height: 160)
        let (overlay, view) = setup(area: square, frame: try Self.frame(), kind: .sizing, ratio: AspectRatio(width: 1, height: 1))
        defer { overlay.clear() }
        _ = view.debugAct("b")
        #expect(view.area == CGRect(x: Self.card.minX, y: Self.card.midY - 50, width: 100, height: 100))
        _ = view.debugAct("b")
        #expect(view.area == square)
    }

    /// Something smaller than the smallest area is fitted with the smallest area, centered on it.
    @Test func smallContentGetsTheSmallestArea() throws {
        let dot = CGRect(x: 200, y: 280, width: 6, height: 6)
        let (overlay, view) = setup(frame: try Self.frame(card: dot))
        defer { overlay.clear() }
        _ = view.debugAct("b")
        #expect(view.area == CGRect(x: dot.midX - 8, y: dot.midY - 8, width: 16, height: 16))
    }

    /// An area over 250,000 pixels is looked at in the background; the keys stay with the frame meanwhile.
    @Test func aLargeAreaFitsInTheBackground() async throws {
        let large = CGRect(x: 50, y: 50, width: 700, height: 500)
        let (overlay, view) = setup(area: large, frame: try Self.frame())
        defer { overlay.clear() }
        _ = view.debugAct("b")
        #expect(view.isFittingToContent)
        #expect(view.area == large)
        try await waitForFit(view)
        #expect(view.area == Self.card)
        _ = view.debugAct("cmd-z")
        #expect(view.area == large)
    }

    /// Moving the area while its edges are looked for drops what is found: the area stays where it was moved.
    @Test func movingTheAreaDropsALookStillGoingOn() async throws {
        let large = CGRect(x: 50, y: 50, width: 700, height: 500)
        let (overlay, view) = setup(area: large, frame: try Self.frame())
        defer { overlay.clear() }
        _ = view.debugAct("b")
        _ = view.debugAct("left")
        #expect(!view.isFittingToContent)
        let moved = large.offsetBy(dx: -1, dy: 0)
        try await Task.sleep(for: .milliseconds(400))
        #expect(view.area == moved)
        _ = view.debugAct("cmd-z")
        #expect(view.area == moved)
    }

    /// Locking a ratio that already matches the fitted area still clears fit undo so ⌘Z/B cannot restore a pre-fit
    /// rectangle with a different aspect ratio.
    @Test func lockingTheFittedAreasCurrentRatioClearsFitUndo() throws {
        let fittedCard = CGRect(x: 150, y: 230, width: 150, height: 100) // 3:2 inside 300 × 150 (2:1)
        let (overlay, view) = setup(frame: try Self.frame(card: fittedCard))
        defer { overlay.clear() }
        _ = view.debugAct("b")
        #expect(view.area == fittedCard)
        _ = view.debugAct("ratio=3:2")
        #expect(view.area == fittedCard)
        _ = view.debugAct("cmd-z")
        #expect(view.area == fittedCard)
        _ = view.debugAct("b")
        #expect(view.area == fittedCard)
    }

    /// An ordinary no-op geometry update (such as a typed width clamped back to the minimum fitted width) preserves fit
    /// undo so ⌘Z still restores the area as drawn.
    @Test func anUnchangedClampedTypedWidthKeepsFitUndo() throws {
        let dot = CGRect(x: 200, y: 280, width: 6, height: 6)
        let (overlay, view) = setup(frame: try Self.frame(card: dot))
        defer { overlay.clear() }
        _ = view.debugAct("b")
        let smallest = CGRect(x: dot.midX - 8, y: dot.midY - 8, width: 16, height: 16)
        #expect(view.area == smallest)
        // On a 2× display, 16 pt is 32 px; typing 30 px clamps back to 32 px without changing the area.
        _ = view.debugAct("width=30")
        #expect(view.area == smallest)
        _ = view.debugAct("cmd-z")
        #expect(view.area == Self.area)
    }
}
