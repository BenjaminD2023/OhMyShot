import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import OMSStudio

struct StudioTimelineInteractionTests {
    @Test func zoomKeepsThePlayheadAnchoredAndDoesNotChangeRecordingTime() {
        var viewport = StudioTimelineViewport(duration: 3_600)
        let before = viewport.position(of: 1_200, width: 800)
        viewport.zoom(by: 8, around: 1_200)
        #expect(abs(viewport.position(of: 1_200, width: 800) - before) < 0.000_001)
        #expect(abs(viewport.time(at: before, width: 800) - 1_200) < 0.000_001)
        #expect(viewport.span == 450)
        viewport.fit(1_200...1_202)
        #expect(viewport.position(of: 1_202, width: 800) - viewport.position(of: 1_200, width: 800) > 500)
        #expect(viewport.contains(1_200, 1_202))
        viewport.fit()
        #expect(viewport.range == 0...3_600 && viewport.isFit)
    }

    @Test func scrollingAndZoomingStayInsideTheRecording() {
        var viewport = StudioTimelineViewport(duration: 600)
        viewport.zoom(by: 8, around: 0)
        #expect(viewport.start == 0 && viewport.span == 75)
        viewport.scroll(to: 1_000)
        #expect(viewport.end == 600)
        viewport.scroll(to: -100)
        #expect(viewport.start == 0)
        viewport.reveal(590)
        #expect(viewport.contains(590, 590))
        viewport.fit(598...600)
        #expect(viewport.end == 600 && viewport.start >= 0)
        viewport.zoom(by: 1_000, around: 600)
        #expect(viewport.span == 1 && !viewport.canZoomIn)
        #expect(viewport.end == 600)
    }

    @Test func emptyAndSubsecondRecordingsHaveValidViewports() {
        var empty = StudioTimelineViewport(duration: .nan)
        empty.zoom(by: 2, around: 5)
        empty.fit(0...1)
        #expect(empty.range == 0...0 && empty.time(at: 200, width: 0) == 0)
        var short = StudioTimelineViewport(duration: 0.2)
        short.zoom(by: 2, around: 0.1)
        #expect(short.span == 0.2 && short.isFit && !short.canZoomIn)
    }

    @Test func thumbnailRequestsStayBoundedAndReuseFramesWhilePanning() {
        var viewport = StudioTimelineViewport(duration: 3_600)
        viewport.fit(1_200...1_220)
        let first = StudioFilmstripRequest(viewport: viewport, width: 900, aspect: 1.6)
        viewport.scroll(to: viewport.start + 1)
        let next = StudioFilmstripRequest(viewport: viewport, width: 900, aspect: 1.6)
        let firstKeys = Set(first.samples.map(\.id)), nextKeys = Set(next.samples.map(\.id))
        #expect(first.samples.count <= 65 && next.samples.count <= 65)
        #expect(!firstKeys.intersection(nextKeys).isEmpty)
        #expect(next.samples.allSatisfy { viewport.contains($0.start, $0.end) })
        #expect(next.samples.allSatisfy { $0.time >= $0.start && $0.time <= $0.end })
        #expect(nextKeys.count == next.samples.count)
        let large = StudioFilmstripRequest(viewport: StudioTimelineViewport(duration: 3_600), width: 40_000, aspect: 0.25)
        #expect(large.samples.count <= 65)
    }

    @Test func thumbnailCacheEvictsLeastRecentlyUsedAndRespectsBytes() {
        var cache = StudioFrameCache<String>(limit: 2, byteLimit: 10)
        cache.insert("a", for: 1, cost: 4)
        cache.insert("b", for: 2, cost: 4)
        #expect(cache.value(for: 1) == "a")
        cache.insert("c", for: 3, cost: 4)
        #expect(cache.value(for: 2) == nil && cache.value(for: 1) == "a")
        cache.insert("large", for: 4, cost: 8)
        #expect(cache.count == 1 && cache.byteCount == 8)
        cache.insert("too large", for: 5, cost: 11)
        #expect(cache.value(for: 5) == nil && cache.count == 1)
        cache.insert("replaced", for: 4, cost: 3)
        #expect(cache.byteCount == 3)
    }

    @Test func keyboardNavigationReachesEveryEditInTimeOrder() throws {
        let zoom = StudioProject.Zoom(start: 2, end: 3, scale: 2, isAutomatic: true)
        let layout = StudioProject.CameraSegment(start: 2, end: 4, layout: .cameraOnly)
        let items = StudioTimelineNavigation.items(zooms: [zoom], cuts: [2...2.5, 10...12], layouts: [layout])
        #expect(items.map(\.selection) == [.zoom(zoom.id), .cut(2), .cameraSegment(layout.id), .cut(10)])
        let first = try #require(StudioTimelineNavigation.adjacent(in: items, selection: .none, time: 0, forward: true))
        #expect(first.selection == .zoom(zoom.id))
        #expect(StudioTimelineNavigation.adjacent(in: items, selection: first.selection, time: 2, forward: true)?.selection == .cut(2))
        #expect(StudioTimelineNavigation.adjacent(in: items, selection: .cameraSegment(layout.id), time: 2, forward: false)?.selection == .cut(2))
        #expect(StudioTimelineNavigation.adjacent(in: items, selection: .none, time: 11, forward: false)?.selection == .cut(10))
        #expect(StudioTimelineNavigation.adjacent(in: [], selection: .none, time: 0, forward: true) == nil)
    }

    @Test func preciseTimeInputAcceptsTimecodesAndRejectsInvalidParts() {
        #expect(StudioTimeInput.parse("12.125") == 12.125)
        #expect(StudioTimeInput.parse("1:02.500") == 62.5)
        #expect(StudioTimeInput.parse("1:02:03.125") == 3_723.125)
        #expect(StudioTimeInput.parse(StudioTimeInput.format(3_723.125)) == 3_723.125)
        for invalid in ["", "NaN", "inf", "-2", "1:60", "1::2", "0.5:12", "1:02:03:04"] {
            #expect(StudioTimeInput.parse(invalid) == nil)
        }
    }

    @Test func aLateThumbnailCannotReplaceTheNewViewport() async throws {
        typealias Continuation = AsyncStream<StudioTimelineFilmstrip.Frame>.Continuation
        let streams = Mutex<[Int64: Continuation]>([:])
        let loader = StudioTimelineFilmstrip { _, samples, _ in
            AsyncStream { continuation in
                if let key = samples.first?.id { streams.withLock { $0[key] = continuation } }
            }
        }
        let source = URL(filePath: "/unused.mp4")
        var viewport = StudioTimelineViewport(duration: 100)
        viewport.fit(10...12)
        let first = StudioFilmstripRequest(viewport: viewport, width: 500, aspect: 1.6)
        viewport.fit(70...72)
        let second = StudioFilmstripRequest(viewport: viewport, width: 500, aspect: 1.6)
        let firstKey = try #require(first.samples.first?.id), secondKey = try #require(second.samples.first?.id)
        let firstTask = Task { await loader.load(source: source, request: first) }
        defer { firstTask.cancel() }
        for _ in 0..<100 where streams.withLock({ $0[firstKey] == nil }) { try await Task.sleep(for: .milliseconds(10)) }
        let firstStream = try #require(streams.withLock { $0[firstKey] })
        let secondTask = Task { await loader.load(source: source, request: second) }
        defer { secondTask.cancel() }
        for _ in 0..<100 where streams.withLock({ $0[secondKey] == nil }) { try await Task.sleep(for: .milliseconds(10)) }
        let secondStream = try #require(streams.withLock { $0[secondKey] })
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let picture = try #require(context.makeImage())
        firstStream.yield(.init(key: firstKey, image: picture))
        firstStream.finish()
        secondStream.yield(.init(key: secondKey, image: picture))
        secondStream.finish()
        await firstTask.value
        await secondTask.value
        #expect(loader.images[firstKey] == nil)
        #expect(loader.images[secondKey] != nil)
    }

    @Test func timelineLaneHitDistinguishesRulerZoomHandlesClipRangeAndCuts() {
        let viewport = StudioTimelineViewport(duration: 10)
        let zoom = StudioProject.Zoom(start: 2, end: 4, scale: 2, isAutomatic: false)
        let layout = StudioProject.CameraSegment(start: 6, end: 8, layout: .cameraOnly)
        let cuts: [ClosedRange<Double>] = [4.5...5.5]
        let width: CGFloat = 1032 // span = 1000 -> 100 pt per second, inset = 16

        #expect(StudioTimeline.laneHit(at: CGPoint(x: 200, y: 10), width: width, viewport: viewport, zooms: [zoom], cuts: cuts) == .ruler)
        #expect(StudioTimeline.laneHit(at: CGPoint(x: 16 + 200, y: 40), width: width, viewport: viewport, zooms: [zoom], cuts: cuts) == .zoomResize(zoom.id, start: true))
        #expect(StudioTimeline.laneHit(at: CGPoint(x: 16 + 300, y: 40), width: width, viewport: viewport, zooms: [zoom], cuts: cuts) == .zoomMove(zoom.id))
        #expect(StudioTimeline.laneHit(at: CGPoint(x: 16 + 500, y: 80), width: width, viewport: viewport, zooms: [zoom], cuts: cuts) == .cut(4.5))
        #expect(StudioTimeline.laneHit(at: CGPoint(x: 16 + 100, y: 80), width: width, viewport: viewport, zooms: [zoom], cuts: cuts) == .clipRange)
        #expect(StudioTimeline.laneHit(
            at: CGPoint(x: 16 + 700, y: 120), width: width, viewport: viewport, zooms: [zoom], cuts: cuts, cameraSegments: [layout]
        ) == .layoutMove(layout.id))
    }

    @Test func magneticSnappingAlignsWithinFivePointsAndRespectsCommandBypass() {
        let viewport = StudioTimelineViewport(duration: 10)
        let width: CGFloat = 1032 // span = 1000 -> 100 pt/s -> 5 pt = 0.05 s
        let candidates: [Double] = [2.0, 4.5]

        // Within 5 pt (2.03 s is 3 pt away from 2.0 s) -> snaps to 2.0
        let snapped = StudioTimeline.snappedTime(2.03, candidates: candidates, duration: 10, width: width, viewport: viewport, enabled: true)
        #expect(snapped.snapped && abs(snapped.time - 2.0) < 0.0001)

        // Outside 5 pt (2.08 s is 8 pt away from 2.0 s) -> does not snap
        let unsnapped = StudioTimeline.snappedTime(2.08, candidates: candidates, duration: 10, width: width, viewport: viewport, enabled: true)
        #expect(!unsnapped.snapped && abs(unsnapped.time - 2.08) < 0.0001)

        // Disabled (Command held) -> does not snap even within 5 pt
        let bypassed = StudioTimeline.snappedTime(2.03, candidates: candidates, duration: 10, width: width, viewport: viewport, enabled: false)
        #expect(!bypassed.snapped && abs(bypassed.time - 2.03) < 0.0001)
    }
}
