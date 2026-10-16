import Foundation
import Testing
@testable import OMSCore

struct EmailSharingTests {
    @Test func theSubjectIsTheFileNameWithoutItsExtension() {
        #expect(EmailSharing.subject(for: URL(filePath: "/tmp/OhMyShot 2026-10-17 at 10.00.00.png")) == "OhMyShot 2026-10-17 at 10.00.00")
        #expect(EmailSharing.subject(for: URL(filePath: "/tmp/Recording.mp4")) == "Recording")
    }

    @Test func anAnswerIsKeptForItsLifetimeAndThenAskedAgain() {
        var remembered = EmailSharing.Remembered(lifetime: 30)
        var asked = 0
        var system = true
        let now = Date.now
        func answer(at seconds: TimeInterval) -> Bool {
            remembered.answer(now: now.addingTimeInterval(seconds)) { asked += 1; return system }
        }

        #expect(answer(at: 0) == true)
        #expect(asked == 1)
        // The system changes its mind (an account is removed); within the lifetime the old answer stands.
        system = false
        #expect(answer(at: 10) == true)
        #expect(answer(at: 29) == true)
        #expect(asked == 1)
        // Past it, the system is asked again, and the new answer is kept in turn.
        #expect(answer(at: 31) == false)
        #expect(asked == 2)
        system = true
        #expect(answer(at: 60) == false)
        #expect(asked == 2)
        #expect(answer(at: 62) == true)
        #expect(asked == 3)
    }

    @Test func aFalseAnswerIsKeptToo() {
        var remembered = EmailSharing.Remembered(lifetime: 30)
        var asked = 0
        let now = Date.now
        for second in [0.0, 5, 20] {
            #expect(remembered.answer(now: now.addingTimeInterval(second)) { asked += 1; return false } == false)
        }
        #expect(asked == 1)
    }
}
