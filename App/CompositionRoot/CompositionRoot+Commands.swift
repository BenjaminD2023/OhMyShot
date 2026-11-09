import AppKit
import Foundation
import ImageIO
import Observation
import OMSAnnotate
import OMSCapture
import OMSCore
import OMSOCR
import OMSRecording
import OMSUI
import OSLog
import UniformTypeIdentifiers

/// What the global shortcuts and the URL API's commands run.
extension CompositionRoot {
    func handle(_ shortcut: CaptureShortcut) {
        statusItem?.dismissLauncher()
        Log.signposter.emitEvent("hotkey")
        Log.hotkeys.notice("hotkey.\(shortcut.rawValue, privacy: .public)")
        if shortcut == .captureArea, beginOnboardingCaptureIfReady() { return }
        switch shortcut {
        case .openHistory:
            showHistory()
            return
        case .copyLatestCapture:
            quickAccess.copyLatest()
            return
        case .annotateLatestCapture:
            annotateLatestCapture()
            return
        case .openFromClipboard:
            annotateClipboard()
            return
        case .controlQuickAccess:
            quickAccess.focusLatest()
            return
        default:
            break
        }
        quickAccess.dismissFirstCaptureHint()
        permissions.refresh([.screenRecording])
        guard permissions.status(of: .screenRecording) == .granted else {
            showOnboarding()
            return
        }
        switch shortcut {
        case .captureArea:
            captures.captureArea()
        case .allInOne:
            captures.allInOne()
        case .annotateArea:
            captures.annotateArea()
        case .pinArea:
            captures.pinArea()
        case .captureAreaAndCopy:
            captures.captureArea(followUp: CaptureFollowUp(action: .copy))
        case .captureAreaAndSave:
            captures.captureArea(followUp: CaptureFollowUp(action: .save))
        case .captureAreaAndAnnotate:
            captures.captureArea(followUp: CaptureFollowUp(action: .annotate))
        case .captureFullscreen:
            captures.captureFullscreen()
        case .captureAreaAndUpload:
            guard let followUp = followUp(for: .upload, asksForName: true) else { return }
            captures.captureArea(followUp: followUp)
        case .captureFullscreenAndUpload:
            guard let followUp = followUp(for: .upload, asksForName: true) else { return }
            captures.captureFullscreen(followUp: followUp)
        case .captureWindow:
            captures.captureWindow()
        case .selfTimer:
            captures.selfTimer()
        case .capturePreviousArea:
            captures.capturePreviousArea()
        case .captureText:
            captures.cancelSelfTimer()
            textCapture.captureText(joinLines: !settings.textRecognitionKeepsLineBreaks)
        case .captureTextJoined:
            captures.cancelSelfTimer()
            textCapture.captureText(joinLines: true)
        case .captureFormula:
            captures.cancelSelfTimer()
            textCapture.captureFormula()
        case .translateArea:
            captures.cancelSelfTimer()
            textCapture.translateArea()
        case .pickColor:
            captures.cancelSelfTimer()
            colorPicker.pickColor()
        case .measure:
            captures.cancelSelfTimer()
            measurer.measure()
        case .recordScreen:
            captures.cancelSelfTimer()
            recordings.recordScreen()
        case .saveReplay:
            if #available(macOS 27, *) { replay?.save() }
        case .scrollingCapture:
            scrolling.begin()
        default:
            Log.hotkeys.notice("Not available yet: \(shortcut.rawValue, privacy: .public)")
        }
    }

    /// Runs a URL API command from an approved caller, as CleanShot X runs it under the same name and parameters, and a
    /// shortcut's. `done` is told the record of a capture command's capture once it is kept, or nil when none is: it was
    /// cancelled or failed, or never began (no Screen Recording, an area on no display, an upload with nowhere to go). Any
    /// other command keeps no capture, and tells it nil at once.
    func perform(_ command: AutomationCommand, done: ((HistoryItem?) -> Void)? = nil) {
        // Told once: by the capture's follow-up when one takes it on, else as this returns.
        var followUpTakesDone = false
        defer { if !followUpTakesDone { done?(nil) } }
        func followUp(doing action: CaptureAction?) -> CaptureFollowUp? {
            guard let followUp = self.followUp(for: action, done: done) else { return nil }
            followUpTakesDone = true
            return followUp
        }
        if command.readsScreen {
            quickAccess.dismissFirstCaptureHint()
            permissions.refresh([.screenRecording])
            if permissions.status(of: .screenRecording) != .granted { return showOnboarding() }
        }
        switch command {
        case .allInOne(let region):
            guard let area = area(of: region) else { return }
            captures.allInOne(choosing: area)
        case .captureArea(let region, let action):
            guard let area = area(of: region), let followUp = followUp(doing: action) else { return }
            if let area { captures.captureArea(at: area, followUp: followUp) } else { captures.captureArea(followUp: followUp) }
        case .capturePreviousArea(let action):
            guard let followUp = followUp(doing: action) else { return }
            captures.capturePreviousArea(followUp: followUp)
        case .captureFullscreen(let action):
            guard let followUp = followUp(doing: action) else { return }
            captures.cancelSelfTimer()
            captures.captureFullscreen(followUp: followUp)
        case .captureWindow(let action):
            guard let followUp = followUp(doing: action) else { return }
            captures.captureWindow(followUp: followUp)
        case .selfTimer(let action):
            guard let followUp = followUp(doing: action) else { return }
            captures.selfTimer(followUp: followUp)
        case .scrollingCapture(let region, let start, let autoScrolls):
            guard let area = area(of: region) else { return }
            scrolling.begin(autoScrolls: autoScrolls, area: area, starts: start)
        case .pin(let file):
            if let file { pin(fileAt: file) } else { choosePicturesToPin() }
        case .recordScreen(let region):
            guard let area = area(of: region) else { return }
            captures.cancelSelfTimer()
            recordings.recordScreen(area: area)
        case .captureText(let file?, _, let lineBreaks):
            let joinLines = !(lineBreaks ?? settings.textRecognitionKeepsLineBreaks)
            Task { await textCapture.recognize(fileAt: file, joinLines: joinLines) }
        case .captureText(nil, let region, let lineBreaks):
            guard let area = area(of: region) else { return }
            captures.cancelSelfTimer()
            let joinLines = !(lineBreaks ?? settings.textRecognitionKeepsLineBreaks)
            if let area {
                Task { await textCapture.recognize(region: area, joinLines: joinLines) }
            } else {
                textCapture.captureText(joinLines: joinLines, allowsCloud: false)
            }
        case .captureFormula(let file?, _):
            Task { await textCapture.readFormula(fileAt: file) }
        case .captureFormula(nil, let region):
            guard let area = area(of: region) else { return }
            captures.cancelSelfTimer()
            if let area {
                Task { await textCapture.readFormula(region: area) }
            } else {
                textCapture.captureFormula()
            }
        case .openAnnotate(let file):
            if let file { open([file]) } else { chooseFilesToAnnotate() }
        case .openFromClipboard:
            annotateClipboard()
        case .toggleDesktopIcons:
            setDesktopIconsHidden(!settings.hidesDesktopIcons)
        case .hideDesktopIcons:
            setDesktopIconsHidden(true)
        case .showDesktopIcons:
            setDesktopIconsHidden(false)
        case .addQuickAccessOverlay(let file):
            Task { await addToQuickAccess(file) }
        case .openHistory:
            showHistory()
        case .restoreRecentlyClosed:
            quickAccess.restoreRecentlyClosed()
        case .openSettings(let tab):
            showSettings(tab)
        }
    }

    /// A URL command's area in global points: `.some(nil)` when the user is to choose it, nil (with a beep) when it
    /// lies on no display.
    private func area(of region: AutomationRegion) -> CGRect?? {
        do {
            return .some(try region.area(in: displays.layout, pointer: NSEvent.mouseLocation))
        } catch {
            Log.automation.error("URL command's area refused: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return nil
        }
    }

    /// The URL API's `action` (or an upload shortcut's) as a capture's follow-up, telling `done` the capture's record; nil
    /// when it cannot be done: an upload with no destination, which is said by the pointer. A URL command never asks for
    /// a file name, being nobody's to answer; an upload shortcut, pressed at the keyboard, does.
    private func followUp(for action: CaptureAction?, asksForName: Bool = false, done: ((HistoryItem?) -> Void)? = nil) -> CaptureFollowUp? {
        if action == .upload, !uploads.canUpload {
            uploads.tellNoDestination()
            return nil
        }
        return CaptureFollowUp(action: action, asksForName: asksForName, done: done)
    }

    func setDesktopIconsHidden(_ hidden: Bool) {
        settings.hidesDesktopIcons = hidden
        desktopIcons.setShown(hidden)
    }

    /// Open from Clipboard, a shortcut and the URL API's `open-from-clipboard`: the clipboard's picture in the editor,
    /// added to the history first. Beeps when the clipboard holds none.
    private func annotateClipboard() {
        switch PasteboardImage.read(.general) {
        case .file(let url):
            open([url])
        case .data(let data):
            // As a file opened with Open With is: at the resolution it says, else one pixel per point. It is named as a
            // capture is, from the file name pattern.
            guard let loaded = ImageLoader.load(data: data) else { return NSSound.beep() }
            Task { await annotate(loaded, name: nil) }
        case nil:
            Log.automation.notice("Open from Clipboard: no picture on the clipboard")
            NSSound.beep()
        }
    }

    /// Annotate Latest Capture: the newest screenshot in the history, in the editor, whether its card is still up or not.
    /// Beeps when there is none.
    private func annotateLatestCapture() {
        guard let entry = history.latestScreenshot() else {
            Log.hotkeys.notice("Annotate Latest Capture: no screenshot in the history")
            return NSSound.beep()
        }
        annotate(entry, displayID: quickAccess.item(entry.id)?.displayID)
    }

    /// The URL API's `add-quick-access-overlay`: a copy of a picture or a recording joins the history and gets a card,
    /// whatever Settings says about cards: it is what was asked for. The file itself stays where it is.
    private func addToQuickAccess(_ url: URL) async {
        do {
            let entry = try await history.add(copyOf: url)
            historyWindow?.reload()
            if entry.kind == .screenshot { readTextSoon() }
            guard let item = await quickAccessItem(for: entry) else {
                history.delete(entry)
                throw CocoaError(.fileReadCorruptFile)
            }
            quickAccess.add(item)
        } catch {
            Log.automation.error("Could not add \(url.lastPathComponent, privacy: .public) to Quick Access: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }
}
