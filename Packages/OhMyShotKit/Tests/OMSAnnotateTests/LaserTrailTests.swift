import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

/// The laser pointer's trail: it narrows with age, fades within its life, ignores a pointer held still, and draws no
/// more points than it should.
struct LaserTrailTests {
    @Test func aPointNarrowsWithAgeAndIsGoneAtTheEndOfItsLife() {
        var trail = LaserTrail(width: 10)
        trail.add(CGPoint(x: 0, y: 0), at: 0)
        trail.add(CGPoint(x: 50, y: 0), at: 0.1)
        let newest = trail.points[1]
        #expect(trail.radius(of: newest, at: 0.1) == 5)
        // Halfway through its life: 1 − 0.5² of the full radius.
        #expect(abs(trail.radius(of: newest, at: 0.1 + LaserTrail.life / 2) - 5 * 0.75) < 0.0001)
        #expect(trail.radius(of: newest, at: 0.1 + LaserTrail.life) == 0)
        #expect(trail.isVisible(at: 0.2) && trail.outline(at: 0.2) != nil)
        #expect(!trail.isVisible(at: 0.1 + LaserTrail.life) && trail.outline(at: 0.1 + LaserTrail.life) == nil)
        #expect(trail.isDone(at: 0.1 + LaserTrail.life))
    }

    /// Each new point goes part of the way toward the pointer; one held still adds nothing, so the trail fades.
    @Test func thePointerIsFollowedSmoothlyAndAHeldPointerAddsNothing() {
        var trail = LaserTrail(width: 10)
        trail.add(CGPoint(x: 0, y: 0), at: 0)
        trail.add(CGPoint(x: 100, y: 0), at: 0.016)
        #expect(trail.points.last?.location == CGPoint(x: 60, y: 0))
        trail.add(CGPoint(x: 100, y: 0), at: 0.032)
        #expect(trail.points.count == 2)
    }

    /// A long trail is drawn with no more than its share of points, and covers where the pointer went.
    @Test func aLongTrailIsThinnedAndStillCoversItsWay() throws {
        var trail = LaserTrail(width: 12)
        for step in 0..<400 { trail.add(CGPoint(x: CGFloat(step), y: 100 + sin(CGFloat(step) / 20) * 30), at: Double(step) * 0.001) }
        let outline = try #require(trail.outline(at: 0.4))
        #expect(outline.contains(CGPoint(x: 390, y: 100 + sin(390.0 / 20) * 30)))
        #expect(!outline.contains(CGPoint(x: 200, y: 300)))
    }

    /// Arrows, boxes, and ovals drawn on the screen are the editor's own marks; a click makes none.
    @Test func shapesDrawnOnTheScreenAreTheEditorsMarks() throws {
        let arrow = try #require(SketchView.shape(.arrow, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 200, y: 120), constrained: false, color: .red))
        guard case .arrow(let shape) = arrow.shape else { Issue.record("not an arrow"); return }
        #expect(shape.start == CGPoint(x: 10, y: 10) && shape.end == CGPoint(x: 200, y: 120))
        #expect(arrow.style.color == .red && arrow.style.lineWidth == ScreenSketchController.LineWidth.medium.value)
        let square = try #require(SketchView.shape(.rectangle, from: .zero, to: CGPoint(x: 80, y: 40), constrained: true, color: .blue))
        guard case .rectangle(let box) = square.shape else { Issue.record("not a box"); return }
        #expect(box.rect.width == box.rect.height)
        #expect(SketchView.shape(.ellipse, from: .zero, to: CGPoint(x: 1, y: 1), constrained: false, color: .red) == nil)
    }
}
