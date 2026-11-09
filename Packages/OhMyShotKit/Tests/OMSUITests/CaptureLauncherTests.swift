import AppKit
import Testing
@testable import OMSUI

@MainActor
struct CaptureLauncherTests {
    private func model(_ captures: [StatusItemController.Entry]) -> CaptureLauncherModel {
        CaptureLauncherModel(captureEntries: captures, textEntries: [], pinEntries: [], historyEntries: [],
                             priorityEntries: [], appEntries: [], debugEntries: [], openGuide: nil,
                             openSettings: {}, quit: {})
    }

    @Test func everyQuickActionHasAShippedSymbol() {
        for shortcut in CaptureLauncherModel.quickActions {
            #expect(NSImage(systemSymbolName: CaptureLauncherModel.symbol(for: shortcut), accessibilityDescription: nil) != nil)
        }
    }

    @Test func primaryActionUsesTheExistingCommandAndAvailability() {
        var captured = 0
        var hidden = false
        let launcher = model([
            .init(title: "Area", shortcut: .captureArea, isHidden: { hidden }) { captured += 1 },
        ])
        launcher.entry(for: .captureArea)?.perform()
        #expect(captured == 1)
        hidden = true
        #expect(launcher.entry(for: .captureArea) == nil)
    }

    @Test func cancellationControlsFollowLiveStateWithoutPromotingOptionalTools() {
        var countingDown = false
        var scrolling = false
        let launcher = model([
            .init(title: "Self-Timer", shortcut: .selfTimer,
                  currentTitle: { countingDown ? "Cancel Self-Timer" : "Self-Timer" }) {},
            .init(title: "Cancel Scrolling Capture", isHidden: { !scrolling }) {},
            .init(title: "Capture Formula", shortcut: .captureFormula, isHidden: { false }) {},
            .init(title: "Scrolling Capture", shortcut: .scrollingCapture,
                  currentTitle: { scrolling ? "Finish Scrolling Capture" : "Scrolling Capture" }) {},
        ])
        #expect(launcher.activeEntries.isEmpty)
        countingDown = true
        scrolling = true
        #expect(launcher.activeEntries.map(\.title) == ["Self-Timer", "Cancel Scrolling Capture"])
        #expect(launcher.entry(for: .scrollingCapture)?.currentTitle?() == "Finish Scrolling Capture")
        countingDown = false
        scrolling = false
        #expect(launcher.activeEntries.isEmpty)
    }

    @Test func advancedMenusKeepNestedActionsAndTheirValidation() {
        var uploaded = false
        var available = false
        let launcher = model([
            .init(title: "More Area Captures") {
                [.init(title: "Upload", isEnabled: { available }, isHidden: { !available }) { uploaded = true }]
            },
        ])
        let category = launcher.moreEntries.first
        let nested = category?.children?().first?.children?().first
        #expect(nested?.isHidden?() == true && nested?.isEnabled?() == false)
        available = true
        #expect(nested?.isHidden?() == false && nested?.isEnabled?() == true)
        nested?.perform()
        #expect(uploaded)
    }
}
