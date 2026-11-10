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

    /// The arrow keys cross the launcher as it is laid out: tiles four to a row, then the rows two to a row.
    @Test func arrowKeysFollowTheLayoutAndKeepTheirSide() {
        typealias Cell = CaptureLauncherModel.Cell
        // Two rows of tiles (the second one short), then two rows of menu rows (the second one short).
        let rows: [(count: Int, columns: Int)] = [(4, 4), (3, 4), (2, 2), (1, 2)]
        func move(_ cell: Cell?, _ direction: CaptureLauncherModel.Direction) -> Cell? {
            CaptureLauncherModel.move(from: cell, direction, rows: rows)
        }
        // From nothing, Down and Right start at the first command, Up and Left in the last row.
        #expect(move(nil, .down) == Cell(row: 0, column: 0))
        #expect(move(nil, .right) == Cell(row: 0, column: 0))
        #expect(move(nil, .up) == Cell(row: 3, column: 0))
        // Along a row, and no further than its ends.
        #expect(move(Cell(row: 0, column: 0), .right) == Cell(row: 0, column: 1))
        #expect(move(Cell(row: 0, column: 3), .right) == Cell(row: 0, column: 3))
        #expect(move(Cell(row: 0, column: 0), .left) == Cell(row: 0, column: 0))
        // Down a column; a short row gives its last place.
        #expect(move(Cell(row: 0, column: 2), .down) == Cell(row: 1, column: 2))
        #expect(move(Cell(row: 0, column: 3), .down) == Cell(row: 1, column: 2))
        // From the tiles to the rows and back, the highlight stays on its side of the launcher.
        #expect(move(Cell(row: 1, column: 0), .down) == Cell(row: 2, column: 0))
        #expect(move(Cell(row: 1, column: 2), .down) == Cell(row: 2, column: 1))
        #expect(move(Cell(row: 2, column: 1), .up) == Cell(row: 1, column: 2))
        #expect(move(Cell(row: 2, column: 1), .down) == Cell(row: 3, column: 0))
        // At the top and the bottom it stays.
        #expect(move(Cell(row: 0, column: 1), .up) == Cell(row: 0, column: 1))
        #expect(move(Cell(row: 3, column: 0), .down) == Cell(row: 3, column: 0))
        // A place that is no longer there (a command went away) starts over.
        #expect(move(Cell(row: 9, column: 0), .down) == Cell(row: 0, column: 0))
    }

    @Test func arrowKeysPassOverDimmedCommands() {
        typealias Cell = CaptureLauncherModel.Cell
        let rows: [(count: Int, columns: Int)] = [(4, 4), (2, 2), (2, 2)]
        let dimmed: Set<Cell> = [Cell(row: 0, column: 1), Cell(row: 1, column: 0), Cell(row: 1, column: 1)]
        func move(_ cell: Cell?, _ direction: CaptureLauncherModel.Direction) -> Cell? {
            CaptureLauncherModel.move(from: cell, direction, rows: rows) { !dimmed.contains($0) }
        }
        #expect(move(Cell(row: 0, column: 0), .right) == Cell(row: 0, column: 2))
        // A row with nothing to choose is passed over whole.
        #expect(move(Cell(row: 0, column: 0), .down) == Cell(row: 2, column: 0))
        #expect(move(Cell(row: 2, column: 1), .up) == Cell(row: 0, column: 2))
        // With every command dimmed there is nothing to light.
        #expect(CaptureLauncherModel.move(from: nil, .down, rows: rows) { _ in false } == nil)
    }

    @Test func theArrowKeysRowsAreTheLaunchersOwnOrder() {
        var scrolling = true
        let launcher = model(
            [
                .init(title: "Capture Area", shortcut: .captureArea) {},
                .init(title: "Capture Window", shortcut: .captureWindow) {},
                .init(title: "Cancel Scrolling Capture", isHidden: { !scrolling }) {},
                .init(title: "More Area Captures") { [] },
            ],
            tools: [.init(title: "Pick Color", shortcut: .pickColor) {}],
            images: [.init(title: "Open Image") { [] }]
        )
        // What is running leads, one to a row; then the capture tiles, the tools, and the rows.
        #expect(launcher.rows.map { $0.entries.map(\.title) }.prefix(4) == [
            ["Cancel Scrolling Capture"], ["Capture Area", "Capture Window"], ["Pick Color"], ["More Area Captures"],
        ])
        #expect(launcher.rows.map(\.columns).prefix(4) == [1, 4, 4, 2])
        scrolling = false
        #expect(launcher.rows.first?.entries.map(\.title) == ["Capture Area", "Capture Window"])
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
