import AppKit
import CoreGraphics
import Testing
@testable import OMSOCR

struct SharedWorkTests {
    /// The runs made, and those stopped midway, from any task.
    private actor Runs {
        private(set) var started = 0
        private(set) var stopped = 0

        func start() -> Int {
            started += 1
            return started
        }

        func stop() { stopped += 1 }
    }

    private struct Failure: Error {}

    /// Work that doubles its key after `delay`, noting its runs.
    private func doubling(_ runs: Runs, delay: Duration = .milliseconds(150)) -> SharedWork<Int, Int> {
        SharedWork { key in
            _ = await runs.start()
            do {
                try await Task.sleep(for: delay)
            } catch {
                await runs.stop()
                throw error
            }
            return key * 2
        }
    }

    @Test func everyoneAskingWhileItRunsSharesOneRun() async throws {
        let runs = Runs()
        let work = doubling(runs)
        async let first = work.value(for: 21)
        async let second = work.value(for: 21)
        #expect(try await [first, second] == [42, 42])
        #expect(await runs.started == 1)
        // Kept: asked again, it is not run again.
        #expect(try await work.value(for: 21) == 42)
        #expect(await runs.started == 1)
        // Another key is work of its own.
        #expect(try await work.value(for: 1) == 2)
        #expect(await runs.started == 2)
    }

    @Test func aRunThatFailedIsMadeAgainTheNextTime() async throws {
        let runs = Runs()
        let work = SharedWork<Int, Int> { key in
            if await runs.start() == 1 { throw Failure() }
            return key
        }
        await #expect(throws: Failure.self) { try await work.value(for: 7) }
        #expect(try await work.value(for: 7) == 7)
        #expect(await runs.started == 2)
    }

    @Test func oneOfTwoStoppingLeavesTheRunToTheOther() async throws {
        let runs = Runs()
        let work = doubling(runs, delay: .milliseconds(500))
        let first = Task { try await work.value(for: 1) }
        let second = Task { try await work.value(for: 1) }
        try await Task.sleep(for: .milliseconds(40))
        let clock = ContinuousClock(), cancelled = clock.now
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        // It stops waiting at once, not when the run ends.
        #expect(clock.now - cancelled < .milliseconds(250))
        #expect(try await second.value == 2)
        #expect(await runs.started == 1)
        #expect(await runs.stopped == 0)
    }

    @Test func theRunStopsWhenNobodyWaitsForItAndIsMadeAgainWhenAsked() async throws {
        let runs = Runs()
        let work = doubling(runs)
        let asker = Task { try await work.value(for: 1) }
        try await Task.sleep(for: .milliseconds(40))
        asker.cancel()
        await #expect(throws: CancellationError.self) { try await asker.value }
        for _ in 0..<50 where await runs.stopped == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await runs.stopped == 1)
        #expect(try await work.value(for: 1) == 2)
        #expect(await runs.started == 2)
    }

    @Test func aCallerCancelledBeforeAskingStartsNothing() async {
        let runs = Runs()
        let work = doubling(runs)
        let asker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await work.value(for: 1)
        }
        await #expect(throws: CancellationError.self) { try await asker.value }
        #expect(await runs.started == 0)
    }
}

struct TextRecognitionTests {
    /// The readings made by each model, from any task.
    private actor Readings {
        private(set) var counts: [TextRecognition.Model: Int] = [:]
        func record(_ model: TextRecognition.Model) { counts[model, default: 0] += 1 }
    }

    @Test func theSuggestionsAndTheLinesShareTheChineseReading() async throws {
        let size = CGSize(width: 640, height: 150)
        let font = NSFont.systemFont(ofSize: 24)
        let picture = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            ("Mail: hello@example.com" as NSString).draw(at: CGPoint(x: 30, y: 30), withAttributes: attributes)
            ("截图完成后可以直接拖出" as NSString).draw(at: CGPoint(x: 30, y: 90), withAttributes: attributes)
            return true
        }
        var rect = CGRect(origin: .zero, size: size)
        let image = try #require(picture.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let readings = Readings()
        let recognition = TextRecognition(image) { model in
            await readings.record(model)
            return try await TextRecognition.recognize(image, by: model, timeout: .seconds(20))
        }
        // Both at once, as when the tools are picked one after the other before either is read.
        async let suggestions = SensitiveTextScanner().scan(recognition)
        async let lines = TextLineReader().read(recognition)
        let (found, placed) = try await (suggestions, lines)
        #expect(found.contains { $0.kind == .email }, "\(found.map(\.kind))")
        #expect(placed.count == 2, "\(placed)")
        // And again later: what was read is kept.
        #expect(try await TextLineReader().read(recognition) == placed)
        #expect(await readings.counts == [.latin: 1, .chinese: 1])
    }
}

extension TextRecognitionTests {
    @Test func suggestionsCarryOnWithOneReadingAndFailWithNeither() async throws {
        let size = CGSize(width: 520, height: 80)
        let picture = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("Mail: hello@example.com" as NSString).draw(at: CGPoint(x: 30, y: 24), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
            return true
        }
        var rect = CGRect(origin: .zero, size: size)
        let image = try #require(picture.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        // The Chinese reading failing leaves the Latin one's matches.
        let latinOnly = TextRecognition(image) { model in
            if model == .chinese { throw CocoaError(.fileReadUnknown) }
            return try await TextRecognition.recognize(image, by: model, timeout: .seconds(20))
        }
        #expect(try await SensitiveTextScanner().scan(latinOnly).contains { $0.kind == .email })
        // Neither reading made: nothing was read, and the scan says so rather than finding nothing.
        let unread = TextRecognition(image) { _ in throw CocoaError(.fileReadUnknown) }
        await #expect(throws: CocoaError.self) { try await SensitiveTextScanner().scan(unread) }
        await #expect(throws: CocoaError.self) { try await TextLineReader().read(unread) }
    }
}
