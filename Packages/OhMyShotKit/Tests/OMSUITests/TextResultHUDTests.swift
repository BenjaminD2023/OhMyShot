import AppKit
import OMSCore
import Testing
@testable import OMSUI

struct TextResultHUDTests {
    @Test func hoverTracksTheCardAndNotItsTransparentShadowMargin() {
        let card = TextResultCard()
        card.updateTrackingAreas()
        #expect(card.trackingAreas.isEmpty)
        card.frame.size = card.fittingSize(width: 300)
        card.updateTrackingAreas()
        #expect(card.trackingAreas.count == 1)
        #expect(card.trackingAreas.first?.rect == card.bounds.insetBy(dx: TextResultCard.margin, dy: TextResultCard.margin))
    }

    @Test func aCompletedResultExpiresAfterOneSecond() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 10, hovered: false, voiceOver: false)
        let generation = lifetime.generation
        #expect(lifetime.timeLeft(at: 10) == 1)
        #expect(!lifetime.isDue(at: 10.999, generation: generation))
        #expect(lifetime.isDue(at: 11, generation: generation))
    }

    @Test func hoveringHoldsIndefinitelyAndLeavingRestartsTheWholeInterval() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 0, hovered: false, voiceOver: false, closeAfter: 1)
        let generation = lifetime.generation
        lifetime.setHovered(true, at: 0.9)
        #expect(lifetime.timeLeft(at: 1_000) == nil)
        #expect(!lifetime.isDue(at: 1_000, generation: generation))
        lifetime.setHovered(false, at: 1_000)
        #expect(lifetime.timeLeft(at: 1_000) == 1)
        #expect(!lifetime.isDue(at: 1_000.999, generation: generation))
        #expect(lifetime.isDue(at: 1_001, generation: generation))
    }

    @Test func duplicateExitEventsDoNotKeepExtendingTheCard() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 0, hovered: true, voiceOver: false, closeAfter: 1)
        lifetime.setHovered(true, at: 10)
        lifetime.setHovered(false, at: 20)
        lifetime.setHovered(false, at: 20.5)
        #expect(lifetime.timeLeft(at: 20.5) == 0.5)
        #expect(lifetime.isDue(at: 21, generation: lifetime.generation))
    }

    @Test func anOldTimerCannotCloseANewerResult() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 0, hovered: false, voiceOver: false, closeAfter: 1)
        let oldTimer = lifetime.generation
        lifetime.start(at: 0.9, hovered: false, voiceOver: false, closeAfter: 1)
        #expect(!lifetime.isDue(at: 1, generation: oldTimer))
        #expect(!lifetime.isDue(at: 100, generation: oldTimer))
        #expect(abs((lifetime.timeLeft(at: 1) ?? 0) - 0.9) < 0.0001)
        #expect(lifetime.isDue(at: 1.9, generation: lifetime.generation))
    }

    @Test func closingAHoveredCardDoesNotHoldTheNextResult() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 0, hovered: true, voiceOver: false, closeAfter: 1)
        let oldTimer = lifetime.generation
        lifetime.stop()
        lifetime.setHovered(false, at: 5)
        #expect(lifetime.timeLeft(at: 10) == nil)
        #expect(!lifetime.isDue(at: 10, generation: oldTimer))
        lifetime.start(at: 10, hovered: false, voiceOver: false, closeAfter: 1)
        #expect(lifetime.isDue(at: 11, generation: lifetime.generation))
    }

    @Test func aResultShownUnderAStationaryPointerStartsHeld() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 0, hovered: false, voiceOver: false, closeAfter: 1)
        lifetime.start(at: 2, hovered: true, voiceOver: false, closeAfter: 1)
        #expect(lifetime.timeLeft(at: 100) == nil)
        lifetime.setHovered(false, at: 100)
        #expect(lifetime.timeLeft(at: 100) == 1)
    }

    @Test func theExistingVoiceOverReadingTimeIsPreserved() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 0, hovered: false, voiceOver: true, closeAfter: 1)
        #expect(lifetime.timeLeft(at: 0) == 20)
        lifetime.setHovered(true, at: 19)
        lifetime.setHovered(false, at: 100)
        #expect(lifetime.timeLeft(at: 100) == 20)
    }

    @Test func anEarlyWakeDoesNotExpireTheRemainingUptime() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 10, hovered: false, voiceOver: false, closeAfter: 1)
        #expect(!lifetime.isDue(at: 10.5, generation: lifetime.generation))
        #expect(lifetime.timeLeft(at: 10.5) == 0.5)
    }

    @Test func eachConfiguredDelayAndHoverReleaseUseTheChosenInterval() {
        for seconds in [1, 2, 3, 4, 5, 10, 20, 30, 60] as [TimeInterval] {
            var lifetime = TextResultLifetime()
            lifetime.start(at: 10, hovered: false, voiceOver: false, closeAfter: seconds)
            #expect(lifetime.timeLeft(at: 10) == seconds)
            #expect(!lifetime.isDue(at: 10 + seconds - 0.001, generation: lifetime.generation))
            #expect(lifetime.isDue(at: 10 + seconds, generation: lifetime.generation))
            lifetime.setHovered(true, at: 10.5)
            #expect(lifetime.timeLeft(at: 1_000) == nil)
            lifetime.setHovered(false, at: 1_000)
            #expect(lifetime.timeLeft(at: 1_000) == seconds)
        }
    }

    @Test func neverDisablesTheTimerAcrossHoverAndResultReplacement() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 0, hovered: false, voiceOver: false, closeAfter: 1)
        let oldTimer = lifetime.generation
        lifetime.start(at: 0.5, hovered: false, voiceOver: false, closeAfter: 0)
        #expect(!lifetime.isDue(at: 1, generation: oldTimer))
        #expect(lifetime.timeLeft(at: 100_000) == nil)
        lifetime.setHovered(true, at: 2)
        lifetime.setHovered(false, at: 3)
        #expect(!lifetime.isDue(at: 100_000, generation: lifetime.generation))
        lifetime.start(at: 10, hovered: false, voiceOver: false, closeAfter: 1)
        #expect(lifetime.isDue(at: 11, generation: lifetime.generation))
    }

    @Test func voiceOverKeepsLongerUserChoicesAndNever() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 0, hovered: false, voiceOver: true, closeAfter: 30)
        #expect(lifetime.timeLeft(at: 0) == 30)
        lifetime.setHovered(true, at: 29)
        lifetime.setHovered(false, at: 100)
        #expect(lifetime.timeLeft(at: 100) == 30)
        lifetime.start(at: 0, hovered: false, voiceOver: true, closeAfter: 0)
        #expect(lifetime.timeLeft(at: 100_000) == nil)
        #expect(!lifetime.isDue(at: 100_000, generation: lifetime.generation))
    }

    @Test func aCardNobodyAskedForKeepsTheTimeEachStateAlwaysHad() {
        let text = TextResultHUD.State.copied(text: "a", joined: false, canJoin: false)
        #expect(TextResultHUD.closeDelay(for: text, chosen: nil) == 4)
        #expect(TextResultHUD.closeDelay(for: .copiedFormula(latex: "x"), chosen: nil) == 4)
        #expect(TextResultHUD.closeDelay(for: .empty, chosen: nil) == 2.5)
        #expect(TextResultHUD.closeDelay(for: .noFormula, chosen: nil) == 2.5)
        #expect(TextResultHUD.closeDelay(for: .notCopied(text: "a"), chosen: nil) == 10)
    }

    @Test func aChoiceSetsCopiedResultsAndNeverCutsTheCardsThatReportAProblem() {
        let text = TextResultHUD.State.copied(text: "a", joined: false, canJoin: false)
        let problems: [(TextResultHUD.State, TimeInterval)] = [(.empty, 2.5), (.noFormula, 2.5), (.notCopied(text: "a"), 10)]
        for seconds in SettingsStore.textResultCloseDelays where seconds > 0 {
            #expect(TextResultHUD.closeDelay(for: text, chosen: seconds) == TimeInterval(seconds))
            #expect(TextResultHUD.closeDelay(for: .copiedFormula(latex: "x"), chosen: seconds) == TimeInterval(seconds))
            for (state, own) in problems {
                #expect(TextResultHUD.closeDelay(for: state, chosen: seconds) == max(own, TimeInterval(seconds)))
            }
        }
        #expect(TextResultHUD.closeDelay(for: .notCopied(text: "a"), chosen: 1) == 10, "Its Copy is the only way to the text")
        #expect(TextResultHUD.closeDelay(for: .empty, chosen: 1) == 2.5, "The hint must stay readable")
    }

    @Test func neverKeepsEveryCardUntilItIsClosed() {
        let states: [TextResultHUD.State] = [.copied(text: "a", joined: false, canJoin: false), .copiedFormula(latex: "x"), .empty, .noFormula, .notCopied(text: "a")]
        for state in states {
            #expect(TextResultHUD.closeDelay(for: state, chosen: 0) == 0)
        }
    }

    @Test func theOneSecondDefaultIsIndependentOfForcedExplanatoryCards() {
        let text = TextResultHUD.State.copied(text: "a", joined: false, canJoin: false)
        #expect(SettingsStore.defaultTextResultCloseAfter == 1)
        #expect(TextResultHUD.closeDelay(for: text, chosen: SettingsStore.defaultTextResultCloseAfter) == 1)
        #expect(TextResultHUD.closeDelay(for: .copiedFormula(latex: "x"), chosen: SettingsStore.defaultTextResultCloseAfter) == 1)
        #expect(TextResultHUD.closeDelay(for: text, chosen: nil) == 4)
    }

    @Test func defaultPlacementKeepsTheExistingTenPointSelectionGap() {
        let anchor = CGRect(x: 400, y: 400, width: 200, height: 80)
        let frame = TextResultHUD.frame(size: CGSize(width: 368, height: 200), near: anchor,
                                        position: .belowSelection, visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900))
        let card = frame.insetBy(dx: TextResultCard.margin, dy: TextResultCard.margin)
        #expect(card.midX == anchor.midX)
        #expect(card.maxY == anchor.minY - 10)
    }

    @Test func aSelectionAtTheBottomPlacesTheCardAboveIt() {
        let anchor = CGRect(x: 15, y: 10, width: 100, height: 30)
        let frame = TextResultHUD.frame(size: CGSize(width: 368, height: 200), near: anchor,
                                        position: .belowSelection, visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 900))
        let card = frame.insetBy(dx: TextResultCard.margin, dy: TextResultCard.margin)
        #expect(card.minY == anchor.maxY + 10)
        #expect(card.minX >= 8)
    }

    @Test func bottomLeftUsesTheSelectionDisplaysVisibleEdges() {
        let visible = CGRect(x: -1920, y: 140, width: 1920, height: 1000)
        let frame = TextResultHUD.frame(size: CGSize(width: 368, height: 200), near: CGRect(x: -300, y: 800, width: 200, height: 80),
                                        position: .bottomLeft, visibleFrame: visible)
        let card = frame.insetBy(dx: TextResultCard.margin, dy: TextResultCard.margin)
        #expect(card.minX == visible.minX + QuickAccessPlacement.edge)
        #expect(card.minY == visible.minY + QuickAccessPlacement.edge)
    }

    @Test func theBottomLeftCardStandsAboveQuickAccessCardsInItsCorner() {
        let visible = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let cards = CGRect(x: 26, y: 26, width: 300, height: 400)
        let frame = TextResultHUD.frame(size: CGSize(width: 368, height: 200), near: .zero, position: .bottomLeft, visibleFrame: visible, avoiding: cards)
        let card = frame.insetBy(dx: TextResultCard.margin, dy: TextResultCard.margin)
        #expect(card.minY == cards.maxY + 10)
        #expect(card.minX == visible.minX + QuickAccessPlacement.edge)
        #expect(!card.intersects(cards))
    }

    @Test func theBottomLeftCardGoesBesideATallStack() {
        let visible = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let cards = CGRect(x: 26, y: 26, width: 300, height: 800)
        let frame = TextResultHUD.frame(size: CGSize(width: 368, height: 200), near: .zero, position: .bottomLeft, visibleFrame: visible, avoiding: cards)
        let card = frame.insetBy(dx: TextResultCard.margin, dy: TextResultCard.margin)
        #expect(card.minX == cards.maxX + 10)
        #expect(card.minY == visible.minY + QuickAccessPlacement.edge)
        #expect(!card.intersects(cards))
    }

    @Test func theBottomLeftCardStaysInTheCornerWhenNothingStandsThere() {
        let visible = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let size = CGSize(width: 368, height: 200)
        let alone = TextResultHUD.frame(size: size, near: .zero, position: .bottomLeft, visibleFrame: visible)
        let cardsAtTheOtherCorner = CGRect(x: 1274, y: 26, width: 300, height: 400)
        #expect(TextResultHUD.frame(size: size, near: .zero, position: .bottomLeft, visibleFrame: visible, avoiding: cardsAtTheOtherCorner) == alone)
        #expect(TextResultHUD.frame(size: size, near: .zero, position: .bottomLeft, visibleFrame: visible, avoiding: nil) == alone)
        // Below the selection never moves for them.
        let anchor = CGRect(x: 400, y: 400, width: 200, height: 80)
        let below = TextResultHUD.frame(size: size, near: anchor, position: .belowSelection, visibleFrame: visible)
        #expect(TextResultHUD.frame(size: size, near: anchor, position: .belowSelection, visibleFrame: visible, avoiding: CGRect(x: 380, y: 300, width: 300, height: 300)) == below)
    }

    @Test func aPointerAlreadyOverTheCardWhenItsAreaIsMadeCountsAsInside() throws {
        let card = TextResultCard()
        card.frame = CGRect(origin: CGPoint(x: 100, y: 100), size: card.fittingSize(width: 300))
        let window = NSWindow(contentRect: card.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = card
        card.updateTrackingAreas()
        let area = try #require(card.trackingAreas.first)
        // The pointer is wherever the test machine has it: the option must say exactly whether that is over the card.
        let pointer = card.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        #expect(area.options.contains(.assumeInside) == area.rect.contains(pointer))
    }

    @Test func placementKeepsTheCardInsideDockAndMenuBarInsets() {
        let visible = CGRect(x: 0, y: 70, width: 1600, height: 806)
        for position in TextResultPosition.allCases {
            let frame = TextResultHUD.frame(size: CGSize(width: 488, height: 260), near: CGRect(x: 1590, y: 860, width: 20, height: 20),
                                            position: position, visibleFrame: visible)
            let card = frame.insetBy(dx: TextResultCard.margin, dy: TextResultCard.margin)
            #expect(visible.insetBy(dx: 8, dy: 8).contains(card))
        }
    }

    @Test func pointAnchorsAndSpanningSelectionsChooseTheCorrectDisplay() {
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: 100, width: 1920, height: 1080)]
        #expect(TextResultHUD.displayIndex(for: CGRect(x: -1000, y: 300, width: 0, height: 0), frames: frames) == 1)
        #expect(TextResultHUD.displayIndex(for: CGRect(x: -100, y: 400, width: 400, height: 100), frames: frames) == 0)
        #expect(TextResultHUD.displayIndex(for: CGRect(x: 4000, y: 2000, width: 0, height: 0), frames: frames) == nil)
    }
}
