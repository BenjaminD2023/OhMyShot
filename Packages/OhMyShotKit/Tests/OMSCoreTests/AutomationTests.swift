import CoreGraphics
import Foundation
import Testing
@testable import OMSCore

struct AutomationURLParserTests {
    private func parse(_ string: String) -> Result<AutomationCommand, AutomationURLError> {
        AutomationURLParser.parse(URL(string: string)!, scheme: "ohmyshot")
    }

    @Test func captureAreaWithRegionDisplayAndAction() {
        let result = parse("ohmyshot://capture-area?x=10&y=20&width=300&height=200&display=2&action=copy")
        let region = AutomationRegion(rect: CGRect(x: 10, y: 20, width: 300, height: 200), display: 2)
        #expect(result == .success(.captureArea(region, action: .copy)))
    }

    @Test func captureAreaWithoutParametersAsksTheUserToSelect() {
        #expect(parse("ohmyshot://capture-area") == .success(.captureArea(AutomationRegion(), action: nil)))
    }

    @Test func commandNamesAreCaseInsensitive() {
        #expect(parse("OHMYSHOT://Capture-Fullscreen?action=save") == .success(.captureFullscreen(action: .save)))
    }

    @Test func partialRegionIsRejected() {
        #expect(parse("ohmyshot://capture-area?x=10&y=20") == .failure(.missingParameter("width")))
    }

    @Test func emptyRegionIsRejected() {
        #expect(parse("ohmyshot://capture-area?x=0&y=0&width=0&height=10") == .failure(.invalidParameter(name: "width", value: "0")))
    }

    @Test func displayNumbersStartAtOne() {
        #expect(parse("ohmyshot://all-in-one?display=0") == .failure(.invalidParameter(name: "display", value: "0")))
        #expect(parse("ohmyshot://all-in-one?display=2") == .success(.allInOne(AutomationRegion(display: 2))))
    }

    @Test func unknownActionIsRejected() {
        #expect(parse("ohmyshot://capture-window?action=print") == .failure(.invalidParameter(name: "action", value: "print")))
    }

    @Test func captureTextReadsFileAndLineBreaks() {
        let result = parse("ohmyshot://capture-text?filepath=/tmp/shot.png&linebreaks=false")
        #expect(result == .success(.captureText(file: URL(filePath: "/tmp/shot.png"), region: AutomationRegion(), lineBreaks: false)))
    }

    /// As the Raycast extension writes them: every reserved character percent-encoded, a plus as %2B.
    @Test func encodedPathsKeepTheirSpacesAndPlusSigns() {
        let result = parse("ohmyshot://pin?filepath=%2FUsers%2Fme%2FDesktop%2Fa%2Bb%20shot.png")
        #expect(result == .success(.pin(file: URL(filePath: "/Users/me/Desktop/a+b shot.png"))))
    }

    @Test func relativeFilePathsAreRejected() {
        #expect(parse("ohmyshot://pin?filepath=shot.png") == .failure(.invalidParameter(name: "filepath", value: "shot.png")))
    }

    @Test func quickAccessOverlayNeedsAFile() {
        #expect(parse("ohmyshot://add-quick-access-overlay") == .failure(.missingParameter("filepath")))
    }

    @Test func scrollingCaptureFlags() {
        #expect(parse("ohmyshot://scrolling-capture?start=true&autoscroll=1") == .success(.scrollingCapture(AutomationRegion(), start: true, autoscroll: true)))
    }

    @Test func openSettingsKeepsTheTab() {
        #expect(parse("ohmyshot://open-settings?tab=shortcuts") == .success(.openSettings(tab: "shortcuts")))
    }

    @Test func unknownParametersAreIgnored() {
        #expect(parse("ohmyshot://capture-previous-area?future=1") == .success(.capturePreviousArea(action: nil)))
    }

    @Test func wrongSchemeAndUnknownCommandsAreRejected() {
        #expect(parse("cleanshot://capture-area") == .failure(.wrongScheme("cleanshot")))
        #expect(parse("ohmyshot://make-coffee") == .failure(.unknownCommand("make-coffee")))
    }

    @Test func screenCommandsSayTheyReadTheScreen() {
        #expect(AutomationCommand.captureWindow(action: .pin).readsScreen)
        #expect(AutomationCommand.captureText(file: nil, region: AutomationRegion(), lineBreaks: nil).readsScreen)
        #expect(!AutomationCommand.captureText(file: URL(filePath: "/tmp/a.png"), region: AutomationRegion(), lineBreaks: nil).readsScreen)
        #expect(!AutomationCommand.hideDesktopIcons.readsScreen)
    }

    @Test func fileCommandsReportTheFilesTheyRead() {
        let file = URL(filePath: "/tmp/a.png")
        #expect(AutomationCommand.pin(file: file).fileURLs == [file])
        #expect(AutomationCommand.captureFullscreen(action: nil).fileURLs.isEmpty)
    }
}

/// URL areas are in their display's own points, from its bottom-left corner.
struct AutomationRegionTests {
    private let pointerOnBuiltIn = CGPoint(x: 100, y: 100)

    @Test func noAreaLeavesTheChoiceToTheUser() throws {
        let layout = DisplayLayoutTests.layout(externalAt: CGPoint(x: 1728, y: 0))
        #expect(try AutomationRegion(display: 2).area(in: layout, pointer: pointerOnBuiltIn) == nil)
    }

    @Test func areaOnTheNumberedDisplay() throws {
        // The 6K display to the left of the built-in one, with its bottom 200 pt below it.
        let layout = DisplayLayoutTests.layout(externalAt: CGPoint(x: -3440, y: -200))
        let region = AutomationRegion(rect: CGRect(x: 10, y: 20, width: 300, height: 200), display: 2)
        #expect(try region.area(in: layout, pointer: pointerOnBuiltIn) == CGRect(x: -3430, y: -180, width: 300, height: 200))
    }

    @Test func areaAboveThePrimaryDisplay() throws {
        let layout = DisplayLayoutTests.layout(externalAt: CGPoint(x: -500, y: 1117))
        let region = AutomationRegion(rect: CGRect(x: 0, y: 0, width: 100, height: 50), display: 2)
        #expect(try region.area(in: layout, pointer: pointerOnBuiltIn) == CGRect(x: -500, y: 1117, width: 100, height: 50))
    }

    @Test func withoutADisplayTheOneUnderThePointer() throws {
        let layout = DisplayLayoutTests.layout(externalAt: CGPoint(x: 1728, y: 0))
        let region = AutomationRegion(rect: CGRect(x: 10, y: 10, width: 40, height: 40))
        #expect(try region.area(in: layout, pointer: CGPoint(x: 2000, y: 500)) == CGRect(x: 1738, y: 10, width: 40, height: 40))
        #expect(try region.area(in: layout, pointer: pointerOnBuiltIn) == CGRect(x: 10, y: 10, width: 40, height: 40))
        // A pointer off every display (as it is between screens of different heights) falls back on the primary.
        #expect(try region.area(in: layout, pointer: CGPoint(x: 100, y: 1300)) == CGRect(x: 10, y: 10, width: 40, height: 40))
    }

    @Test func areaPastItsDisplayIsCutToIt() throws {
        let layout = DisplayLayoutTests.layout(externalAt: CGPoint(x: 1728, y: 0))
        let region = AutomationRegion(rect: CGRect(x: 1600, y: 1000, width: 400, height: 400), display: 1)
        #expect(try region.area(in: layout, pointer: pointerOnBuiltIn) == CGRect(x: 1600, y: 1000, width: 128, height: 117))
    }

    @Test func areaOffItsDisplayOrAMissingDisplayIsRefused() {
        let layout = DisplayLayoutTests.layout(externalAt: CGPoint(x: 1728, y: 0))
        let off = CGRect(x: 2000, y: 10, width: 50, height: 50)
        #expect(throws: AutomationURLError.areaOffDisplay(off)) {
            try AutomationRegion(rect: off, display: 1).area(in: layout, pointer: pointerOnBuiltIn)
        }
        #expect(throws: AutomationURLError.noSuchDisplay(3)) {
            try AutomationRegion(rect: CGRect(x: 0, y: 0, width: 10, height: 10), display: 3).area(in: layout, pointer: pointerOnBuiltIn)
        }
    }
}

struct AutomationGateTests {
    let raycast = AutomationCaller(identifier: "com.raycast.macos", displayName: "Raycast")

    @Test func disabledAutomationDeniesEveryone() {
        let decision = AutomationGate.evaluate(caller: raycast, isEnabled: false, approvedCallers: [raycast.identifier])
        #expect(decision == .deny(reason: "automation is turned off in Settings"))
    }

    @Test func unidentifiedSendersAreDenied() {
        #expect(AutomationGate.evaluate(caller: nil, isEnabled: true, approvedCallers: []) == .deny(reason: "the sender could not be identified"))
    }

    @Test func approvedCallersAreAllowed() {
        #expect(AutomationGate.evaluate(caller: raycast, isEnabled: true, approvedCallers: [raycast.identifier]) == .allow)
    }

    @Test func newCallersNeedTheUsersApproval() {
        #expect(AutomationGate.evaluate(caller: raycast, isEnabled: true, approvedCallers: []) == .askUser)
    }

    @Test func refusedCallersAreNotAskedAgain() {
        let decision = AutomationGate.evaluate(caller: raycast, isEnabled: true, approvedCallers: [], deniedCallers: [raycast.identifier])
        #expect(decision == .deny(reason: "Raycast was already refused"))
    }
}
