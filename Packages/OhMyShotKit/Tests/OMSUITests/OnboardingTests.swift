import AppKit
import OMSCore
import Testing
@testable import OMSUI

@MainActor
struct OnboardingTests {
    private final class AccessState {
        var granted = false
        var asked = false
        var requests = 0
        var settingsOpened = 0
        var refreshes = 0
        var access: OnboardingWindowController.Access {
            .init(isGranted: { self.granted }, hasAsked: { self.asked }, refresh: { self.refreshes += 1 }, request: {
                self.requests += 1
                self.asked = true
            }, openSettings: { self.settingsOpened += 1 })
        }
    }

    @Test func permissionIsRequestedOnceAndReturningFromSettingsRefreshesIt() async {
        let access = AccessState()
        var steps: [OnboardingProgress.Step] = []
        let model = OnboardingModel(step: .permission, mode: .tour, access: access.access, readHotKeys: { nil }, bindings: { [] }, stepChanged: { steps.append($0) })
        model.next()
        #expect(model.step == .permission && steps.isEmpty)
        await model.requestAccess()
        #expect(access.requests == 1 && access.settingsOpened == 0 && model.hasAsked)
        await model.requestAccess()
        #expect(access.requests == 1 && access.settingsOpened == 1)
        access.granted = true
        model.refresh()
        #expect(model.isGranted)
        model.next()
        #expect(model.step == .shortcuts && steps == [.shortcuts])
    }

    @Test func systemShortcutConflictsRefreshAndDoNotBlockPractice() {
        let access = AccessState()
        access.granted = true
        var hotKeys: [String: Any]?
        let model = OnboardingModel(
            step: .shortcuts, mode: .tour, access: access.access, readHotKeys: { hotKeys },
            bindings: { SystemScreenshotKeys.defaultBindings(for: .release) }, stepChanged: { _ in }
        )
        #expect(model.keysTaken && model.clashes.count == 3)
        model.next()
        #expect(model.step == .capture)
        model.back()
        hotKeys = Dictionary(uniqueKeysWithValues: ["28", "29", "30", "31", "184"].map { ($0, ["enabled": false]) })
        model.refresh()
        #expect(!model.keysTaken)
        model.next()
        #expect(model.step == .capture)
    }

    @Test func keysSplitIntoOneCapPerModifierAndOneForTheKey() {
        #expect(KeyCaps.parts(of: "⇧⌘4") == ["⇧", "⌘", "4"])
        #expect(KeyCaps.parts(of: "⌃⌥⌘F12") == ["⌃", "⌥", "⌘", "F12"])
        #expect(KeyCaps.parts(of: "⌘Space") == ["⌘", "Space"])
        #expect(KeyCaps.parts(of: "⌘") == ["⌘"])
    }

    @Test func theWelcomeMenuShowsTheStatusMenuWithTheCurrentKeys() {
        let access = AccessState()
        let model = OnboardingModel(
            step: .welcome, mode: .tour, access: access.access, readHotKeys: { nil },
            bindings: { SystemScreenshotKeys.defaultBindings(for: .release) }, stepChanged: { _ in }
        )
        #expect(model.menuEntries.map(\.title) == [CaptureShortcut.allInOne, .captureArea, .annotateArea, .pinArea].map(\.title))
        #expect(model.menuEntries[1].keys == "⇧⌘4")
        // The release build leaves Capture Area and Pin without keys.
        #expect(model.menuEntries[3].keys == nil)
    }

    @Test func hintFitsBesideEitherCornerOnItsOwnDisplay() {
        // A secondary display left of the main one, so clamping must not assume an origin of zero.
        let visible = CGRect(x: -1440, y: 40, width: 1440, height: 860)
        let size = CGSize(width: 320, height: 260)
        for x in [visible.minX + 18, visible.maxX - 238] {
            let card = CGRect(x: x, y: 58, width: 220, height: 165)
            let hint = FirstCaptureHintPlacement.frame(size: size, card: card, visible: visible)
            #expect(visible.contains(hint))
            #expect(!hint.intersects(card))
            #expect(hint.size == size)
        }
    }

    @Test func hintMovesAboveTheCardWhenTheDisplayIsNarrow() {
        let visible = CGRect(x: 0, y: 30, width: 520, height: 700)
        let card = CGRect(x: 18, y: 48, width: 220, height: 165)
        let hint = FirstCaptureHintPlacement.frame(size: CGSize(width: 320, height: 250), card: card, visible: visible)
        #expect(visible.contains(hint) && !hint.intersects(card))
        #expect(hint.minY > card.maxY)
    }

    @Test func theHintHasASizeBeforeItsFirstPresentation() {
        for copies in [true, false] {
            for saved in [true, false] {
                let hint = FirstCaptureHintController(captureID: UUID(), isCopied: copies, isSaved: saved, close: {})
                #expect(hint.fittingSize.width == 320)
                #expect(hint.fittingSize.height > 100 && hint.fittingSize.height < 600)
            }
        }
    }

    @Test func aHintHoldsOnlyItsOwnCardAndReleasesWithTheNormalGracePeriod() {
        let practice = UUID(), other = UUID()
        var schedule = CardCloseSchedule()
        schedule.sync(cards: [practice, other], interval: 10, at: 0)
        schedule.hold(.onboarding, for: practice, if: true, at: 9)
        #expect(schedule.takeDue(at: 20) == [other])
        #expect(schedule.takeDue(at: 100).isEmpty)
        schedule.hold(.onboarding, for: practice, if: false, at: 100)
        #expect(schedule.takeDue(at: 103).isEmpty)
        #expect(schedule.takeDue(at: 104) == [practice])
    }
}
