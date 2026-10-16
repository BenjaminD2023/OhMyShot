import Testing
@testable import OMSCore

struct RecordingVolumeTests {
    @Test func aSoundBroughtBackToFullByTheSlidersLastStepIsFull() {
        #expect(RecordingVolume.isFull(1))
        #expect(RecordingVolume.isFull(0.995))
        #expect(!RecordingVolume.isFull(0.99))
        #expect(!RecordingVolume.isFull(0))
    }
}
