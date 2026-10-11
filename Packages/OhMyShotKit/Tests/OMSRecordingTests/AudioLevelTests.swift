import CoreMedia
import Testing
@testable import OMSRecording

struct AudioLevelTests {
    @Test func aToneReadsAsItsRMS() throws {
        // The test tone: a 440 Hz sine at 0.1 of full scale, whose RMS is 0.1 / √2.
        let rms = try #require(AudioLevel.rms(of: TestMedia.audio(at: 0, frames: 4_800)))
        #expect(abs(Double(rms) - 0.1 / 2.0.squareRoot()) < 0.002, "\(rms)")
        let mono = try #require(AudioLevel.rms(of: TestMedia.audio(at: 0, frames: 4_800, channels: 1)))
        #expect(abs(mono - rms) < 0.002)
    }

    @Test func theMeterSpreadsDecibelsEvenly() {
        #expect(AudioLevel.meterValue(rms: 0) == 0)
        #expect(AudioLevel.meterValue(rms: 1) == 1)
        // -30 dBFS is halfway between -50 and -10.
        #expect(abs(AudioLevel.meterValue(rms: Float(pow(10, -30.0 / 20))) - 0.5) < 0.001)
        #expect(AudioLevel.meterValue(rms: 0.0001) == 0)
    }
}
