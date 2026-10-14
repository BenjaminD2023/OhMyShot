import Testing
@testable import OMSCapture

struct AutoScrollWatchTests {
    /// How the capture stands at a look.
    private struct Capture {
        var settled = 0
        var views = 0
        var busy: Duration = .zero
        var taking: Duration = .zero
        var isInBlank = false
        var isPulled = false

        /// A quarter second of the page coming in as fast as it is pushed: fifteen views of 10 ms each.
        mutating func keepsUp() {
            settled += AutoScrollWatchTests.push
            views += 15
            busy += .milliseconds(150)
        }
    }

    /// What Auto-scroll pushes in a quarter second at 1× on an area 813 pt long at 2×: 568 px a second.
    private static let push = 142
    private static let extent = 1626.0

    /// Looks every quarter second for `seconds` while Auto-scroll pushes on, `quarter` telling what the capture did
    /// meanwhile: the verdicts but going, and when.
    private static func watch(
        seconds: Double, _ quarter: (_ time: Double, _ capture: inout Capture) -> Void
    ) -> [(time: Double, verdict: AutoScrollWatch.Verdict)] {
        var watch = AutoScrollWatch(extent: extent)
        var capture = Capture()
        var told: [(Double, AutoScrollWatch.Verdict)] = []
        for look in 1...Int(seconds * 4) {
            let time = Double(look) / 4
            quarter(time, &capture)
            let verdict = watch.look(AutoScrollWatch.Sample(
                time: .milliseconds(look * 250), pushed: Double(look * push), settled: capture.settled, views: capture.views, busy: capture.busy,
                taking: capture.taking, isInBlank: capture.isInBlank, isPulled: capture.isPulled
            ))
            if verdict != .going { told.append((time, verdict)) }
            if case .stopped = verdict { break }
        }
        return told
    }

    private static func stoppedAt(_ told: [(time: Double, verdict: AutoScrollWatch.Verdict)]) -> Double? {
        told.first { if case .stopped = $0.verdict { true } else { false } }?.time
    }

    @Test func aPageThatKeepsComingIsNeverStopped() {
        #expect(Self.watch(seconds: 30) { _, capture in capture.keepsUp() }.isEmpty)
    }

    @Test func aPageThatStopsIsStoppedOnceFourTenthsOfTheAreaArePushedOntoTwice() {
        // The page ends at 2 s: no more views, the picture as it is. Four tenths of the area take 1.15 s to push: quiet
        // at the first look that could tell, stopped at the next, afresh.
        let told = Self.watch(seconds: 10) { time, capture in if time <= 2 { capture.keepsUp() } }
        #expect(told.first.map { $0.time > 3 && $0.time <= 3.5 && $0.verdict == .quiet(pushed: 710, got: 0) } == true, "\(told)")
        let stopped = Self.stoppedAt(told)
        #expect(stopped.map { $0 > 4.5 && $0 <= 5 } == true, "\(told)")
        #expect(told.count == 2, "\(told)")
    }

    @Test func anAppStandingStillAMomentIsNoEnd() {
        // Live: the page stood still 1.1 s, busy drawing, then caught up with all it was pushed at once. Quiet once,
        // never stopped.
        var owed = 0
        let told = Self.watch(seconds: 12) { time, capture in
            if time > 2, time <= 3.25 {
                owed += Self.push
            } else {
                capture.settled += owed
                owed = 0
                capture.keepsUp()
            }
        }
        #expect(Self.stoppedAt(told) == nil, "\(told)")
        #expect(told.contains { if case .quiet = $0.verdict { true } else { false } }, "\(told)")
    }

    @Test func aBlankStretchIsPushedThroughBeforeItIsTakenForTheEnd() {
        // Into a blank stretch at 2 s, the view nothing but the blank and the stream sending nothing, two and a half of
        // the area's lengths of it: what follows comes in after it, and Auto-scroll is never stopped.
        let through = 2 + 2.5 * Self.extent / 568
        let told = Self.watch(seconds: 20) { time, capture in
            if time <= 2 || time > through {
                capture.isInBlank = false
                capture.keepsUp()
            } else {
                capture.isInBlank = true
            }
        }
        #expect(told.isEmpty, "\(told)")
    }

    @Test func aBlankStretchWithoutEndIsTheEndOnceThreeAreasArePushedThrough() {
        // A page ending in a blank margin taller than the view: stopped, three of the area's lengths pushed into it on.
        let told = Self.watch(seconds: 20) { time, capture in
            if time <= 2 { capture.keepsUp() } else { capture.isInBlank = true }
        }
        let stopped = Self.stoppedAt(told)
        let patience = 2.25 + 3 * Self.extent / 568
        #expect(stopped.map { $0 >= patience + 1.15 && $0 < patience + 2 } == true, "\(told), patience to \(patience)")
    }

    @Test func pulledPastTheEndStopsAtOnceThoughBlank() {
        // The stitcher never says both (a pull is no blank stretch), but should it: the pull is the end.
        let told = Self.watch(seconds: 10) { time, capture in
            if time <= 2 {
                capture.keepsUp()
            } else {
                capture.isInBlank = true
                capture.isPulled = true
            }
        }
        #expect(Self.stoppedAt(told).map { $0 <= 3.5 } == true, "\(told)")
    }

    @Test func pulledPastTheEndStopsAtOnceThoughTheCaptureIsBehind() {
        // A slow build at the page's end: the pull seen, and the views of it creeping still slow to take in. The pull is
        // the end; it is not let off as a capture behind.
        let told = Self.watch(seconds: 12) { time, capture in
            if time <= 2 {
                capture.keepsUp()
            } else {
                capture.isPulled = true
                capture.views += 1
                capture.busy += .milliseconds(250)
            }
        }
        #expect(!told.contains { $0.verdict == .behind }, "\(told)")
        #expect(Self.stoppedAt(told).map { $0 <= 3.5 } == true, "\(told)")
    }

    @Test func aCaptureBehindThePageIsLetOffUntilItCatchesUp() {
        // From 2 s for two seconds, views of 400 ms each, the stream dropping the frames between: the picture comes in
        // late, all at once. Never stopped.
        var owed = 0
        let told = Self.watch(seconds: 12) { time, capture in
            if time > 2, time <= 4 {
                owed += Self.push
                if Int(time * 4) % 2 == 0 {
                    capture.views += 1
                    capture.busy += .milliseconds(400)
                }
                capture.taking = .milliseconds(200)
            } else {
                capture.taking = .zero
                capture.settled += owed
                owed = 0
                capture.keepsUp()
            }
        }
        #expect(Self.stoppedAt(told) == nil, "\(told)")
        #expect(told.contains { $0.verdict == .behind }, "\(told)")
    }

    @Test func aCaptureBehindForGoodIsStoppedAfterThreeLooks() {
        // A video playing past the page's end in a slow build: views keep coming, each slow, and the picture never grows.
        let told = Self.watch(seconds: 30) { time, capture in
            if time <= 2 {
                capture.keepsUp()
            } else {
                capture.views += 1
                capture.busy += .milliseconds(250)
            }
        }
        #expect(told.map(\.verdict).filter { $0 == .behind }.count == 3, "\(told)")
        #expect(Self.stoppedAt(told) != nil, "\(told)")
    }

    @Test func aViewTakingLongIsBehindThoughNoneFinished() {
        // One view taken in for a second and more: no view finished in the window, the one under way says enough.
        var watch = AutoScrollWatch(extent: Self.extent)
        var verdicts: [AutoScrollWatch.Verdict] = []
        for look in 1...8 {
            verdicts.append(watch.look(AutoScrollWatch.Sample(
                time: .milliseconds(look * 250), pushed: Double(look * Self.push), settled: 0, views: 1, busy: .zero,
                taking: .milliseconds(look * 250)
            )))
        }
        #expect(verdicts.contains(.behind), "\(verdicts)")
        #expect(!verdicts.contains { if case .stopped = $0 { true } else { false } }, "\(verdicts)")
    }

    @Test func movingTheGestureStartsTheWatchAfresh() {
        // Stopped at 2 s; the gesture moved at the first quiet look: the watch waits the whole while again before it
        // tells, and tells quiet again, not stopped.
        var watch = AutoScrollWatch(extent: Self.extent)
        var settled = 0
        var first: Double?
        var second: Double?
        for look in 1...60 {
            let time = Double(look) / 4
            if time <= 2 { settled += Self.push }
            let verdict = watch.look(AutoScrollWatch.Sample(
                time: .milliseconds(look * 250), pushed: Double(look * Self.push), settled: settled, views: min(look, 8) * 15,
                busy: .milliseconds(min(look, 8) * 150)
            ))
            guard case .quiet = verdict else { continue }
            if first == nil {
                first = time
                watch.restart()
            } else {
                second = time
                break
            }
        }
        guard let first, let second else {
            Issue.record("stopped at \(String(describing: first)), then \(String(describing: second))")
            return
        }
        #expect(second - first >= 1.15, "stopped at \(first), then \(second)")
    }
}
