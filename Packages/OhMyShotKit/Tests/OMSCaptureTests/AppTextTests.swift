import CoreGraphics
import Foundation
@testable import OMSCapture
import OMSCore
import Testing

/// Asking the apps under a picture for their text at its lines, against a made-up screen.
struct AppTextTests {
    /// A screen of elements in Core Graphics' global space, each with lines or a text.
    private nonisolated final class Screen: AppTextSource {
        struct Thing {
            var frame: CGRect
            var app: pid_t
            /// Lines top to bottom, each with its frame; empty for an element without lines.
            var lines: [(frame: CGRect, text: String)] = []
            var text: String?
            var secure = false
        }

        var elements: [Thing] = []
        /// Front to back: the app and whether its window may be clear.
        var windows: [(app: pid_t, frame: CGRect, clear: Bool)] = []
        var asked: [CGPoint] = []
        var lineQuestions = 0

        func apps(at point: CGPoint) -> [pid_t] {
            var apps: [pid_t] = []
            for window in windows where window.frame.contains(point) {
                apps.append(window.app)
                if !window.clear { break }
            }
            return apps
        }

        func element(at point: CGPoint, in app: pid_t) -> Int? {
            asked.append(point)
            return elements.indices.last { elements[$0].app == app && elements[$0].frame.contains(point) }
        }

        func isSecure(_ element: Int) -> Bool { elements[element].secure }

        func line(of element: Int, at point: CGPoint) -> (start: Int, text: String, bounds: CGRect?)? {
            let lines = elements[element].lines
            guard !lines.isEmpty else { return nil }
            lineQuestions += 1
            guard let index = lines.firstIndex(where: { $0.frame.minY <= point.y && point.y < $0.frame.maxY }) else { return nil }
            return (lines[..<index].reduce(0) { $0 + $1.text.count + 1 }, lines[index].text, lines[index].frame)
        }

        func text(of element: Int) -> String? { elements[element].text }

        func frame(of element: Int) -> CGRect? { elements[element].frame }

        func name(of app: pid_t) -> String { "App \(app)" }
    }

    private static let later = ContinuousClock.now + .seconds(60)

    @Test func linesAreAskedAboutWhereThePictureShowsThem() {
        let screen = Screen()
        screen.windows = [(1, CGRect(x: 0, y: 0, width: 1000, height: 800), false)]
        screen.elements = [.init(frame: CGRect(x: 100, y: 50, width: 400, height: 300), app: 1, text: "Plan Storage")]
        // The picture's area starts at (100, 50) in points, two pixels a point.
        let box = CGRect(x: 20, y: 40, width: 200, height: 20)
        let reading = AppText.gather([box], frame: CGRect(x: 100, y: 50, width: 400, height: 300), scale: 2, pid: nil, from: screen, until: Self.later)
        #expect(reading.lines == [AppTextPieces(box: box, pieces: ["Plan Storage"], app: "App 1")])
        #expect(!screen.asked.isEmpty)
        #expect(screen.asked.allSatisfy { CGRect(x: 110, y: 70, width: 100, height: 10).contains($0) && $0.y == 75 })
    }

    @Test func aLineOfATextViewIsAskedForOnce() {
        let screen = Screen()
        screen.windows = [(1, CGRect(x: 0, y: 0, width: 1000, height: 800), false)]
        screen.elements = [.init(
            frame: CGRect(x: 0, y: 0, width: 800, height: 400), app: 1,
            lines: [(CGRect(x: 0, y: 0, width: 800, height: 20), "first line"), (CGRect(x: 0, y: 20, width: 800, height: 20), "    let list = items")]
        )]
        let boxes = [CGRect(x: 10, y: 0, width: 600, height: 20), CGRect(x: 40, y: 20, width: 600, height: 20)]
        let reading = AppText.gather(boxes, frame: CGRect(x: 0, y: 0, width: 800, height: 400), scale: 1, pid: nil, from: screen, until: Self.later)
        #expect(reading.lines.map(\.pieces) == [["first line"], ["    let list = items"]])
        // Each line reaches across its box: one point each.
        #expect(screen.lineQuestions == 2)
        #expect(reading.points == 2)
        // A line narrower than the box leaves the points along it asked; they find the same line.
        screen.elements[0].lines[0].frame.size.width = 300
        let narrow = AppText.gather(boxes, frame: CGRect(x: 0, y: 0, width: 800, height: 400), scale: 1, pid: nil, from: screen, until: Self.later)
        #expect(narrow.lines.map(\.pieces) == [["first line"], ["    let list = items"]])
        #expect(narrow.points > 3)
        #expect(screen.lineQuestions == 4)
    }

    @Test func placesAlongALineAreItsPiecesLeftToRight() {
        let screen = Screen()
        screen.windows = [(1, CGRect(x: 0, y: 0, width: 1000, height: 800), false)]
        screen.elements = [
            .init(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), app: 1),
            .init(frame: CGRect(x: 0, y: 0, width: 200, height: 20), app: 1, text: "Name"),
            .init(frame: CGRect(x: 400, y: 0, width: 200, height: 20), app: 1, text: "Size"),
        ]
        let reading = AppText.gather([CGRect(x: 0, y: 0, width: 600, height: 20)], frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 1, pid: nil, from: screen, until: Self.later)
        #expect(reading.lines.map(\.pieces) == [["Name", "Size"]])
        // Two elements side by side that say the same, as a window's title does: once.
        screen.elements[2].text = "Name"
        let twice = AppText.gather([CGRect(x: 0, y: 0, width: 600, height: 20)], frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 1, pid: nil, from: screen, until: Self.later)
        #expect(twice.lines.map(\.pieces) == [["Name"]])
    }

    @Test func aPasswordFieldIsPassedOver() {
        let screen = Screen()
        screen.windows = [(1, CGRect(x: 0, y: 0, width: 1000, height: 800), false)]
        screen.elements = [.init(frame: CGRect(x: 0, y: 0, width: 600, height: 20), app: 1, text: "hunter2", secure: true)]
        let reading = AppText.gather([CGRect(x: 0, y: 0, width: 600, height: 20)], frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scale: 1, pid: nil, from: screen, until: Self.later)
        #expect(reading.lines.isEmpty)
        #expect(reading.secure == 1)
        #expect(screen.asked.count == 1)
    }

    @Test func theAppInFrontIsAskedAndAClearWindowLetsTheOneBehindAnswer() {
        let screen = Screen()
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        screen.elements = [
            .init(frame: frame, app: 1, text: "Behind"),
            .init(frame: frame, app: 2, text: "In front"),
        ]
        screen.windows = [(2, frame, false), (1, frame, false)]
        let box = [CGRect(x: 0, y: 0, width: 100, height: 20)]
        #expect(AppText.gather(box, frame: frame, scale: 1, pid: nil, from: screen, until: Self.later).lines.map(\.pieces) == [["In front"]])
        // A window's own app is asked wherever others lie.
        #expect(AppText.gather(box, frame: frame, scale: 1, pid: 1, from: screen, until: Self.later).lines.map(\.pieces) == [["Behind"]])
        // A clear shelf in front that has nothing there.
        screen.elements[1].frame = CGRect(x: 500, y: 0, width: 100, height: 100)
        screen.windows = [(2, frame, true), (1, frame, false)]
        #expect(AppText.gather(box, frame: frame, scale: 1, pid: nil, from: screen, until: Self.later).lines.map(\.pieces) == [["Behind"]])
    }

    @Test func outOfTimeItStops() {
        let screen = Screen()
        screen.windows = [(1, CGRect(x: 0, y: 0, width: 1000, height: 800), false)]
        screen.elements = [.init(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), app: 1, text: "Plan")]
        let reading = AppText.gather([CGRect(x: 0, y: 0, width: 100, height: 20)], frame: .zero, scale: 1, pid: nil, from: screen, until: .now - .seconds(1))
        #expect(reading.outOfTime)
        #expect(reading.lines.isEmpty)
        #expect(screen.asked.isEmpty)
    }

    @Test func anAreaOnTheDisplayBesideThePrimaryOneIsAskedWhereAccessibilityPlacesIt() {
        // The built-in display (primary) left of an ultrawide, their tops level: the ultrawide reaches below the
        // primary's bottom, so its AppKit frame starts below zero.
        let layout = DisplayLayout(displays: [
            ScreenCapturerTests.display(CGRect(x: 0, y: 0, width: 2056, height: 1329)),
            ScreenCapturerTests.display(CGRect(x: 2056, y: -111, width: 3440, height: 1440)),
        ])
        let area = CGRect(x: 2500, y: 500, width: 400, height: 300)
        // Accessibility's space: the primary's top left at the origin, y down.
        #expect(layout.flipped(area) == CGRect(x: 2500, y: 529, width: 400, height: 300))
        #expect(layout.flipped(CGRect(x: 2056, y: -111, width: 3440, height: 1440)) == CGRect(x: 2056, y: 0, width: 3440, height: 1440))
        let screen = Screen()
        screen.windows = [(1, CGRect(x: 2056, y: 0, width: 3440, height: 1440), false)]
        screen.elements = [.init(frame: CGRect(x: 2500, y: 529, width: 400, height: 40), app: 1, text: "On the ultrawide")]
        let reading = AppText.gather([CGRect(x: 20, y: 20, width: 600, height: 40)], frame: layout.flipped(area), scale: 2, pid: nil, from: screen, until: Self.later)
        #expect(reading.lines.map(\.pieces) == [["On the ultrawide"]])
        #expect(screen.asked.allSatisfy { $0.y == 529 + 20 })
    }

    @Test func shortLinesAreAskedInTheMiddleAndLongOnesAlongThem() {
        #expect(AppText.points(along: CGRect(x: 0, y: 0, width: 30, height: 20)) == [CGPoint(x: 15, y: 10)])
        let along = AppText.points(along: CGRect(x: 0, y: 0, width: 2000, height: 20))
        #expect(along.count == 8)
        #expect(along.first == CGPoint(x: 10, y: 10))
        #expect(along.last == CGPoint(x: 1990, y: 10))
        #expect(AppText.points(along: CGRect(x: 0, y: 0, width: 100, height: 20)).count == 2)
    }
}
