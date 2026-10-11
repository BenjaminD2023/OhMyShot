import Foundation
import Testing
@testable import OMSRecording

struct ReplayBufferTests {
    @Test func displaysAreBufferedWithin4096() throws {
        guard #available(macOS 27, *) else { return }
        // The ultrawide at 2x and the built-in display's scaled mode: both over H.264's 4096; one that fits.
        #expect(ReplayBuffer.size(fitting: 6880, 2880) == (4096, 1714))
        #expect(ReplayBuffer.size(fitting: 4112, 2658) == (4096, 2648))
        #expect(ReplayBuffer.size(fitting: 2880, 1800) == (2880, 1800))
        #expect(ReplayBuffer.size(fitting: 1365, 767) == (1364, 766))
    }
}
