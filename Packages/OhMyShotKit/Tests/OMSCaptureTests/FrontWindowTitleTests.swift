import CoreGraphics
import Foundation
import Testing
@testable import OMSCapture

/// Which window an area is named after.
struct FrontWindowTitleTests {
    private func window(
        pid: pid_t, title: String?, layer: Int = 0, size: CGSize = CGSize(width: 800, height: 600), alpha: CGFloat = 1
    ) -> [String: Any] {
        var info: [String: Any] = [
            kCGWindowLayer as String: layer,
            kCGWindowOwnerPID as String: pid,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": size.width, "Height": size.height] as [String: CGFloat],
        ]
        if let title { info[kCGWindowName as String] = title }
        return info
    }

    @MainActor
    @Test func theFrontmostWindowOfTheAppIsTheOneInFront() {
        let list = [window(pid: 7, title: "Other app"), window(pid: 42, title: "Front"), window(pid: 42, title: "Behind")]
        #expect(WindowCatalog.frontWindowTitle(ofProcess: 42, in: list) == "Front")
    }

    @MainActor
    @Test func panelsSliversAndWindowsWithNoTitleAreSkipped() {
        let list = [
            window(pid: 42, title: "Menu", layer: 25),
            window(pid: 42, title: "Sliver", size: CGSize(width: 10, height: 600)),
            window(pid: 42, title: "Hidden", alpha: 0),
            window(pid: 42, title: nil),
            window(pid: 42, title: ""),
            window(pid: 42, title: "Document"),
        ]
        #expect(WindowCatalog.frontWindowTitle(ofProcess: 42, in: list) == "Document")
    }

    @MainActor
    @Test func anAppWithNoWindowOnScreenHasNoTitle() {
        #expect(WindowCatalog.frontWindowTitle(ofProcess: 42, in: [window(pid: 7, title: "Other app")]) == nil)
        #expect(WindowCatalog.frontWindowTitle(ofProcess: 42, in: []) == nil)
    }
}
