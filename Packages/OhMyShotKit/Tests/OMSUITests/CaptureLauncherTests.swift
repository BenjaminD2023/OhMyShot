import AppKit
import Testing
@testable import OMSUI

@MainActor
struct CaptureLauncherTests {
    private func model(
        _ captures: [StatusItemController.Entry],
        tools: [StatusItemController.Entry] = [],
        images: [StatusItemController.Entry] = [],
        history: [StatusItemController.Entry] = [],
        app: [StatusItemController.Entry] = []
    ) -> CaptureLauncherModel {
        CaptureLauncherModel(captureEntries: captures, toolEntries: tools, imageEntries: images, historyEntries: history,
                             priorityEntries: [], appEntries: app, debugEntries: [], openSettings: {},
                             editShortcut: { _ in }, quit: {})
    }

    @Test func launcherRetainsForkUpdateActionsAndSavedPreferenceControls() {
        var checks = 0
        var automatic = true
        let controller = StatusItemController(
            captureEntries: [], appEntries: [.init(title: "What's New") {}],
            openSettings: {}, editShortcut: { _ in }, quit: {},
            updateEntries: [
                .init(title: "Check for Updates") { checks += 1 },
                .init(title: "Updates") {
                    [.init(title: "Automatic", isChecked: { automatic }) { automatic.toggle() }]
                },
            ]
        )
        let entries = controller.launcherModel.appRows
        #expect(entries.filter { $0.title == "Check for Updates" }.count == 1)
        entries.first { $0.title == "Check for Updates" }?.perform()
        #expect(checks == 1)
        let toggle = entries.first { $0.title == "Updates" }?.children?().first
        #expect(toggle?.isChecked?() == true)
        toggle?.perform()
        #expect(!automatic && toggle?.isChecked?() == false)
    }

    @Test func tileUsesTheExistingCommandAndAvailability() {
        var captured = 0
        var hidden = false
        let launcher = model([
            .init(title: "Area", shortcut: .captureArea, isHidden: { hidden }) { captured += 1 },
        ])
        launcher.captureTiles.first?.perform()
        #expect(captured == 1)
        hidden = true
        #expect(launcher.captureTiles.isEmpty)
    }

    @Test func cancellationsLeadOnlyWhileSomethingRuns() {
        var scrolling = false
        var formula = false
        let launcher = model([
            .init(title: "Scrolling Capture", shortcut: .scrollingCapture,
                  currentTitle: { scrolling ? "Finish Scrolling Capture" : "Scrolling Capture" }) {},
            .init(title: "Cancel Scrolling Capture", isHidden: { !scrolling }) {},
            .init(title: "Capture Formula", shortcut: .captureFormula, isHidden: { !formula }) {},
        ])
        #expect(launcher.activeEntries.isEmpty)
        scrolling = true
        #expect(launcher.activeEntries.map(\.title) == ["Cancel Scrolling Capture"])
        #expect(launcher.captureTiles.first?.currentTitle?() == "Finish Scrolling Capture")
        // An optional command with a shortcut is a tile while it is there, never a cancellation.
        #expect(launcher.toolTiles.isEmpty)
        formula = true
        #expect(launcher.toolTiles.map(\.title) == ["Capture Formula"])
        #expect(launcher.activeEntries.map(\.title) == ["Cancel Scrolling Capture"])
    }

    /// The launcher replaces the status menu on a left click, so every command in it is there exactly once: a
    /// command with a shortcut as a tile, where its keys can be changed, and one without as a row.
    @Test func everyStatusMenuCommandAppearsOnceAsATileExactlyWhenItHasAShortcut() {
        let launcher = model(
            [
                .init(title: "All-In-One", shortcut: .allInOne) {},
                .init(title: "Capture Area", shortcut: .captureArea) {},
                .init(title: "Annotate Area", shortcut: .annotateArea) {},
                .init(title: "Capture Area and Pin", shortcut: .pinArea) {},
                .init(title: "More Area Captures") { [] },
                .init(title: "Record Screen", shortcut: .recordScreen) {},
                .init(title: "Cancel Studio Export", isHidden: { true }) {},
                .init(title: "Translate Area", shortcut: .translateArea) {},
            ],
            tools: [
                .init(title: "Pick Color", shortcut: .pickColor) {},
                .separator,
                .init(title: "Hide Desktop Icons") {},
            ],
            images: [.init(title: "Pins") { [] }],
            history: [
                .init(title: "Capture History…", shortcut: .openHistory) {},
                .init(title: "Restore Recently Closed") {},
            ],
            app: [.init(title: "Join Discord") {}, .init(title: "What’s New…", isHidden: { true }) {}]
        )
        let tiles = launcher.captureTiles + launcher.toolTiles
        let rows = launcher.activeEntries + launcher.moreRows + launcher.imageRows + launcher.appRows
        #expect(launcher.captureTiles.map(\.title) == ["Capture Area", "Record Screen", "All-In-One", "Capture Area and Pin"])
        #expect(launcher.toolTiles.map(\.title) == ["Annotate Area", "Translate Area", "Pick Color", "Capture History…"])
        #expect(tiles.allSatisfy { $0.shortcut != nil } && rows.allSatisfy { $0.shortcut == nil })
        let shown = (tiles + rows).map(\.title)
        #expect(shown.count == Set(shown).count)
        #expect(Set(shown).isSuperset(of: [
            "All-In-One", "Capture Area", "Annotate Area", "Capture Area and Pin", "More Area Captures", "Record Screen",
            "Translate Area", "Pick Color", "Hide Desktop Icons", "Pins", "Capture History…", "Restore Recently Closed",
            "Join Discord",
        ]))
        #expect(!shown.contains("Cancel Studio Export") && !shown.contains("What’s New…"))
    }
}
