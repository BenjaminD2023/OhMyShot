import OMSCore
import Testing
import UniformTypeIdentifiers
@testable import OMSUI

/// What the Save panel offers a screenshot to be called.
struct SavePanelTests {
    @Test func aScreenshotKeepsTheExtensionEveryOtherWayOfSavingItUses() {
        // The system prefers "jpeg" for JPEG; saving, dragging out, and uploading all say "jpg".
        #expect(SavePanel.defaultFileName(name: "Shot", type: .png) == "Shot.png")
        #expect(SavePanel.defaultFileName(name: "Shot", type: .jpeg) == "Shot.jpg")
        #expect(SavePanel.defaultFileName(name: "Shot", type: .heic) == "Shot.heic")
    }

    @Test func anotherKindOfFileTakesTheSystemsExtension() {
        #expect(SavePanel.defaultFileName(name: "Screen Recording", type: .mpeg4Movie) == "Screen Recording.mp4")
        #expect(SavePanel.defaultFileName(name: "Loop", type: .gif) == "Loop.gif")
        #expect(SavePanel.defaultFileName(name: "Untyped", type: nil) == "Untyped")
    }

    @Test func theChosenFormatComesFirstInThePanelsTypes() {
        #expect(SavePanel.pictureTypes(preferring: .heic) == [.heic, .png, .jpeg])
        #expect(SavePanel.pictureTypes(preferring: .jpeg) == [.jpeg, .png, .heic])
    }
}
