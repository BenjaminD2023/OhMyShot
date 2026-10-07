import Testing
@testable import OMSCore

struct ActiveResourcesTests {
    @Test func leasesAreCountedUntilTheyEnd() {
        let registry = ActiveResources()
        let first = registry.acquire(.timer)
        let second = registry.acquire(.timer)
        let stream = registry.acquire(.captureStream)
        #expect(registry.snapshot == [.timer: 2, .captureStream: 1])

        first.end()
        stream.end()
        #expect(registry.snapshot == [.timer: 1])

        second.end()
        #expect(registry.isIdle)
    }

    @Test func endingTwiceReleasesOnce() {
        let registry = ActiveResources()
        let kept = registry.acquire(.window)
        let lease = registry.acquire(.window)
        lease.end()
        lease.end()
        #expect(registry.snapshot == [.window: 1])
        kept.end()
    }

    @Test func droppedLeasesReleaseThemselves() {
        let registry = ActiveResources()
        do {
            _ = registry.acquire(.eventMonitor)
        }
        #expect(registry.isIdle)
    }
}
