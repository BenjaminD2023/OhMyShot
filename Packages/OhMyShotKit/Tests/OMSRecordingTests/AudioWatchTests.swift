import Testing
@testable import OMSRecording

struct AudioWatchTests {
    @Test func nothingIsStalledInTheFirstFiveSeconds() {
        let watch = AudioWatch(startedAt: 100)
        #expect(!watch.isStalled(at: 100))
        #expect(!watch.isStalled(at: 104.9))
    }

    @Test func aMicrophoneThatNeverSendsAnythingIsStalledAfterFiveSeconds() {
        let watch = AudioWatch(startedAt: 100)
        #expect(watch.isStalled(at: 105))
        #expect(watch.isStalled(at: 160))
    }

    @Test func aMicrophoneThatKeepsSendingIsNeverStalled() {
        var watch = AudioWatch(startedAt: 0)
        // A buffer every 10 ms for a minute, checked each time.
        for step in 1...6_000 {
            let time = Double(step) / 100
            watch.bufferArrived(at: time)
            #expect(!watch.isStalled(at: time))
        }
    }

    @Test func aMicrophoneThatGoesQuietIsStalledFiveSecondsAfterItsLastBuffer() {
        var watch = AudioWatch(startedAt: 0)
        for time in stride(from: 1.0, through: 20.0, by: 1) { watch.bufferArrived(at: time) }
        #expect(!watch.isStalled(at: 24.9))
        #expect(watch.isStalled(at: 25))
    }

    @Test func aBufferEndsTheStall() {
        var watch = AudioWatch(startedAt: 0)
        #expect(watch.isStalled(at: 8))
        watch.bufferArrived(at: 8.5)
        #expect(!watch.isStalled(at: 8.5))
        #expect(!watch.isStalled(at: 13))
        #expect(watch.isStalled(at: 13.5))
    }

    @Test func nothingIsStalledWhilePaused() {
        var watch = AudioWatch(startedAt: 0)
        watch.bufferArrived(at: 3)
        watch.pause()
        #expect(!watch.isStalled(at: 8))
        #expect(!watch.isStalled(at: 600))
    }

    @Test func theFiveSecondsBeginAgainOnResume() {
        var watch = AudioWatch(startedAt: 0)
        watch.bufferArrived(at: 3)
        watch.pause()
        watch.resume(at: 60)
        #expect(!watch.isStalled(at: 60))
        #expect(!watch.isStalled(at: 64.9))
        #expect(watch.isStalled(at: 65))
    }

    @Test func buffersFromBeforeTheResumeDoNotShortenTheFiveSeconds() {
        var watch = AudioWatch(startedAt: 0)
        watch.pause()
        // The stream goes on sending while paused.
        watch.bufferArrived(at: 20)
        watch.resume(at: 30)
        #expect(!watch.isStalled(at: 34.9))
        #expect(watch.isStalled(at: 35))
    }

    @Test func aBufferAfterTheResumeEndsTheStallToo() {
        var watch = AudioWatch(startedAt: 0)
        watch.pause()
        watch.resume(at: 30)
        #expect(watch.isStalled(at: 36))
        watch.bufferArrived(at: 36.5)
        #expect(!watch.isStalled(at: 40))
    }
}
