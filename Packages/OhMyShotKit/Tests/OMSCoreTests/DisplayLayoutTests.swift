import CoreGraphics
import Foundation
import Testing
@testable import OMSCore

/// The author's setup: a built-in XDR panel ("looks like" 1728×1117) as the primary display, plus a
/// 6K external display (3440×1440 points, 6880×2880 pixels) placed in different spots.
struct DisplayLayoutTests {
    static let builtIn = DisplayInfo(
        id: 1,
        name: "Built-in Liquid Retina XDR Display",
        frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
        pixelSize: CGSize(width: 3456, height: 2234),
        backingScale: 2,
        maximumPotentialEDR: 16
    )

    static func external(at origin: CGPoint) -> DisplayInfo {
        DisplayInfo(
            id: 2,
            name: "6K",
            frame: CGRect(origin: origin, size: CGSize(width: 3440, height: 1440)),
            pixelSize: CGSize(width: 6880, height: 2880),
            backingScale: 2,
            maximumPotentialEDR: 1
        )
    }

    static func layout(externalAt origin: CGPoint) -> DisplayLayout {
        DisplayLayout(displays: [builtIn, external(at: origin)])
    }

    @Test(
        "Flipping between AppKit and Core Graphics space is its own inverse",
        arguments: [CGPoint(x: 1728, y: 0), CGPoint(x: -3440, y: -200), CGPoint(x: -500, y: 1117)]
    )
    func flipRoundTrips(externalOrigin: CGPoint) {
        let layout = Self.layout(externalAt: externalOrigin)
        let rect = CGRect(x: externalOrigin.x + 40, y: externalOrigin.y + 30, width: 300, height: 200)
        #expect(layout.flipped(layout.flipped(rect)) == rect)
        #expect(layout.flipped(layout.flipped(rect.origin)) == rect.origin)
    }

    @Test func externalAbovePrimaryHasNegativeCoreGraphicsY() {
        let layout = Self.layout(externalAt: CGPoint(x: 0, y: 1117))
        #expect(layout.flipped(layout.displays[1].frame) == CGRect(x: 0, y: -1440, width: 3440, height: 1440))
    }

    @Test func externalLeftOfPrimaryAlignedAtTheBottom() {
        let layout = Self.layout(externalAt: CGPoint(x: -3440, y: 0))
        #expect(layout.flipped(layout.displays[1].frame) == CGRect(x: -3440, y: -323, width: 3440, height: 1440))
    }

    @Test func primaryTopLeftIsTheCoreGraphicsOrigin() {
        let layout = Self.layout(externalAt: CGPoint(x: 1728, y: 0))
        #expect(layout.flipped(CGPoint(x: 0, y: 1117)) == .zero)
    }

    @Test func sharedEdgeBelongsToTheDisplayThatStartsThere() {
        let layout = Self.layout(externalAt: CGPoint(x: 1728, y: 0))
        #expect(layout.display(at: CGPoint(x: 1728, y: 100))?.id == 2)
        #expect(layout.display(at: CGPoint(x: 1727.5, y: 100))?.id == 1)
        #expect(layout.display(at: CGPoint(x: 1000, y: 1200)) == nil)
    }

    @Test func urlDisplayNumbersStartAtOneWithThePrimary() {
        let layout = Self.layout(externalAt: CGPoint(x: 1728, y: 0))
        #expect(layout.display(number: 1)?.id == 1)
        #expect(layout.display(number: 2)?.id == 2)
        #expect(layout.display(number: 0) == nil)
        #expect(layout.display(number: 3) == nil)
    }

    @Test func localRectsAreOffsetByTheirDisplayOrigin() {
        let layout = Self.layout(externalAt: CGPoint(x: -3440, y: 200))
        let local = CGRect(x: 10, y: 20, width: 100, height: 50)
        #expect(layout.globalRect(fromLocal: local, on: layout.displays[1]) == CGRect(x: -3430, y: 220, width: 100, height: 50))
    }

    @Test func pixelsPerPointComesFromTheFramebuffer() {
        #expect(Self.external(at: .zero).pixelsPerPoint == 2)
        let scaled = DisplayInfo(
            id: 3,
            name: "Scaled",
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            pixelSize: CGSize(width: 3840, height: 2160),
            backingScale: 2,
            maximumPotentialEDR: 1
        )
        #expect(scaled.pixelsPerPoint == 1.5)
        #expect(Self.builtIn.supportsHDR)
        #expect(!scaled.supportsHDR)
    }
}

/// All-In-One's last area comes back only where it was.
struct RememberedAreaTests {
    @Test func theAreaComesBackOnItsDisplayAsItWas() {
        let layout = DisplayLayoutTests.layout(externalAt: CGPoint(x: 1728, y: 0))
        let area = CGRect(x: 1800, y: 100, width: 400, height: 300)
        let kept = RememberedArea(area: area, on: DisplayLayoutTests.external(at: CGPoint(x: 1728, y: 0)))
        #expect(kept.area(in: layout) == area)
    }

    @Test func aDisplayMovedOrGoneDropsTheArea() {
        let kept = RememberedArea(area: CGRect(x: 1800, y: 100, width: 400, height: 300), on: DisplayLayoutTests.external(at: CGPoint(x: 1728, y: 0)))
        #expect(kept.area(in: DisplayLayoutTests.layout(externalAt: CGPoint(x: -3440, y: 0))) == nil)
        #expect(kept.area(in: DisplayLayout(displays: [DisplayLayoutTests.builtIn])) == nil)
    }

    @Test func itSurvivesBeingStored() throws {
        let kept = RememberedArea(area: CGRect(x: 10, y: 20, width: 30, height: 40), on: DisplayLayoutTests.builtIn)
        let decoded = try JSONDecoder().decode(RememberedArea.self, from: JSONEncoder().encode(kept))
        #expect(decoded == kept)
    }
}
