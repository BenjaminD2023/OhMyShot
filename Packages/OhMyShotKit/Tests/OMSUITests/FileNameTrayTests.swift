import CoreGraphics
import Testing
@testable import OMSUI

/// Where a brick dropped on the file name's tray lands, and where its caret stands.
@MainActor
struct FileNameTrayTests {
    // Two rows: three bricks, then two.
    let frames = [
        CGRect(x: 0, y: 0, width: 40, height: 22), CGRect(x: 44, y: 0, width: 20, height: 22),
        CGRect(x: 68, y: 0, width: 60, height: 22),
        CGRect(x: 0, y: 26, width: 50, height: 22), CGRect(x: 54, y: 26, width: 30, height: 22),
    ]

    @Test func aDropLandsBeforeOrAfterTheBrickByItsHalf() {
        #expect(FileNameSettings.gap(at: CGPoint(x: 10, y: 10), frames: frames) == 0)
        #expect(FileNameSettings.gap(at: CGPoint(x: 30, y: 10), frames: frames) == 1)
        #expect(FileNameSettings.gap(at: CGPoint(x: 200, y: 10), frames: frames) == 3)
        #expect(FileNameSettings.gap(at: CGPoint(x: 80, y: 40), frames: frames) == 5)
        #expect(FileNameSettings.gap(at: CGPoint(x: 5, y: 36), frames: frames) == 3)
    }

    @Test func aDropBelowTheLastRowLandsInIt() {
        #expect(FileNameSettings.gap(at: CGPoint(x: 60, y: 70), frames: frames) == 4)
        #expect(FileNameSettings.gap(at: .zero, frames: []) == 0)
    }

    @Test func theCaretStandsBetweenBricksAndAtTheEndOfARow() {
        #expect(FileNameSettings.caret(forGap: 1, frames: frames)?.minX == 42)
        #expect(FileNameSettings.caret(forGap: 3, frames: frames)?.minX == 130)
        #expect(FileNameSettings.caret(forGap: 3, frames: frames)?.minY == 0)
        #expect(FileNameSettings.caret(forGap: 5, frames: frames)?.minY == 26)
        #expect(FileNameSettings.caret(forGap: 0, frames: []) == nil)
    }
}
