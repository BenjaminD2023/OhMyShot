import AppKit
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

    @MainActor @Test func watermarkCheckboxAppearsOnlyWhenWatermarkIsConfiguredAndTogglesOutput() {
        let without = PictureSaveOptions(output: .standard)
        let viewWithout = PictureSaveOptionsView(options: without)
        #expect(viewWithout.watermark.isHidden)

        let blank = PictureSaveOptions(output: .standard, availableWatermark: Watermark(text: "   "))
        let viewBlank = PictureSaveOptionsView(options: blank)
        #expect(viewBlank.watermark.isHidden)

        let wm = Watermark(text: "Confidential", tone: .light, opacity: 0.25, size: 0.05)
        let enabled = PictureSaveOptions(output: ScreenshotOutput(watermark: wm))
        let viewEnabled = PictureSaveOptionsView(options: enabled)
        #expect(!viewEnabled.watermark.isHidden)
        #expect(viewEnabled.watermark.state == .on)
        viewEnabled.watermark.state = .off
        viewEnabled.watermark.sendAction(viewEnabled.watermark.action, to: viewEnabled.watermark.target)
        #expect(enabled.output.watermark == nil)
        viewEnabled.watermark.state = .on
        viewEnabled.watermark.sendAction(viewEnabled.watermark.action, to: viewEnabled.watermark.target)
        #expect(enabled.output.watermark == wm)

        let optIn = PictureSaveOptions(output: .standard, availableWatermark: wm)
        let viewOptIn = PictureSaveOptionsView(options: optIn)
        #expect(!viewOptIn.watermark.isHidden)
        #expect(viewOptIn.watermark.state == .off)
        viewOptIn.watermark.state = .on
        viewOptIn.watermark.sendAction(viewOptIn.watermark.action, to: viewOptIn.watermark.target)
        #expect(optIn.output.watermark == wm)
    }
}
