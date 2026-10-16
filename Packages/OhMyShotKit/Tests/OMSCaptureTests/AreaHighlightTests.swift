import AppKit
import CoreGraphics
import OMSCore
import Testing
@testable import OMSCapture

/// How an area being recorded is marked on screen: no panel is shown, only made.
struct AreaHighlightTests {
    let left = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let right = CGRect(x: 1000, y: 0, width: 1200, height: 900)

    private func layout() -> DisplayLayout {
        func display(_ id: CGDirectDisplayID, _ frame: CGRect) -> DisplayInfo {
            DisplayInfo(id: id, name: "Display \(id)", frame: frame, pixelSize: CGSize(width: frame.width * 2, height: frame.height * 2), backingScale: 2, maximumPotentialEDR: 1)
        }
        return DisplayLayout(displays: [display(1, left), display(2, right)])
    }

    @Test func anOutlineAndAFrameLieAroundTheAreaWithRoomForTheirEdge() {
        let area = CGRect(x: 100, y: 200, width: 300, height: 250)
        for style in [RecordingHighlight.outline, .redFrame] {
            let placements = AreaOutline.placements(around: area, displays: [left, right], style: style)
            #expect(placements == [.init(frame: CGRect(x: 96, y: 196, width: 308, height: 258), area: CGRect(x: 4, y: 4, width: 300, height: 250))], "\(style)")
        }
    }

    @Test func theDimLiesOverTheWholeDisplayWithTheAreaClear() {
        let area = CGRect(x: 100, y: 200, width: 300, height: 250)
        let placements = AreaOutline.placements(around: area, displays: [left, right], style: .dim)
        #expect(placements == [.init(frame: left, area: area)])
    }

    @Test func anAreaAcrossTwoDisplaysIsMarkedOnBothInTheirOwnSpaces() {
        let area = CGRect(x: 900, y: 100, width: 300, height: 200)
        let outlined = AreaOutline.placements(around: area, displays: [left, right], style: .outline)
        #expect(outlined.map(\.frame) == [CGRect(x: 896, y: 96, width: 104, height: 208), CGRect(x: 1000, y: 96, width: 204, height: 208)])
        // Each panel knows where the whole area is within itself, so each edge is drawn where it falls.
        #expect(outlined.map(\.area) == [CGRect(x: 4, y: 4, width: 300, height: 200), CGRect(x: -100, y: 4, width: 300, height: 200)])
        let dimmed = AreaOutline.placements(around: area, displays: [left, right], style: .dim)
        #expect(dimmed.map(\.frame) == [left, right])
        #expect(dimmed.map(\.area) == [area, area.offsetBy(dx: -1000, dy: 0)])
    }

    @Test func aDisplayTheAreaDoesNotReachIsLeftAlone() {
        let area = CGRect(x: 1100, y: 100, width: 200, height: 200)
        for style in RecordingHighlight.allCases {
            let placements = AreaOutline.placements(around: area, displays: [left, right], style: style)
            #expect(placements.count == 1 && right.contains(placements[0].frame), "\(style)")
        }
    }

    @Test func theDimLiesUnderTheRecordingsOwnWindowsAndTheOthersOverMenus() {
        let area = CGRect(x: 100, y: 200, width: 300, height: 250)
        // The control bar, the keys, and the click rings lie above the shared dim level (RecordingWindowLevelTests
        // in OMSUITests checks their real panels against it), and must not be dimmed.
        #expect(AreaOutline.dimLevel == RecordingWindowLevel.dim && AreaOutline.dimLevel < RecordingWindowLevel.chrome)
        let dim = AreaOutline.panels(around: area, layout: layout(), style: .dim)
        #expect(dim.count == 1 && dim[0].level == AreaOutline.dimLevel)
        #expect(dim[0].ignoresMouseEvents && dim[0].contentView is AreaDimView)
        for style in [RecordingHighlight.outline, .redFrame] {
            let panels = AreaOutline.panels(around: area, layout: layout(), style: style)
            #expect(panels.count == 1 && panels[0].level.rawValue > NSWindow.Level.popUpMenu.rawValue, "\(style)")
            #expect(panels[0].ignoresMouseEvents)
        }
        #expect(AreaOutline.panels(around: area, layout: layout(), style: .redFrame)[0].contentView is AreaFrameView)
        #expect(AreaOutline.panels(around: area, layout: layout())[0].contentView is SelectionOutlineView)
    }

    @Test func theRedFrameLiesWhollyOutsideTheArea() throws {
        let area = CGRect(x: 100, y: 200, width: 300, height: 250)
        let panel = try #require(AreaOutline.panels(around: area, layout: layout(), style: .redFrame).first)
        let view = try #require(panel.contentView as? AreaFrameView)
        let line = try #require(view.layer?.sublayers?.first as? CAShapeLayer)
        let path = try #require(line.path)
        // The line is centered on its path, so the path lies half a line's width outside the area, and the
        // line's outer edge is within the room the panel has around the area.
        #expect(path.boundingBox == area.insetBy(dx: -AreaOutline.redFrameWidth / 2, dy: -AreaOutline.redFrameWidth / 2).offsetBy(dx: -96, dy: -196))
        #expect(AreaOutline.redFrameWidth < AreaOutline.edgeRoom)
    }
}
