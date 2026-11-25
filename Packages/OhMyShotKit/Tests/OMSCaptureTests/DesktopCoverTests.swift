import Testing
@testable import OMSCapture
@testable import OMSCore

@MainActor
struct DesktopCoverTests {
    private func makeCover() -> DesktopCover {
        let cover = DesktopCover(topology: DisplayTopology(), capturer: ScreenCapturer(content: ShareableContentCache()))
        cover.canReadScreen = { false }
        return cover
    }

    @Test func temporaryHideIsReferenceCountedAndTearsDownCleanly() {
        let cover = makeCover()
        defer {
            cover.setShown(false)
            while cover.isTemporarilyHidden { cover.endTemporaryHide() }
        }

        #expect(!cover.isShown)
        #expect(!cover.isTemporarilyHidden)

        // Extra end before any begin is a safe no-op.
        cover.endTemporaryHide()
        #expect(!cover.isShown)

        cover.beginTemporaryHide()
        #expect(cover.isShown)
        #expect(cover.isTemporarilyHidden)

        // Nested temporary hides keep the cover up until every lease ends.
        cover.beginTemporaryHide()
        #expect(cover.isShown)

        cover.endTemporaryHide()
        #expect(cover.isShown)
        #expect(cover.isTemporarilyHidden)

        cover.endTemporaryHide()
        #expect(!cover.isShown)
        #expect(!cover.isTemporarilyHidden)
        #expect(cover.windowIDs.isEmpty)
    }

    @Test func temporaryHideDoesNotClobberPersistentDesktopHide() {
        let cover = makeCover()
        defer {
            cover.setShown(false)
            while cover.isTemporarilyHidden { cover.endTemporaryHide() }
        }

        // Persistent hide stays on after a temporary hide finishes.
        cover.setShown(true)
        #expect(cover.isShown)
        cover.beginTemporaryHide()
        cover.endTemporaryHide()
        #expect(cover.isShown)

        // Turning persistent hide off during a temporary hide waits until the temporary hide ends.
        cover.beginTemporaryHide()
        cover.setShown(false)
        #expect(cover.isShown)
        cover.endTemporaryHide()
        #expect(!cover.isShown)

        // Turning persistent hide on during a temporary hide keeps the cover up after temporary hide ends.
        cover.beginTemporaryHide()
        cover.setShown(true)
        cover.endTemporaryHide()
        #expect(cover.isShown)
        cover.setShown(false)
        #expect(!cover.isShown)
    }
}
