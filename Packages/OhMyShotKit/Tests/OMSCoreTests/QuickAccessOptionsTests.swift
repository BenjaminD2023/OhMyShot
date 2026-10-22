import CoreGraphics
import Foundation
import Testing
@testable import OMSCore

/// How Quick Access cards are sized and placed, and what Settings keeps about them.
struct QuickAccessOptionsTests {
    @Test func mediumIsTodaysCard() {
        #expect(QuickAccessSize.medium.cardWidth == CardPicture.width)
        #expect(QuickAccessSize.medium.tallest == CardPicture.tallest)
    }

    @Test func theSizesScaleTheCardAndItsTallestTogether() {
        #expect(QuickAccessSize.small.cardWidth == 180 && QuickAccessSize.small.tallest == 141)
        #expect(QuickAccessSize.large.cardWidth == 260 && QuickAccessSize.large.tallest == 203)
    }

    @Test func aCardIsAsTallAsItsPictureWithinTheBounds() {
        // 4:3 at 220 is 165; a wide screen shot is cut at the shortest; a tall one at the tallest.
        #expect(QuickAccessSize.medium.cardHeight(pixelWidth: 800, pixelHeight: 600) == 165)
        #expect(QuickAccessSize.medium.cardHeight(pixelWidth: 3440, pixelHeight: 1440) == 100)
        #expect(QuickAccessSize.medium.cardHeight(pixelWidth: 600, pixelHeight: 1200) == 172)
        #expect(QuickAccessSize.small.cardHeight(pixelWidth: 1000, pixelHeight: 1000) == 141)
        #expect(QuickAccessSize.large.cardHeight(pixelWidth: 800, pixelHeight: 600) == 195)
        #expect(QuickAccessSize.large.cardHeight(pixelWidth: 4000, pixelHeight: 100) == 100)
    }

    @Test func theCardsStandInTheChosenCorner() {
        let visible = CGRect(x: 0, y: 23, width: 1440, height: 877)
        let margin: CGFloat = 34
        let width: CGFloat = 220 + margin * 2
        let left = QuickAccessPlacement.panelFrame(corner: .bottomLeft, visible: visible, panelWidth: width, panelHeight: 300, margin: margin)
        let right = QuickAccessPlacement.panelFrame(corner: .bottomRight, visible: visible, panelWidth: width, panelHeight: 300, margin: margin)
        // The cards, inside the panel's margin, are 26 pt from the side and from the bottom.
        #expect(left.minX + margin == visible.minX + QuickAccessPlacement.edge)
        #expect(right.maxX - margin == visible.maxX - QuickAccessPlacement.edge)
        #expect(left.minY + margin == visible.minY + QuickAccessPlacement.edge)
        #expect(right.minY == left.minY)
        #expect(left.width == width && right.height == 300)
    }

    @Test func aStackIsNoTallerThanTheDisplayLessItsEdges() {
        #expect(QuickAccessPlacement.tallestStack(visible: CGRect(x: 0, y: 0, width: 1000, height: 800)) == 748)
    }

    @Test func theStackFollowsThePointerOnlyWhenAskedTo() {
        #expect(QuickAccessPlacement.display(forCaptureOn: 1, pointerOn: 2, followsPointer: false) == 1)
        #expect(QuickAccessPlacement.display(forCaptureOn: 1, pointerOn: 2, followsPointer: true) == 2)
        // A pointer that is on no display leaves it where the capture was taken.
        #expect(QuickAccessPlacement.display(forCaptureOn: 1, pointerOn: nil, followsPointer: true) == 1)
    }
}

/// Where the small buttons of a card stand.
struct CardControlLayoutTests {
    @Test func aColumnHoldsAsManyButtonsAsTheCardIsTallEnoughFor() {
        #expect(CardControlLayout.rows(height: 60) == 0)
        #expect(CardControlLayout.rows(height: 80) == 1)
        #expect(CardControlLayout.rows(height: 100) == 2)
        #expect(CardControlLayout.rows(height: 130) == 3)
        #expect(CardControlLayout.rows(height: 172) == 4)
        #expect(CardControlLayout.rows(height: 100, reserve: 24) == 1)
    }

    private let screenshot: [CardControlLayout.Extra] = [.annotate, .pin, .upload, .recognizeText, .trash]

    /// An upload that starts or ends takes Upload away or brings it back, and no other button moves: a click aimed at
    /// Recognize Text or Trash lands where it was aimed.
    @Test func uploadComingOrGoingMovesNoOtherButton() {
        let with = CardControlLayout.slots(for: screenshot, onRecording: false, height: 172)
        let without = CardControlLayout.slots(for: screenshot.filter { $0 != .upload }, onRecording: false, height: 172)
        #expect(with.enumerated().filter { screenshot[$0.offset] != .upload }.map(\.element) == without)
        #expect(without == [.init(side: .leading, row: 0), .init(side: .leading, row: 1), .init(side: .trailing, row: 0), .init(side: .trailing, row: 1)])
    }

    @Test func trashIsNeverBesideClose() {
        for height in stride(from: CGFloat(100), through: 203, by: 1) {
            for onRecording in [false, true] {
                let slots = CardControlLayout.slots(for: [.trash], onRecording: onRecording, height: height, leadingReserve: onRecording ? 24 : 0)
                #expect(slots[0] != CardControlLayout.Slot(side: .leading, row: 0))
            }
        }
    }

    /// A 100 pt card has two places a side: Upload, last on its side, goes to the menu.
    @Test func aCardTooShortForAButtonsPlaceLeavesItToTheMenu() {
        let slots = CardControlLayout.slots(for: screenshot, onRecording: false, height: 100)
        #expect(slots.compactMap(\.self).count == 4)
        #expect(slots[2] == nil)
        #expect(CardControlLayout.slots(for: screenshot, onRecording: false, height: 130).allSatisfy { $0 != nil })
    }

    /// A recording's leading column stops above its length badge.
    @Test func aReservedLeadingColumnTakesFewerButtons() {
        let short = CardControlLayout.slots(for: [.annotate, .upload, .trash], onRecording: true, height: 100, leadingReserve: 24)
        #expect(short == [.init(side: .leading, row: 0), nil, .init(side: .trailing, row: 0)])
        let tall = CardControlLayout.slots(for: [.annotate, .upload, .trash], onRecording: true, height: 130, leadingReserve: 24)
        #expect(tall[1] == .init(side: .leading, row: 1))
    }

    @Test func slotsLieUnderTheCornerButtonsAtTheCardsSides() {
        let first = CardControlLayout.Slot(side: .leading, row: 0)
        let second = CardControlLayout.Slot(side: .trailing, row: 1)
        // 8 pt in, a 24 pt corner button and a 6 pt gap above the first row.
        #expect(CardControlLayout.top(of: first) == 38)
        #expect(CardControlLayout.top(of: second) == 68)
        #expect(CardControlLayout.left(of: first, width: 220) == 8)
        #expect(CardControlLayout.left(of: second, width: 220) == 188)
        // The last row ends 8 pt above the bottom of the shortest card.
        #expect(CardControlLayout.top(of: second) + CardControlLayout.buttonSize <= QuickAccessSize.shortest - CardControlLayout.inset)
    }
}

@MainActor
struct QuickAccessSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "OMSCoreTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test func cardsKeepTodaysLookAndStayUntilClosed() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SettingsStore(defaults: defaults).quickAccessPreferences
        #expect(preferences == QuickAccessPreferences())
        #expect(preferences.corner == .bottomLeft && preferences.size == .medium)
        #expect(!preferences.onPointerDisplay)
        #expect(preferences.closeInterval == nil && preferences.closeAction == .close)
    }

    @Test func theChoicesAreKept() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.quickAccessCorner = .bottomRight
        settings.quickAccessSize = .large
        settings.quickAccessOnPointerDisplay = true
        settings.quickAccessCloseAfter = 20
        settings.quickAccessCloseAction = .saveAndClose
        let kept = SettingsStore(defaults: defaults).quickAccessPreferences
        #expect(kept == QuickAccessPreferences(corner: .bottomRight, size: .large, onPointerDisplay: true, closeAfter: 20, closeAction: .saveAndClose))
        #expect(kept.closeInterval == 20)
    }

    @Test func shortDelaysAreChoicesAndNeverStaysTheDefault() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SettingsStore.quickAccessCloseDelays == [0, 1, 2, 3, 5, 10, 20, 30, 60])
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.quickAccessCloseAfter == 0)
        settings.quickAccessCloseAfter = 3
        #expect(SettingsStore(defaults: defaults).quickAccessPreferences.closeInterval == 3)
    }

    @Test(arguments: [0, 1, 2, 3, 5, 10, 20, 30, 60])
    func everyOfferedDelaySurvivesRelaunch(seconds: Int) throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.quickAccessCloseAfter = seconds
        let restored = SettingsStore(defaults: defaults)
        #expect(restored.quickAccessCloseAfter == seconds)
        #expect(restored.quickAccessPreferences.closeInterval == (seconds == 0 ? nil : TimeInterval(seconds)))
    }

    @Test func screenshotCardDelayAndTextToolPreferencesAreIndependent() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.showTextResult = true
        settings.textRecognitionWrapsText = false
        settings.quickAccessCloseAfter = 1
        let restored = SettingsStore(defaults: defaults)
        #expect(restored.quickAccessCloseAfter == 1)
        #expect(restored.showTextResult)
        #expect(!restored.textRecognitionWrapsText)
        restored.showTextResult = false
        restored.textRecognitionWrapsText = true
        #expect(SettingsStore(defaults: defaults).quickAccessCloseAfter == 1)
    }

    @Test func closingTakesAnUnsavedCaptureOnlyWithHistoryOffAndTimedCloseOn() {
        let closes = QuickAccessPreferences(closeAfter: 10, closeAction: .close)
        #expect(closes.closingDiscardsUnsavedCaptures(history: .never))
        #expect(!closes.closingDiscardsUnsavedCaptures(history: .oneDay))
        #expect(!closes.closingDiscardsUnsavedCaptures(history: .oneWeek))
        // Saving first keeps a copy, and cards that stay until closed are the person's to close.
        #expect(!QuickAccessPreferences(closeAfter: 10, closeAction: .saveAndClose).closingDiscardsUnsavedCaptures(history: .never))
        #expect(!QuickAccessPreferences(closeAfter: 0, closeAction: .close).closingDiscardsUnsavedCaptures(history: .never))
        // Today's cards, as they are by default.
        #expect(!QuickAccessPreferences().closingDiscardsUnsavedCaptures(history: .never))
    }

    @Test func aDelaySettingsDoesNotOfferFallsBackToNever() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(7, forKey: "quickAccessCloseAfter")
        defaults.set("middle", forKey: "quickAccessCorner")
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.quickAccessCloseAfter == 0)
        #expect(settings.quickAccessCorner == .bottomLeft)
        #expect(SettingsStore.quickAccessCloseDelays.first == 0)
    }
}
