import AppKit
import Testing
@testable import OMSCore

@MainActor
struct HoverTagTests {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let size = CGSize(width: 80, height: 24)

    /// A horizontal bar's tag stands centered under the chip, clear of the bar.
    @Test func standsUnderABarsChip() {
        let chip = CGRect(x: 400, y: 500, width: 30, height: 30)
        let frame = HoverTag.frame(of: size, beside: chip, edge: .minY, gap: 12, within: screen)
        #expect(frame == CGRect(x: 375, y: 464, width: 80, height: 24))
    }

    /// At the foot of the screen there is no room under the bar: the tag stands above it.
    @Test func movesAboveAtTheScreensFoot() {
        let chip = CGRect(x: 400, y: 10, width: 30, height: 30)
        let frame = HoverTag.frame(of: size, beside: chip, edge: .minY, gap: 12, within: screen)
        #expect(frame.minY == chip.maxY + 12)
    }

    /// The rail's tag stands to its right, on the chip's middle; at the screen's right edge, to its left.
    @Test func standsBesideARailsChip() {
        let chip = CGRect(x: 20, y: 300, width: 30, height: 30)
        let right = HoverTag.frame(of: size, beside: chip, edge: .maxX, gap: 12, within: screen)
        #expect(right == CGRect(x: 62, y: 303, width: 80, height: 24))
        let atEdge = CGRect(x: 960, y: 300, width: 30, height: 30)
        let left = HoverTag.frame(of: size, beside: atEdge, edge: .maxX, gap: 12, within: screen)
        #expect(left.maxX == atEdge.minX - 12)
    }

    /// A chip at the screen's side keeps its tag on screen.
    @Test func staysOnScreen() {
        let chip = CGRect(x: 0, y: 500, width: 30, height: 30)
        let frame = HoverTag.frame(of: size, beside: chip, edge: .minY, gap: 12, within: screen)
        #expect(frame.minX >= screen.minX)
    }

    /// A symbol alone keeps its help for the tag instead of the system's tooltip; a titled chip keeps the tooltip.
    @Test func symbolOnlyButtonsUseTheTag() {
        let button = HoverTagButton(title: "Capture", image: NSImage(), target: nil, action: nil)
        button.imagePosition = .imageLeading
        button.toolTip = "Capture the area (Return)"
        #expect(!button.showsHoverTag)
        #expect(button.toolTip == "Capture the area (Return)")

        button.imagePosition = .imageOnly
        #expect(button.showsHoverTag)
        #expect(button.toolTip == "Capture the area (Return)")
        #expect(button.accessibilityHelp() == "Capture the area (Return)")

        button.toolTip = nil
        #expect(!button.showsHoverTag)
    }
}
