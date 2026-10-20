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

    @Test func aCompletedResultExpiresAfterThreeSeconds() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 10, hovered: false, voiceOver: false)
        let generation = lifetime.generation
        #expect(lifetime.timeLeft(at: 10) == 3)
        #expect(!lifetime.isDue(at: 12.999, generation: generation))
        #expect(lifetime.isDue(at: 13, generation: generation))
    }

    @Test func hoveringHoldsIndefinitelyAndLeavingRestartsTheWholeInterval() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 0, hovered: false, voiceOver: false)
        let generation = lifetime.generation
        lifetime.setHovered(true, at: 2.9)
        #expect(lifetime.timeLeft(at: 1_000) == nil)
        #expect(!lifetime.isDue(at: 1_000, generation: generation))
        lifetime.setHovered(false, at: 1_000)
        #expect(lifetime.timeLeft(at: 1_000) == 3)
        #expect(!lifetime.isDue(at: 1_002.99, generation: generation))
        #expect(lifetime.isDue(at: 1_003, generation: generation))
    }

    @Test func duplicateExitEventsDoNotKeepExtendingTheCard() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 0, hovered: true, voiceOver: false)
        lifetime.setHovered(true, at: 10)
        lifetime.setHovered(false, at: 20)
        lifetime.setHovered(false, at: 22)
        #expect(lifetime.timeLeft(at: 22) == 1)
        #expect(lifetime.isDue(at: 23, generation: lifetime.generation))
    }

    @Test func anOldTimerCannotCloseANewerResult() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 0, hovered: false, voiceOver: false)
        let oldTimer = lifetime.generation
        lifetime.start(at: 2.9, hovered: false, voiceOver: false)
        #expect(!lifetime.isDue(at: 3, generation: oldTimer))
        #expect(!lifetime.isDue(at: 100, generation: oldTimer))
        #expect(abs((lifetime.timeLeft(at: 3) ?? 0) - 2.9) < 0.0001)
        #expect(lifetime.isDue(at: 5.9, generation: lifetime.generation))
    }

    @Test func closingAHoveredCardDoesNotHoldTheNextResult() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 0, hovered: true, voiceOver: false)
        let oldTimer = lifetime.generation
        lifetime.stop()
        lifetime.setHovered(false, at: 5)
        #expect(lifetime.timeLeft(at: 10) == nil)
        #expect(!lifetime.isDue(at: 10, generation: oldTimer))
        lifetime.start(at: 10, hovered: false, voiceOver: false)
        #expect(lifetime.isDue(at: 13, generation: lifetime.generation))
    }

    @Test func aResultShownUnderAStationaryPointerStartsHeld() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 0, hovered: false, voiceOver: false)
        lifetime.start(at: 2, hovered: true, voiceOver: false)
        #expect(lifetime.timeLeft(at: 100) == nil)
        lifetime.setHovered(false, at: 100)
        #expect(lifetime.timeLeft(at: 100) == 3)
    }

    @Test func theExistingVoiceOverReadingTimeIsPreserved() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 0, hovered: false, voiceOver: true)
        #expect(lifetime.timeLeft(at: 0) == 20)
        lifetime.setHovered(true, at: 19)
        lifetime.setHovered(false, at: 100)
        #expect(lifetime.timeLeft(at: 100) == 20)
    }

    @Test func anEarlyWakeDoesNotExpireTheRemainingUptime() {
        var lifetime = TextResultLifetime()
        lifetime.start(at: 10, hovered: false, voiceOver: false)
        #expect(!lifetime.isDue(at: 10.5, generation: lifetime.generation))
        #expect(lifetime.timeLeft(at: 10.5) == 2.5)
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
