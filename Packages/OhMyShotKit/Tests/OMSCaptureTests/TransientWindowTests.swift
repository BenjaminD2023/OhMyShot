import CoreGraphics
import OMSCore
import Testing
@testable import OMSCapture

struct TransientWindowTests {
    private let layout = DisplayLayout(displays: [
        DisplayInfo(
            id: 1, name: "Main", frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            pixelSize: CGSize(width: 200, height: 200), backingScale: 2, maximumPotentialEDR: 1
        ),
    ])

    private func window(id: CGWindowID, pid: pid_t, layer: Int, frame: CGRect) -> [String: Any] {
        [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: CGFloat(1),
            kCGWindowBounds as String: [
                "X": frame.minX, "Y": frame.minY, "Width": frame.width, "Height": frame.height,
            ] as [String: CGFloat],
        ]
    }

    @Test func transientCandidatesKeepPopupMenusAndTheExplicitLauncherButExcludeChromeAndPanels() {
        let popupMenu = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let floating = Int(CGWindowLevelForKey(.floatingWindow))
        let dock = Int(CGWindowLevelForKey(.dockWindow))
        let mainMenu = Int(CGWindowLevelForKey(.mainMenuWindow))
        let status = Int(CGWindowLevelForKey(.statusWindow))
        let desktop = Int(CGWindowLevelForKey(.desktopWindow))
        let windows = [
            window(id: 10, pid: 7, layer: popupMenu, frame: CGRect(x: 10, y: 20, width: 30, height: 40)),
            window(id: 11, pid: 7, layer: status, frame: CGRect(x: 11, y: 21, width: 30, height: 40)),
            window(id: 12, pid: 7, layer: floating, frame: CGRect(x: 12, y: 22, width: 30, height: 40)),
            window(id: 13, pid: 7, layer: dock, frame: CGRect(x: 13, y: 23, width: 30, height: 40)),
            window(id: 14, pid: 7, layer: mainMenu, frame: CGRect(x: 14, y: 24, width: 30, height: 40)),
            window(id: 15, pid: 7, layer: desktop, frame: CGRect(x: 15, y: 25, width: 30, height: 40)),
            window(id: 20, pid: 42, layer: status, frame: CGRect(x: 1, y: 2, width: 30, height: 40)),
            window(id: 21, pid: 42, layer: popupMenu, frame: CGRect(x: 2, y: 3, width: 30, height: 40)),
            window(id: 30, pid: 9, layer: 0, frame: CGRect(x: 30, y: 10, width: 30, height: 40)),
            window(id: 40, pid: 8, layer: Int(CGWindowLevelForKey(.screenSaverWindow)), frame: CGRect(x: 40, y: 10, width: 30, height: 40)),
        ]

        let externalOnly = WindowCatalog.transientWindows(in: windows, layout: layout, ownPID: 42)
        #expect(externalOnly.map(\.id) == [10])
        #expect(externalOnly.first?.frame == CGRect(x: 10, y: 40, width: 30, height: 40))

        let withLauncher = WindowCatalog.transientWindows(in: windows, layout: layout, ownPID: 42, includingOwnWindowID: 20)
        #expect(Set(withLauncher.map(\.id)) == Set([10, 20]))

        let wrongOwner = WindowCatalog.transientWindows(in: windows, layout: layout, ownPID: 42, includingOwnWindowID: 10)
        #expect(wrongOwner.map(\.id) == [10])

        let retainedPopup = WindowCatalog.transientWindowsToRestore(
            externalOnly, onScreenOwners: [OnScreenWindowOwner(id: 10, ownerPID: 7)]
        )
        #expect(retainedPopup.map(\.id) == [10])
    }

    @Test func disappearedOrdinaryLayerFrontmostPanelIsRetained() {
        let panel = window(
            id: 50, pid: 7, layer: Int(CGWindowLevelForKey(.normalWindow)),
            frame: CGRect(x: 10, y: 20, width: 30, height: 40)
        )
        let candidates = WindowCatalog.transientWindows(
            in: [panel], layout: layout, ownPID: 42, frontmostPID: 7
        )
        #expect(candidates.map(\.id) == [50])
        #expect(WindowCatalog.transientWindowsToRestore(candidates, onScreenOwners: []).map(\.id) == [50])
    }

    @Test func persistentFloatingAndNormalFrontmostWindowsAreNotRetained() {
        let normal = window(
            id: 60, pid: 7, layer: Int(CGWindowLevelForKey(.normalWindow)),
            frame: CGRect(x: 10, y: 20, width: 30, height: 40)
        )
        let floating = window(
            id: 61, pid: 7, layer: Int(CGWindowLevelForKey(.floatingWindow)),
            frame: CGRect(x: 20, y: 30, width: 30, height: 40)
        )
        let candidates = WindowCatalog.transientWindows(
            in: [normal, floating], layout: layout, ownPID: 42, frontmostPID: 7
        )
        let stillOnScreen = WindowCatalog.onScreenWindowOwners(in: [normal, floating])
        #expect(candidates.map(\.id) == [60, 61])
        #expect(WindowCatalog.transientWindowsToRestore(candidates, onScreenOwners: stillOnScreen).isEmpty)
    }

    @Test func ordinaryWindowFromWrongOwnerIsNotACandidate() {
        let wrongApp = window(
            id: 70, pid: 8, layer: Int(CGWindowLevelForKey(.normalWindow)),
            frame: CGRect(x: 10, y: 20, width: 30, height: 40)
        )
        let wrongLauncher = window(
            id: 71, pid: 8, layer: Int(CGWindowLevelForKey(.floatingWindow)),
            frame: CGRect(x: 20, y: 30, width: 30, height: 40)
        )
        let candidates = WindowCatalog.transientWindows(
            in: [wrongApp, wrongLauncher], layout: layout, ownPID: 42, frontmostPID: 7, includingOwnWindowID: 71
        )
        #expect(candidates.isEmpty)

        let reusedID = OnScreenWindowOwner(id: 71, ownerPID: 9)
        let requested = TransientWindow(
            id: 71, ownerPID: 42, frame: CGRect(x: 20, y: 30, width: 30, height: 40), keepsWhenPresent: true
        )
        #expect(WindowCatalog.transientWindowsToRestore([requested], onScreenOwners: [reusedID]).isEmpty)
    }
}
