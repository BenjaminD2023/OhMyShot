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
}
