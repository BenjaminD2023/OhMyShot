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

    @Test func pickingAFormatRenamesTheFileToMatch() {
        #expect(SavePanel.renamed("Shot.png", to: .jpeg) == "Shot.jpg")
        #expect(SavePanel.renamed("Shot.JPEG", to: .heic) == "Shot.heic")
        // A name with no picture extension (hidden, or a dot of the person's own) gains one rather than losing its end.
        #expect(SavePanel.renamed("Shot", to: .png) == "Shot.png")
        #expect(SavePanel.renamed("v1.2 notes", to: .png) == "v1.2 notes.png")
    }

    @Test func thePanelsOptionsAreKeptAndTheTypedExtensionPicksTheFormat() {
        let options = ScreenshotOutput(format: .png, quality: 0.6, retinaAtOneX: true, convertsToSRGB: true, addsBorder: true)
        let typedJPEG = SavePanel.chosenOutput(for: URL(filePath: "/tmp/Shot.jpg"), options: options)
        #expect(typedJPEG == ScreenshotOutput(format: .jpeg, quality: 0.6, retinaAtOneX: true, convertsToSRGB: true, addsBorder: true))
        // An extension that is no picture format leaves the one picked.
        #expect(SavePanel.chosenOutput(for: URL(filePath: "/tmp/Shot.txt"), options: options) == options)
    }

    @MainActor @Test func changingTheFormatTellsThePanel() {
        let options = PictureSaveOptions(output: .standard)
        var told: [ImageExporter.Format] = []
        options.formatChanged = { told.append($0) }
        options.output.quality = 0.7
        options.output.format = .heic
        options.output.addsBorder = true
        #expect(told == [.heic])
    }
}
