import CoreGraphics
import Foundation
import Testing
@testable import OMSAnnotate

struct AnnotationModelTests {
    @Test func documentsRoundTripThroughJSON() throws {
        var document = AnnotationDocument(pixelSize: CGSize(width: 800, height: 600), scale: 2, items: [
            Annotation(shape: .arrow(Arrow(start: .zero, end: CGPoint(x: 100, y: 50), bend: 12, head: .tapered)), style: Style()),
            Annotation(shape: .line(Line(start: .zero, end: CGPoint(x: 10, y: 10), dashed: true)), style: Style(color: .blue)),
            Annotation(shape: .rectangle(Box(rect: CGRect(x: 1, y: 2, width: 3, height: 4), filled: true, cornerRadius: 6)), style: Style()),
            Annotation(shape: .ellipse(Box(rect: CGRect(x: 1, y: 2, width: 3, height: 4))), style: Style()),
            Annotation(shape: .pen(Stroke(points: [.zero, CGPoint(x: 1, y: 1)])), style: Style()),
            Annotation(shape: .highlighter(Stroke(points: [.zero])), style: Style(color: .marker, lineWidth: 18, shadow: false)),
            Annotation(shape: .text(TextBlock(origin: CGPoint(x: 5, y: 5), string: "标注 ✨", fontSize: 24, look: .label, width: 300)), style: Style()),
            Annotation(shape: .counter(Counter(center: CGPoint(x: 9, y: 9), value: 3, numbering: .roman)), style: Style()),
            Annotation(shape: .redaction(Redaction(rect: CGRect(x: 0, y: 0, width: 50, height: 20), method: .pixelate)), style: Style()),
            Annotation(shape: .spotlight(Spot(rect: CGRect(x: 0, y: 0, width: 50, height: 20), oval: true)), style: Style()),
        ])
        document.canvas = CGRect(x: -10, y: 0, width: 700, height: 600)
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: data)
        #expect(decoded == document)
    }

    @Test func countersNumberLettersAndRomanNumerals() {
        func label(_ value: Int, _ numbering: Counter.Numbering) -> String {
            Counter(center: .zero, value: value, numbering: numbering).label
        }
        #expect(label(1, .numbers) == "1")
        #expect(label(12, .numbers) == "12")
        #expect(label(1, .letters) == "A")
        #expect(label(26, .letters) == "Z")
        #expect(label(27, .letters) == "AA")
        #expect(label(4, .roman) == "IV")
        #expect(label(9, .roman) == "IX")
        #expect(label(1994, .roman) == "MCMXCIV")
    }

    @Test func theNextCounterFollowsTheHighestOfItsNumbering() {
        var document = AnnotationDocument(pixelSize: CGSize(width: 10, height: 10), scale: 1)
        #expect(document.nextCounterValue(for: .numbers) == 1)
        document.items = [3, 1].map { Annotation(shape: .counter(Counter(center: .zero, value: $0)), style: Style()) }
        #expect(document.nextCounterValue(for: .numbers) == 4)
        // Each numbering counts on its own: after 1 and 3, letters start at A.
        #expect(document.nextCounterValue(for: .letters) == 1)
        document.items.append(Annotation(shape: .counter(Counter(center: .zero, value: 1, numbering: .letters)), style: Style()))
        #expect(document.nextCounterValue(for: .letters) == 2)
        #expect(document.nextCounterValue(for: .numbers) == 4)
        #expect(document.nextCounterValue(for: .roman) == 1)
    }

    @Test func arrowsAreHitAlongTheirLengthOnly() {
        let arrow = Annotation(shape: .arrow(Arrow(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 210, y: 10))), style: Style(lineWidth: 4))
        #expect(arrow.contains(CGPoint(x: 100, y: 12), tolerance: 4, scale: 1))
        #expect(!arrow.contains(CGPoint(x: 100, y: 30), tolerance: 4, scale: 1))
        // The head is wider than the body.
        #expect(arrow.contains(CGPoint(x: 200, y: 17), tolerance: 1, scale: 1))
    }

    @Test func bentArrowsAreHitOnTheirCurve() {
        let arrow = Annotation(shape: .arrow(Arrow(start: CGPoint(x: 0, y: 100), end: CGPoint(x: 200, y: 100), bend: 40)), style: Style(lineWidth: 4))
        // Bending 40 to the right of travel (rightward) puts the middle 40 below the line on screen.
        #expect(ArrowPath.middle(of: arrow.arrowValue!).y == 140)
        #expect(arrow.contains(CGPoint(x: 100, y: 140), tolerance: 3, scale: 1))
        #expect(!arrow.contains(CGPoint(x: 100, y: 100), tolerance: 3, scale: 1))
    }

    @Test func areasCatchThePointerOnlyAtTheirEdgesUnlessAsked() {
        let redaction = Annotation(shape: .redaction(Redaction(rect: CGRect(x: 0, y: 0, width: 100, height: 100))), style: Style())
        #expect(redaction.contains(CGPoint(x: 50, y: 50), tolerance: 4, scale: 1))
        #expect(!redaction.contains(CGPoint(x: 50, y: 50), tolerance: 4, scale: 1, interior: false))
        #expect(redaction.contains(CGPoint(x: 2, y: 50), tolerance: 4, scale: 1, interior: false))
        let outlined = Annotation(shape: .rectangle(Box(rect: CGRect(x: 0, y: 0, width: 100, height: 100))), style: Style(lineWidth: 2))
        #expect(!outlined.contains(CGPoint(x: 50, y: 50), tolerance: 4, scale: 1))
        #expect(outlined.contains(CGPoint(x: 99, y: 50), tolerance: 4, scale: 1))
    }

    @Test func dragsMakeTheToolsMarks() throws {
        let settings = ToolSettings()
        let square = try #require(AnnotationTool.rectangle.mark(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 30), constrained: true, settings: settings))
        guard case .rectangle(let box) = square.shape else { Issue.record("not a rectangle"); return }
        #expect(box.rect == CGRect(x: 10, y: 10, width: 40, height: 40))
        let backwards = try #require(AnnotationTool.redact.mark(from: CGPoint(x: 50, y: 30), to: CGPoint(x: 10, y: 10), constrained: false, settings: settings))
        #expect(backwards.bounds(scale: 1) == CGRect(x: 10, y: 10, width: 40, height: 20))
        let line = try #require(AnnotationTool.line.mark(from: .zero, to: CGPoint(x: 100, y: 8), constrained: true, settings: settings))
        guard case .line(let snapped) = line.shape else { Issue.record("not a line"); return }
        #expect(abs(snapped.end.y) < 0.001)
        #expect(AnnotationTool.pen.mark(from: .zero, to: CGPoint(x: 1, y: 1), constrained: false, settings: settings) == nil)
    }

    @Test func cornersResizeAndKeepProportionsWithShift() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(Geometry.resized(rect, dragging: .bottomRight, to: CGPoint(x: 150, y: 60), keepingAspect: false) == CGRect(x: 0, y: 0, width: 150, height: 60))
        #expect(Geometry.resized(rect, dragging: .bottomRight, to: CGPoint(x: 200, y: 60), keepingAspect: true) == CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(Geometry.resized(rect, dragging: .left, to: CGPoint(x: 120, y: 0), keepingAspect: false) == CGRect(x: 100, y: 0, width: 20, height: 50))
    }

    @Test func dragsMoveEveryKindOfMark() {
        let marks: [Annotation] = [
            Annotation(shape: .arrow(Arrow(start: .zero, end: CGPoint(x: 50, y: 0))), style: Style()),
            Annotation(shape: .pen(Stroke(points: [.zero, CGPoint(x: 20, y: 20)])), style: Style()),
            Annotation(shape: .text(TextBlock(origin: .zero, string: "A")), style: Style()),
            Annotation(shape: .counter(Counter(center: CGPoint(x: 20, y: 20), value: 1)), style: Style()),
            Annotation(shape: .spotlight(Spot(rect: CGRect(x: 0, y: 0, width: 10, height: 10))), style: Style()),
        ]
        for mark in marks {
            let before = mark.bounds(scale: 1)
            let after = mark.translated(by: CGSize(width: 7, height: -3)).bounds(scale: 1)
            #expect(abs(after.minX - before.minX - 7) < 0.01 && abs(after.minY - before.minY + 3) < 0.01)
        }
    }

    @Test func settingsFollowASelectedMarkAndRestyleIt() {
        let label = Annotation(shape: .text(TextBlock(origin: .zero, string: "x", fontSize: 30, look: .label)), style: Style(color: .blue, lineWidth: 2))
        var settings = ToolSettings()
        settings.adopt(label)
        #expect(settings.textLook == .label && settings.fontSize == 30 && settings.color == .blue)
        settings.textLook = .outlined
        settings.color = .green
        let restyled = settings.applied(to: label)
        guard case .text(let block) = restyled.shape else { Issue.record("not text"); return }
        #expect(block.look == .outlined && block.string == "x" && restyled.style.color == .green)
    }
}

extension Annotation {
    var arrowValue: Arrow? {
        if case .arrow(let arrow) = shape { return arrow }
        return nil
    }
}
