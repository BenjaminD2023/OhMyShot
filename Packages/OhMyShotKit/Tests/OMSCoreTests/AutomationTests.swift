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

    @Test func fileCommandsReportTheFilesTheyRead() {
        let file = URL(filePath: "/tmp/a.png")
        #expect(AutomationCommand.pin(file: file).fileURLs == [file])
        #expect(AutomationCommand.captureFullscreen(action: nil).fileURLs.isEmpty)
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
