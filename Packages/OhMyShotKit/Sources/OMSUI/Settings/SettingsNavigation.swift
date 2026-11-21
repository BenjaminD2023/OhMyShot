import AppKit
import OMSCore
import SwiftUI

extension SettingsTab {
    /// The tile behind the pane's symbol in the sidebar, in a system color as System Settings has them.
    var tint: Color {
        switch self {
        case .general: .gray
        case .capture: .blue
        case .screenshots: .purple
        case .quickAccess: .orange
        case .recording: .red
        case .text: .green
        case .tools: .indigo
        case .sharing: .cyan
        case .shortcuts: .gray
        case .automation: .green
        case .permissions: .blue
        case .about: .teal
        }
    }

    /// The rows of the pane as a search finds them: each row's title, where a search for it lands, the names of its
    /// controls and choices, and the words people type for it that the pane doesn't show. `SettingsSearchTests` checks
    /// that every row a pane draws is here.
    var searchRows: [SettingsSearchRow] {
        switch self {
        case .general:
            [
                SettingsSearchRow(String(localized: "Language", bundle: .module), terms: [
                    String(localized: "System default", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_LANGUAGE", defaultValue: "locale, interface language, display language", bundle: .module)),
                SettingsSearchRow(String(localized: "Startup", bundle: .module), terms: [
                    String(localized: "Launch at login", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_STARTUP", defaultValue: "login item, open at login, start automatically, autostart", bundle: .module)),
                SettingsSearchRow(String(localized: "Updates", bundle: .module), terms: [
                    String(localized: "Check for updates automatically", bundle: .module),
                    String(localized: "Check Now", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_UPDATES", defaultValue: "upgrade, new version, latest version, release notes", bundle: .module)),
                SettingsSearchRow(String(localized: "Menu bar", bundle: .module), terms: [
                    String(localized: "Show icon", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_MENU_BAR", defaultValue: "status bar, menubar, tray, hide icon", bundle: .module)),
                SettingsSearchRow(String(localized: "Sound", bundle: .module), terms: [
                    String(localized: "Play sounds", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_SOUND", defaultValue: "shutter sound, mute, silent", bundle: .module)),
                SettingsSearchRow(String(localized: "Keep captures", bundle: .module), terms: [
                    String(localized: "Open Capture History", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_KEEP_CAPTURES", defaultValue: "retention, history, delete old captures, expire, disk space", bundle: .module)),
                SettingsSearchRow(String(localized: "Usage Data", bundle: .module), terms: [
                    String(localized: "Send optional usage data", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_USAGE_DATA", defaultValue: "telemetry, analytics, statistics, privacy", bundle: .module)),
                SettingsSearchRow(String(localized: "Reset", bundle: .module), terms: [
                    String(localized: "Reset to Default Settings…", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_RESET", defaultValue: "defaults, factory settings, restore", bundle: .module)),
                SettingsSearchRow(String(localized: "Getting Started", bundle: .module), terms: [
                    String(localized: "Show the Getting Started Guide…", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_GETTING_STARTED", defaultValue: "onboarding, tutorial, guide, welcome, help", bundle: .module)),
            ]
        case .capture:
            [
                SettingsSearchRow(String(localized: "Selecting", bundle: .module), terms: [
                    String(localized: "Freeze the screen", bundle: .module),
                    String(localized: "Show the pointer in screenshots", bundle: .module),
                    String(localized: "Shift keeps", bundle: .module),
                    String(localized: "A square", bundle: .module),
                    String(localized: "Snap the selection to text", bundle: .module),
                    String(localized: "Find QR codes and barcodes", bundle: .module),
                    String(localized: "All-In-One remembers the last area", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_SELECTING", defaultValue: "cursor, mouse, aspect ratio, ratio, scan code", bundle: .module)),
                SettingsSearchRow(String(localized: "Magnifier", bundle: .module), terms: [
                    String(localized: "Size", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_MAGNIFIER", defaultValue: "loupe, zoom, lens, pixel", bundle: .module)),
                SettingsSearchRow(String(localized: "Self-Timer", bundle: .module), keywords: String(localized: "SEARCH_KEYWORDS_SELF_TIMER", defaultValue: "timer, delay, delayed capture, countdown, wait", bundle: .module)),
                SettingsSearchRow(String(localized: "Windows", bundle: .module), terms: [
                    String(localized: "Capture the shadow", bundle: .module),
                    String(localized: "Window background", bundle: .module),
                    String(localized: "Same background as screenshots", bundle: .module),
                    String(localized: "No background", bundle: .module),
                    String(localized: "Desktop wallpaper", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_WINDOWS", defaultValue: "window screenshot, drop shadow, padding", bundle: .module)),
            ]
        case .screenshots:
            [
                SettingsSearchRow(String(localized: "After screenshot", bundle: .module), terms: [
                    String(localized: "Copy", bundle: .module),
                    String(localized: "Quick Access", bundle: .module),
                    String(localized: "Save", bundle: .module),
                    String(localized: "Upload", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_AFTER_SCREENSHOT", defaultValue: "clipboard, auto save, automatically", bundle: .module)),
                SettingsSearchRow(String(localized: "Save to", bundle: .module), keywords: String(localized: "SEARCH_KEYWORDS_SAVE_TO", defaultValue: "folder, location, directory, path, desktop, export", bundle: .module)),
                SettingsSearchRow(String(localized: "Background", bundle: .module), terms: [
                    String(localized: "Rounded corners and shadow", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_BACKGROUND", defaultValue: "padding, backdrop, gradient, beautify, frame", bundle: .module)),
                SettingsSearchRow(String(localized: "Format", bundle: .module), terms: [
                    String(localized: "Quality", bundle: .module),
                    "PNG",
                    "JPEG",
                    "HEIC",
                ], keywords: String(localized: "SEARCH_KEYWORDS_FORMAT", defaultValue: "JPG, file type, image format, compression", bundle: .module)),
                SettingsSearchRow(String(localized: "Pictures", bundle: .module), terms: [
                    String(localized: "Save Retina screenshots at 1×", bundle: .module),
                    String(localized: "Convert to sRGB", bundle: .module),
                    String(localized: "Add a 1 px border", bundle: .module),
                    String(localized: "Add a watermark", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_PICTURES", defaultValue: "resolution, 2x, HiDPI, color profile, color space, outline", bundle: .module)),
                SettingsSearchRow(String(localized: "File name", bundle: .module), terms: [
                    String(localized: "Ask for a name when saving", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_FILE_NAME", defaultValue: "filename, naming, pattern, template, date, counter", bundle: .module)),
                SettingsSearchRow(String(localized: "Clipboard", bundle: .module), terms: [
                    String(localized: "Picture only", bundle: .module),
                    String(localized: "File and picture", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_CLIPBOARD", defaultValue: "paste, pasteboard, copy as file", bundle: .module)),
            ]
        case .quickAccess:
            [
                SettingsSearchRow(String(localized: "Position", bundle: .module), terms: [
                    String(localized: "Bottom left", bundle: .module),
                    String(localized: "Bottom right", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_QUICK_ACCESS_POSITION", defaultValue: "corner, placement, overlay, thumbnail", bundle: .module)),
                SettingsSearchRow(String(localized: "Size", bundle: .module), terms: [
                    String(localized: "Small", bundle: .module),
                    String(localized: "Medium", bundle: .module),
                    String(localized: "Large", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_QUICK_ACCESS_SIZE", defaultValue: "card size, bigger, smaller", bundle: .module)),
                SettingsSearchRow(String(localized: "Display", bundle: .module), terms: [
                    String(localized: "Show on the display with the pointer", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_QUICK_ACCESS_DISPLAY", defaultValue: "monitor, screen, multiple displays, external display", bundle: .module)),
                SettingsSearchRow(String(localized: "Close cards", bundle: .module), terms: [
                    String(localized: "Save and close", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_CLOSE_CARDS", defaultValue: "auto close, dismiss, timeout, hide automatically", bundle: .module)),
            ]
        case .recording:
            [
                SettingsSearchRow(String(localized: "Countdown", bundle: .module), keywords: String(localized: "SEARCH_KEYWORDS_COUNTDOWN", defaultValue: "delay, timer, wait", bundle: .module)),
                SettingsSearchRow(String(localized: "While recording", bundle: .module), terms: [
                    String(localized: "Show controls", bundle: .module),
                    String(localized: "Show the pointer", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_WHILE_RECORDING", defaultValue: "cursor, mouse, toolbar, stop button", bundle: .module)),
                SettingsSearchRow(String(localized: "Recorded area", bundle: .module), terms: [
                    String(localized: "Outline", bundle: .module),
                    String(localized: "Dim the rest of the screen", bundle: .module),
                    String(localized: "Red frame", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_RECORDED_AREA", defaultValue: "highlight, border, dim, mask", bundle: .module)),
                SettingsSearchRow(String(localized: "Audio", bundle: .module), keywords: String(localized: "SEARCH_KEYWORDS_AUDIO", defaultValue: "microphone, mic, system audio, sound, voice", bundle: .module)),
                SettingsSearchRow(String(localized: "Clicks", bundle: .module), terms: [
                    String(localized: "Accent rings", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_CLICKS", defaultValue: "mouse clicks, click highlight, cursor", bundle: .module)),
                SettingsSearchRow(String(localized: "Keystrokes", bundle: .module), terms: [
                    String(localized: "All keys", bundle: .module),
                    String(localized: "Shortcuts only", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_KEYSTROKES", defaultValue: "keyboard, typing, key presses, show keys", bundle: .module)),
                SettingsSearchRow(String(localized: "Studio", bundle: .module), terms: [
                    String(localized: "Keep the keys pressed", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_STUDIO", defaultValue: "keystrokes, key presses, record keys", bundle: .module)),
                SettingsSearchRow(String(localized: "Frame rate", bundle: .module), keywords: String(localized: "SEARCH_KEYWORDS_FRAME_RATE", defaultValue: "fps, frames per second, smooth", bundle: .module)),
                SettingsSearchRow(String(localized: "Video format", bundle: .module), terms: [
                    String(localized: "HEVC", bundle: .module),
                    "H.264",
                ], keywords: String(localized: "SEARCH_KEYWORDS_VIDEO_FORMAT", defaultValue: "codec, MP4, H.265, compression, video quality", bundle: .module)),
                SettingsSearchRow(String(localized: "GIF", bundle: .module), terms: [
                    String(localized: "GIF frame rate", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_GIF", defaultValue: "animated, animation", bundle: .module)),
                SettingsSearchRow(String(localized: "After recording", bundle: .module), keywords: String(localized: "SEARCH_KEYWORDS_AFTER_RECORDING", defaultValue: "clipboard, auto save, video, movie", bundle: .module)),
            ]
        case .text:
            [
                SettingsSearchRow(String(localized: "Capture Text", bundle: .module), terms: [
                    String(localized: "Show the copied text", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_CAPTURE_TEXT", defaultValue: "OCR, text recognition, extract text, copy text", bundle: .module)),
                SettingsSearchRow(String(localized: "Text card position", bundle: .module), terms: [
                    String(localized: "Below selection", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_TEXT_CARD_POSITION", defaultValue: "result card, popup, OCR result", bundle: .module)),
                SettingsSearchRow(String(localized: "Close text card", bundle: .module), keywords: String(localized: "SEARCH_KEYWORDS_CLOSE_TEXT_CARD", defaultValue: "dismiss, timeout, hide, result card", bundle: .module)),
                SettingsSearchRow(String(localized: "Image line breaks", bundle: .module), terms: [
                    String(localized: "Keep line breaks", bundle: .module),
                    String(localized: "Join lines", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_LINE_BREAKS", defaultValue: "newline, paragraph, merge lines, OCR", bundle: .module)),
                SettingsSearchRow(String(localized: "Recognized Text", bundle: .module), terms: [
                    String(localized: "Wrap text to window", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_RECOGNIZED_TEXT", defaultValue: "OCR panel, OCR window, word wrap", bundle: .module)),
                SettingsSearchRow(String(localized: "Text from apps", bundle: .module), terms: [
                    String(localized: "Accessibility", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_TEXT_FROM_APPS", defaultValue: "exact text, characters, app text", bundle: .module)),
                SettingsSearchRow(String(localized: "Translate into", bundle: .module), keywords: String(localized: "SEARCH_KEYWORDS_TRANSLATE_INTO", defaultValue: "translation, translate, target language", bundle: .module)),
                SettingsSearchRow(String(localized: "Model packs", bundle: .module), keywords: String(localized: "SEARCH_KEYWORDS_MODEL_PACKS", defaultValue: "download, model, formula, LaTeX, math, table, VLM, PaddleOCR", bundle: .module)),
                SettingsSearchRow(String(localized: "Cloud reading", bundle: .module), terms: [
                    String(localized: "API key", bundle: .module),
                    String(localized: "Base URL", bundle: .module),
                    String(localized: "Model", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_CLOUD_READING", defaultValue: "AI, LLM, OpenAI, cloud OCR, GPT, Gemini, Claude", bundle: .module)),
            ]
        case .tools:
            [
                SettingsSearchRow(String(localized: "Copy colors as", bundle: .module), keywords: String(localized: "SEARCH_KEYWORDS_COPY_COLORS", defaultValue: "color picker, eyedropper, hex, RGB, HSL, OKLCH, P3", bundle: .module)),
                SettingsSearchRow(String(localized: "Measure in", bundle: .module), terms: [
                    String(localized: "Points", bundle: .module),
                    String(localized: "Pixels", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_MEASURE_IN", defaultValue: "ruler, measure, units", bundle: .module)),
                SettingsSearchRow(String(localized: "Measurement snapping", bundle: .module), terms: [
                    String(localized: "Snap selections to content", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_MEASUREMENT_SNAPPING", defaultValue: "ruler, snap, edges, magnetic", bundle: .module)),
                SettingsSearchRow(String(localized: "Edge tolerance", bundle: .module), keywords: String(localized: "SEARCH_KEYWORDS_EDGE_TOLERANCE", defaultValue: "ruler, snap sensitivity, threshold", bundle: .module)),
                SettingsSearchRow(String(localized: "Pins", bundle: .module), terms: [
                    String(localized: "Corners", bundle: .module),
                    String(localized: "Shadow", bundle: .module),
                    String(localized: "Border", bundle: .module),
                    String(localized: "Show in screenshots", bundle: .module),
                    String(localized: "Bring pins back after relaunch", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_PINS", defaultValue: "float, always on top, sticky, pinned image", bundle: .module)),
            ]
        case .sharing:
            [
                SettingsSearchRow(String(localized: "Destinations", bundle: .module), terms: [
                    String(localized: "Add Destination", bundle: .module),
                    String(localized: "Import ShareX Uploader…", bundle: .module),
                    "S3",
                    "WebDAV",
                ], keywords: String(localized: "SEARCH_KEYWORDS_DESTINATIONS", defaultValue: "upload, cloud, R2, Cloudflare, server, storage, image host", bundle: .module)),
                SettingsSearchRow(String(localized: "After upload", bundle: .module), terms: [
                    String(localized: "Copy link after upload", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_AFTER_UPLOAD", defaultValue: "link, URL, share link, clipboard", bundle: .module)),
                SettingsSearchRow(String(localized: "Recent uploads", bundle: .module), terms: [
                    String(localized: "Forget All", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_RECENT_UPLOADS", defaultValue: "upload history, links, uploaded files", bundle: .module)),
            ]
        case .shortcuts:
            CaptureShortcut.allCases.filter(\.isAvailable).map { SettingsSearchRow($0.title) }
        case .automation:
            [
                SettingsSearchRow(String(localized: "URL scheme", bundle: .module), terms: [
                    String(localized: "Allow other apps to control OhMyShot", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_URL_SCHEME", defaultValue: "API, deep link, scripting, automation, CleanShot, Raycast, Alfred", bundle: .module)),
                SettingsSearchRow(String(localized: "Approved apps", bundle: .module), terms: [
                    String(localized: "Command-line tools", bundle: .module),
                ], keywords: String(localized: "SEARCH_KEYWORDS_APPROVED_APPS", defaultValue: "Terminal, CLI, command line, scripts", bundle: .module)),
            ]
        case .permissions:
            Permission.allCases.map { SettingsSearchRow($0.title, keywords: $0.searchKeywords) }
        case .about:
            [SettingsSearchRow(String(localized: "Acknowledgments", bundle: .module), keywords: String(localized: "SEARCH_KEYWORDS_ACKNOWLEDGMENTS", defaultValue: "licenses, open source, credits, GPL, version", bundle: .module))]
        }
    }

    /// Words a search finds the whole pane by, as it finds its title, and never shows: for a pane whose rows are its
    /// commands, where no one row is meant.
    var searchKeywords: [String] {
        switch self {
        case .shortcuts:
            SettingsSearchRow.words(in: String(
                localized: "SEARCH_KEYWORDS_SHORTCUTS", defaultValue: "hotkeys, keyboard shortcuts, key bindings, global shortcuts", bundle: .module
            ))
        default: []
        }
    }

    /// Whether a search finds the pane by its title, or by a word it is known by.
    private func isNamed(by query: String) -> Bool {
        title.localizedStandardContains(query) || searchKeywords.contains { $0.localizedStandardContains(query) }
    }

    /// The rows the pane draws now: all but those `hidden`, as Sharing hides Recent uploads until an upload finishes.
    private func drawnRows(hiding hidden: Set<String>) -> [SettingsSearchRow] {
        searchRows.filter { !hidden.contains($0.title) }
    }

    /// The rows whose title or controls show what a search typed.
    private func rowsShowing(_ query: String, hiding hidden: Set<String>) -> [SettingsSearchRow] {
        drawnRows(hiding: hidden).filter { row in ([row.title] + row.terms).contains { $0.localizedStandardContains(query) } }
    }

    /// The rows a search finds only by a word they are known by, which they don't show.
    private func rowsKnownBy(_ query: String, hiding hidden: Set<String>) -> [SettingsSearchRow] {
        let showing = Set(rowsShowing(query, hiding: hidden).map(\.title))
        return drawnRows(hiding: hidden).filter { row in
            !showing.contains(row.title) && row.keywords.contains { $0.localizedStandardContains(query) }
        }
    }

    /// The rows a search finds in the pane, as the sidebar lists them under its name, or nil when it finds neither
    /// them nor the pane: first what it found that the pane shows (a row's title, a control's name), then the titles
    /// of the rows it found only by a word they are known by, as that word is never shown. Rows the pane doesn't draw
    /// now (`hidden`, by title) aren't found.
    func matches(_ query: String, hiding hidden: Set<String> = []) -> [String]? {
        var seen = Set<String>()
        let shown = drawnRows(hiding: hidden).flatMap { [$0.title] + $0.terms }.filter { $0.localizedStandardContains(query) }
        let found = (shown + rowsKnownBy(query, hiding: hidden).map(\.title)).filter { seen.insert($0).inserted }
        return found.isEmpty && !isNamed(by: query) ? nil : found
    }

    /// The panes a search finds, with the rows it found in each: first those it found by their title or a word the
    /// pane is known by ("text" lists Text before Capture's "Snap the selection to text"), then those with a row that
    /// shows what was typed, then those found only by a word a row is known by; each in the sidebar's order. Return
    /// opens the first. Spaces around what was typed don't count, as the sidebar leaves them out.
    static func found(_ typed: String, hiding hidden: Set<String> = []) -> [(tab: SettingsTab, rows: [String])] {
        let query = typed.trimmingCharacters(in: .whitespaces)
        let found = allCases.compactMap { tab in tab.matches(query, hiding: hidden).map { (tab: tab, rows: $0) } }
        func tier(_ tab: SettingsTab) -> Int {
            tab.isNamed(by: query) ? 0 : tab.rowsShowing(query, hiding: hidden).isEmpty ? 2 : 1
        }
        return (0...2).flatMap { level in found.filter { tier($0.tab) == level } }
    }

    /// The title of the row opening the pane from a search lands on: the first that shows what was typed, else the
    /// first known by it. Spaces around what was typed don't count.
    func row(matching typed: String, hiding hidden: Set<String> = []) -> String? {
        let query = typed.trimmingCharacters(in: .whitespaces)
        return (rowsShowing(query, hiding: hidden).first ?? rowsKnownBy(query, hiding: hidden).first)?.title
    }
}

extension Permission {
    /// Words a search finds the permission's row by, never shown.
    var searchKeywords: String {
        switch self {
        case .screenRecording: String(localized: "SEARCH_KEYWORDS_SCREEN_RECORDING", defaultValue: "privacy, screen capture, permission", bundle: .module)
        case .microphone: String(localized: "SEARCH_KEYWORDS_MICROPHONE", defaultValue: "mic, audio, voice, privacy", bundle: .module)
        case .camera: String(localized: "SEARCH_KEYWORDS_CAMERA", defaultValue: "webcam, FaceTime camera, video, privacy", bundle: .module)
        case .accessibility: String(localized: "SEARCH_KEYWORDS_ACCESSIBILITY", defaultValue: "privacy, permission, control", bundle: .module)
        case .inputMonitoring: String(localized: "SEARCH_KEYWORDS_INPUT_MONITORING", defaultValue: "keyboard, keystrokes, privacy, permission", bundle: .module)
        }
    }
}

/// A row of a settings pane as a search finds it.
struct SettingsSearchRow {
    /// The row's title, as `SettingsRow` shows it: what a search lands on.
    let title: String
    /// The names of its controls and choices.
    var terms: [String] = []
    /// Words people type for the row that the pane doesn't show ("OCR", "hotkey", "JPG"), in each language as its
    /// catalog lists them: a search finds the row by them, and lists it by its title.
    var keywords: [String] = []

    /// - Parameter keywords: the catalog's list of the words, apart by commas.
    init(_ title: String, terms: [String] = [], keywords: String = "") {
        self.title = title
        self.terms = terms
        self.keywords = Self.words(in: keywords)
    }

    /// The words of a catalog's list, apart by commas, or by the 、 and ， Chinese and Japanese write.
    static func words(in list: String) -> [String] {
        list.split { ",，、".contains($0) }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Where a search sends the pane it opens: the row to scroll to and light up for a moment.
@Observable
final class SettingsSearchTarget {
    /// The title of the row to land on.
    private(set) var row: String?
    /// The row lit up now, which goes after a moment.
    var lit: String?
    /// Counts the requests, so the same row asked for twice lands twice.
    private(set) var request = 0

    func land(on row: String?) {
        self.row = row
        request += 1
    }
}

let sidebarWidth: CGFloat = 215

/// The smallest and largest the settings window's content gets. Wider than the maximum, a pane's rows sit in a band
/// of empty space; taller, there is nothing more to show.
let settingsMinSize = CGSize(width: sidebarWidth + paneWidth, height: 420)
let settingsMaxSize = CGSize(width: settingsMinSize.width + 280, height: 900)

/// The pane's symbol, white on a rounded tile of its color, as System Settings draws its panes.
struct SettingsIcon: View {
    let tab: SettingsTab
    var size: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Image(systemName: tab.symbolName)
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(size * 0.2)
            .frame(width: size, height: size)
            .background(tab.tint.gradient, in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            .accessibilityHidden(true)
    }
}

/// The pane on show, the panes visited before and after it, and the sidebar's search.
@Observable
final class SettingsNavigator {
    private(set) var tab: SettingsTab = .general {
        didSet { if tab != oldValue { onChange?(tab) } }
    }

    var query = ""
    /// Where a search sends the pane it opens.
    let target = SettingsSearchTarget()

    private var back: [SettingsTab] = []
    private var forward: [SettingsTab] = []

    @ObservationIgnored var onChange: ((SettingsTab) -> Void)?
    /// The titles of the rows the panes don't draw now, which the search leaves out.
    @ObservationIgnored var hiddenRows: @MainActor () -> Set<String> = { [] }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// Shows a pane, which Back then leaves for the one shown now.
    func go(to tab: SettingsTab) {
        guard tab != self.tab else { return }
        back.append(self.tab)
        forward.removeAll()
        self.tab = tab
    }

    /// Shows a pane with no history either side of it.
    func start(at tab: SettingsTab) {
        back.removeAll()
        forward.removeAll()
        self.tab = tab
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(tab)
        tab = previous
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(tab)
        tab = next
    }

    /// Opens a pane the search found, on the first row it found there.
    func open(_ tab: SettingsTab, searchedFor query: String) {
        go(to: tab)
        target.land(on: tab.row(matching: query, hiding: hiddenRows()))
    }
}

/// The window's content: the sidebar of panes with its search field, and the chosen pane beside it, titled in the
/// toolbar after the Back and Forward buttons, as in System Settings.
struct SettingsRootView: View {
    @Bindable var navigator: SettingsNavigator
    /// The pane for a tab, made the first time it is asked for and the same one after.
    let pane: (SettingsTab) -> NSViewController
    @FocusState private var isSearching: Bool

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(navigator: navigator)
                .toolbar(removing: .sidebarToggle)
                // The sidebar can't be dragged: not wider or narrower, and not shut, as it could not be opened again
                // with no sidebar button.
                .navigationSplitViewColumnWidth(min: sidebarWidth, ideal: sidebarWidth, max: sidebarWidth)
                .background(FixedSidebar())
        } detail: {
            SettingsPaneHost(controller: pane(navigator.tab))
                .id(navigator.tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(navigator.tab.title)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button {
                            navigator.goBack()
                        } label: {
                            Label { Text("Back", bundle: .module) } icon: { Image(systemName: "chevron.left") }
                        }
                        .disabled(!navigator.canGoBack)
                        .keyboardShortcut("[", modifiers: .command)
                        .help(Text("Show the previous pane", bundle: .module))
                        Button {
                            navigator.goForward()
                        } label: {
                            Label { Text("Forward", bundle: .module) } icon: { Image(systemName: "chevron.right") }
                        }
                        .disabled(!navigator.canGoForward)
                        .keyboardShortcut("]", modifiers: .command)
                        .help(Text("Show the next pane", bundle: .module))
                    }
                }
        }
        .searchable(text: $navigator.query, placement: .sidebar, prompt: Text("Search", bundle: .module))
        .searchFocused($isSearching)
        .onSubmit(of: .search) {
            if let first = SettingsTab.found(navigator.query, hiding: navigator.hiddenRows()).first {
                navigator.open(first.tab, searchedFor: navigator.query)
            }
        }
        .background {
            // Command-F goes to the search field, as in System Settings.
            Button { isSearching = true } label: { EmptyView() }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .frame(
            minWidth: settingsMinSize.width, maxWidth: settingsMaxSize.width,
            minHeight: settingsMinSize.height, maxHeight: settingsMaxSize.height
        )
    }
}

/// Keeps the sidebar from collapsing, which SwiftUI has no way to say: it finds the split view the sidebar sits in and
/// marks the sidebar's column as one that can't collapse, neither by dragging its edge nor by narrowing the window.
/// SwiftUI marks it collapsible again each time it updates the split view (on choosing a pane, say), so it is
/// watched and set back.
private struct FixedSidebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        private var observation: NSKeyValueObservation?
        private weak var sidebar: NSSplitViewItem?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            guard window != nil else { return }
            // The split view is laid out around the sidebar a moment after the sidebar joins the window.
            DispatchQueue.main.async { [weak self] in self?.pin() }
        }

        private func pin() {
            var view = superview
            while let current = view, !(current is NSSplitView) { view = current.superview }
            guard let controller = (view as? NSSplitView)?.delegate as? NSSplitViewController,
                  let sidebar = controller.splitViewItems.first else { return }
            self.sidebar = sidebar
            fix()
            observation = sidebar.observe(\.canCollapse) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.fix() }
            }
        }

        private func fix() {
            guard let sidebar else { return }
            if sidebar.canCollapse { sidebar.canCollapse = false }
            if sidebar.canCollapseFromWindowResize { sidebar.canCollapseFromWindowResize = false }
        }
    }
}

/// The panes down the window's left side: in groups, or while searching, those the search finds with the rows it
/// found in each.
private struct SettingsSidebar: View {
    @Bindable var navigator: SettingsNavigator

    var body: some View {
        let query = navigator.query.trimmingCharacters(in: .whitespaces)
        let selection = Binding<SettingsTab?>(get: { navigator.tab }, set: { tab in
            guard let tab else { return }
            // A pane chosen from what a search found opens on the row it found.
            if query.isEmpty { navigator.go(to: tab) } else { navigator.open(tab, searchedFor: query) }
        })
        if query.isEmpty {
            List(selection: selection) {
                ForEach(SettingsTab.groups.indices, id: \.self) { index in
                    Section {
                        ForEach(SettingsTab.groups[index], id: \.self) { tab in
                            SettingsSidebarRow(tab: tab).tag(tab)
                        }
                    }
                }
            }
        } else {
            let results = SettingsTab.found(query, hiding: navigator.hiddenRows())
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(selection: selection) {
                    ForEach(results, id: \.tab) { tab, rows in
                        SettingsSidebarRow(tab: tab, found: rows).tag(tab)
                    }
                }
            }
        }
    }
}

private struct SettingsSidebarRow: View {
    let tab: SettingsTab
    /// The rows a search found in the pane, listed under its title.
    var found: [String] = []

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title)
                if !found.isEmpty {
                    Text(found.formatted(.list(type: .and, width: .narrow)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        } icon: {
            SettingsIcon(tab: tab)
        }
        .padding(.vertical, 2)
    }
}

/// A pane made in AppKit, kept by the window between visits so it is made once.
private struct SettingsPaneHost: NSViewControllerRepresentable {
    let controller: NSViewController

    func makeNSViewController(context: Context) -> NSViewController {
        controller
    }

    func updateNSViewController(_ controller: NSViewController, context: Context) {}
}
