import AppKit
import CoreGraphics
import Testing
@testable import OMSCapture

struct AutoScrollerTests {
    @Test func scrollingEventsRetainTheirSourceMarkerAndPixelDistance() throws {
        let target = AutoScrollDestination(application: .current, windowID: 1234, location: CGPoint(x: 240, y: 360))
        let event = try #require(target.event(distance: 12, axis: .vertical, source: nil))
        #expect(event.type == .scrollWheel)
        #expect(NSEvent(cgEvent: event)?.type == .scrollWheel)
        #expect(NSEvent(cgEvent: event)?.scrollingDeltaY == -12)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -12)
        #expect(event.getIntegerValueField(.eventSourceUserData) == AutoScroller.mark)
        #expect(event.flags.isEmpty)
    }

    @Test func onlyTheUserScrollingTakesOver() throws {
        func event(delta: Int32, phase: CGScrollPhase?, momentum: Int64 = 0) throws -> CGEvent {
            let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            return event
        }
        // A mouse's wheel, and a trackpad gesture beginning and going on.
        #expect(AutoScrollWheelMonitor.isScrolling(try event(delta: -4, phase: nil)))
        #expect(AutoScrollWheelMonitor.isScrolling(try event(delta: -4, phase: .began)))
        #expect(AutoScrollWheelMonitor.isScrolling(try event(delta: -4, phase: .changed)))
        // Fingers resting on the trackpad and lifted, a gesture's end, and the momentum of a flick made before.
        #expect(!AutoScrollWheelMonitor.isScrolling(try event(delta: 0, phase: .mayBegin)))
        #expect(!AutoScrollWheelMonitor.isScrolling(try event(delta: 0, phase: .cancelled)))
        #expect(!AutoScrollWheelMonitor.isScrolling(try event(delta: 0, phase: .ended)))
        #expect(!AutoScrollWheelMonitor.isScrolling(try event(delta: -4, phase: nil, momentum: 2)))
    }

    @Test func speedControlStartsImmediatelyAndRemainsBounded() {
        let slow = AutoScrollMotion.velocity(multiplier: 0.25, extent: 800)
        let normal = AutoScrollMotion.velocity(multiplier: 1, extent: 800)
        let fast = AutoScrollMotion.velocity(multiplier: 2, extent: 800)
        #expect(slow > 0 && normal > slow && fast > normal)
        #expect(fast <= 640)
        #expect(AutoScrollMotion.velocity(multiplier: 20, extent: 800) == fast)
        #expect(AutoScrollMotion.velocity(multiplier: 1, extent: 0) == 0)
    }

    @Test func slowMovementAccumulatesButPausingAndReversingDiscardResidualMotion() {
        var motion = AutoScrollMotion()
        let steps = (0..<100).map { _ in motion.step(velocity: 5, elapsed: 0.02) }
        #expect((9...10).contains(steps.reduce(0, +)))
        #expect(motion.step(velocity: 0, elapsed: 0.02) == 0)
        #expect(motion.step(velocity: 20, elapsed: 0.02) == 0)
        #expect(motion.step(velocity: -20, elapsed: 0.02) == 0)
        #expect(motion.step(velocity: -20, elapsed: 0.02) == 0)
        #expect(motion.step(velocity: -20, elapsed: 0.02) == -1)
    }

    @Test func delayedTicksNeverSendACatchUpJump() {
        var motion = AutoScrollMotion()
        #expect(motion.step(velocity: 900, elapsed: 4) == 45)
        #expect(motion.step(velocity: .infinity, elapsed: 0.03) == 0)
        #expect(AutoScrollMotion.velocity(multiplier: .nan, extent: 800) == 0)
    }
}
