import Foundation
import OMSCore
import Testing
@testable import OMSUI

/// What the Settings sidebar's search finds, and where it lands.
@MainActor
struct SettingsSearchTests {
    /// Every row a pane draws is in its pane's search rows, so a search can't miss a row added later: the panes' source
    /// is read for the titles their rows are given.
    @Test func everyRowAPaneDrawsCanBeFound() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/OMSUI/Settings")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let pattern = /SettingsRow\(String\(localized: "((?:[^"\\]|\\.)*)", bundle: \.module\)/
        let drawn = try files.flatMap { file in try String(contentsOf: file, encoding: .utf8).matches(of: pattern).map { String($0.1) } }
        #expect(drawn.count > 40)
        let searched = Set(SettingsTab.allCases.flatMap { $0.searchRows.map(\.title) })
        for title in drawn {
            #expect(searched.contains(title), "\(title) can't be found")
        }
    }

    @Test func aSearchLandsOnTheRowThatHasWhatItFound() {
        #expect(SettingsTab.tools.row(matching: "shadow") == "Pins")
        #expect(SettingsTab.text.row(matching: "wrap") == "Recognized Text")
        #expect(SettingsTab.text.row(matching: "API key") == "Cloud reading")
        #expect(SettingsTab.capture.row(matching: "shadow") == "Windows")
        #expect(SettingsTab.screenshots.row(matching: "JPEG") == "Format")
        #expect(SettingsTab.screenshots.row(matching: "ask for a name") == "File name")
        #expect(SettingsTab.quickAccess.row(matching: "bottom left") == "Position")
        #expect(SettingsTab.general.row(matching: "nothing like this") == nil)
    }

    /// A pane whose title a search finds comes before one that only has the words in a row, so Return opens it.
    @Test func aPaneNamedByTheSearchComesFirst() {
        let found = SettingsTab.found("text").map(\.tab)
        #expect(found.first == .text)
        #expect(found.contains(.capture))
        // Tools has how pins look; Shortcuts has Hide or Show Pins.
        #expect(SettingsTab.found("pins").map(\.tab) == [.tools, .shortcuts])
        #expect(SettingsTab.found("nothing like this").isEmpty)
    }

    /// What people type, which the panes don't show, finds the row they mean: the first pane found, and the row it
    /// opens on.
    @Test(arguments: [
        ("OCR", SettingsTab.text, "Capture Text"),
        ("hotkey", .shortcuts, nil),
        ("retention", .general, "Keep captures"),
        ("retention ", .general, "Keep captures"),
        ("delay", .capture, "Self-Timer"),
        ("JPG", .screenshots, "Format"),
        ("HEIC", .screenshots, "Format"),
        ("clipboard", .screenshots, "Clipboard"),
        ("auto save", .screenshots, "After screenshot"),
        ("webcam", .permissions, "Camera"),
        ("S3", .sharing, "Destinations"),
        ("GIF", .recording, "GIF"),
        ("fps", .recording, "Frame rate"),
        ("login item", .general, "Startup"),
        ("eyedropper", .tools, "Copy colors as"),
        ("LaTeX", .text, "Model packs"),
        ("QR code", .capture, "Selecting"),
        ("watermark", .screenshots, "Pictures"),
        ("record keys", .recording, "Studio"),
        ("barcode", .capture, "Selecting"),
        ("no background", .capture, "Windows"),
    ] as [(String, SettingsTab, String?)])
    func whatPeopleTypeReachesTheRowTheyMean(query: String, tab: SettingsTab, row: String?) {
        #expect(SettingsTab.found(query).first?.tab == tab, "\(query) opens \(String(describing: SettingsTab.found(query).first?.tab))")
        #expect(tab.row(matching: query) == row)
    }

    /// Settings have no auto zoom (Studio zooms in each project), so a search for it finds nothing, and Recording has
    /// no row for zoom.
    @Test func autoZoomFindsNothing() {
        #expect(SettingsTab.found("auto zoom").isEmpty)
        #expect(SettingsTab.recording.row(matching: "zoom") == nil)
    }

    /// A row the pane doesn't draw now, as Recent uploads before any upload has finished, is neither found nor
    /// landed on.
    @Test func aRowThePaneHidesIsNotFound() {
        #expect(SettingsTab.found("upload history").first?.tab == .sharing)
        #expect(SettingsTab.sharing.row(matching: "upload history") == "Recent uploads")
        let hidden: Set = ["Recent uploads"]
        #expect(SettingsTab.sharing.matches("upload history", hiding: hidden) == nil)
        #expect(SettingsTab.sharing.matches("Forget All", hiding: hidden) == nil)
        #expect(SettingsTab.sharing.row(matching: "upload history", hiding: hidden) == nil)
        #expect(SettingsTab.sharing.matches("S3", hiding: hidden) == ["S3"])
    }

    /// The two controls that were missing are found by their own names.
    @Test func theQRCodeAndWatermarkControlsAreFound() {
        #expect(SettingsTab.capture.matches("Find QR codes") == ["Find QR codes and barcodes"])
        #expect(SettingsTab.screenshots.matches("Add a watermark") == ["Add a watermark"])
    }

    /// What a pane shows comes before what it is only known by: a row that shows the word typed is where the search
    /// lands, and a pane with one comes before a pane found only by a hidden word.
    @Test func whatAPaneShowsComesFirst() {
        #expect(SettingsTab.screenshots.matches("clipboard")?.first == "Clipboard")
        // Capture and Shortcuts show Self-Timer; Recording only knows its Countdown by "timer".
        let timer = SettingsTab.found("timer").map(\.tab)
        #expect(timer.first == .capture)
        #expect(timer.last == .recording, "\(timer)")
        let accessibility = SettingsTab.found("Accessibility").map(\.tab)
        #expect(accessibility.contains(.text) && accessibility.contains(.permissions))
    }

    /// A word the pane doesn't show is never listed under it: the row it found is, by its title.
    @Test func aRowFoundByAHiddenWordIsListedByItsTitle() {
        #expect(SettingsTab.text.matches("OCR")?.contains("OCR") == false)
        #expect(SettingsTab.text.matches("OCR")?.first == "Capture Text")
        #expect(SettingsTab.permissions.matches("webcam") == ["Camera"])
        // A row that shows what was typed is listed by that, not twice.
        #expect(SettingsTab.screenshots.matches("HEIC") == ["HEIC"])
        // Found by a word the whole pane is known by, a pane lists no rows, as one found by its title.
        #expect(SettingsTab.shortcuts.matches("hotkey") == [])
    }

    /// A catalog's list of words is read apart at commas, or at the 、 and ， of Chinese and Japanese.
    @Test func aListOfWordsIsReadApartAtItsCommas() {
        #expect(SettingsSearchRow.words(in: "OCR, text recognition,  scan ") == ["OCR", "text recognition", "scan"])
        #expect(SettingsSearchRow.words(in: "文字识别、OCR，提取文字") == ["文字识别", "OCR", "提取文字"])
        #expect(SettingsSearchRow.words(in: "") == [])
    }

    @Test func eachPanesRowsHaveTitlesOfTheirOwn() {
        for tab in SettingsTab.allCases {
            let titles = tab.searchRows.map(\.title)
            #expect(Set(titles).count == titles.count, "\(tab) has two rows of one title")
        }
    }
}
