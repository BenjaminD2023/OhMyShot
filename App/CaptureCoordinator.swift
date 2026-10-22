import AppKit
import Foundation
import OMSAnnotate
import OMSCapture
import OMSCore
import OSLog
import UniformTypeIdentifiers

/// Turns a capture request into a history item: shows the overlay, captures the chosen region or window,
/// encodes it off the main actor, keeps it in the history, copies it, and hands it to Quick Access.
/// Nothing is written to the Desktop unless the user saves or turns on saving after capture.
final class CaptureCoordinator {
    private let settings: SettingsStore
    private let displays: DisplayTopology
    private let capturer: ScreenCapturer
    private let overlay: OverlayController
    private let history: HistoryStore
    /// Saves, copies, and hands over screenshots in the format Settings choose.
    let files: ScreenshotFiles
    /// Receives every finished capture, already in the history; the composition root decides whether
    /// it gets a Quick Access card.
    var onCaptured: ((QuickAccessItem) -> Void)?
    /// A capture was kept and is to be uploaded: Settings says so, or its follow-up's action does. The default
    /// destination gets it. Not called, after Settings, for a pin or a capture opened in the editor, which are kept
    /// without a card.
    var uploadKept: ((HistoryItem) -> Void)?
    /// Opens a capture in the annotation editor: its record and its pixels per point.
    var openInEditor: ((HistoryItem, CGFloat) -> Void)?
    /// A color taken with C over the magnifier while capturing: where it was, and the keys held then.
    var onColor: ((ScreenColor, CGPoint, NSEvent.ModifierFlags, Bool) -> Void)?
    /// Receives a capture to pin where it was taken, with its record in the history. Set by the
    /// composition root, which has the pins.
    var onPin: ((CapturedFrame, HistoryItem?) -> Void)?
    /// How Self-Timer is cancelled, told to VoiceOver when it starts: the keys of its shortcut, or nil
    /// when it has none and the menu bar is the way. Set by the composition root.
    var selfTimerKeys: (() -> String?)?
    /// Self-Timer's countdown, between choosing what to capture and capturing it.
    private let countdown = SelfTimerCountdown()
    /// What waits for the capture Self-Timer is counting down to, told nil when it is cancelled.
    private var timerFollowUp: CaptureFollowUp?
    #if DEBUG
    /// The in-place annotation on screen, for scripted checks.
    private(set) weak var inPlaceView: InPlaceAnnotationView?
    /// Stands in for Self-Timer's capture at zero, for scripted checks that must not read the screen.
    var selfTimerCapture: ((CGRect) -> CapturedFrame?)?
    #endif
    private lazy var shutter = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true
    )

    init(settings: SettingsStore, displays: DisplayTopology, capturer: ScreenCapturer, overlay: OverlayController, history: HistoryStore) {
        self.settings = settings
        self.displays = displays
        self.capturer = capturer
        self.overlay = overlay
        self.history = history
        files = ScreenshotFiles(settings: settings, history: history)
    }

    /// - Parameters:
    ///   - copiesToClipboard: false for scripted checks, which never touch the clipboard.
    ///   - freezes: whether the screen holds still while selecting; nil follows the setting. Scripted
    ///     checks on drawn screens pass true, so the real screen is never captured.
    /// - Parameters:
    ///   - area: chosen already, in global points (the URL API's `all-in-one` with an area): it shows chosen, and
    ///     Return takes it.
    ///   - followUp: the URL API's action, and whoever waits for the capture.
    func captureArea(copiesToClipboard: Bool = true, freezes: Bool? = nil, choosing area: CGRect? = nil, followUp: CaptureFollowUp = .none) {
        begin(mode: .area, copiesToClipboard: copiesToClipboard, freezes: freezes, area: area, followUp: followUp)
    }

    /// The URL API's `capture-area` with an area: captured at once, as it is on screen, without the overlay. It is
    /// what Capture Previous Area takes next.
    func captureArea(at rect: CGRect, followUp: CaptureFollowUp = .none) {
        guard !overlay.isActive else { return followUp.finish(nil) }
        cancelSelfTimer()
        previousArea = rect
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        let title = frontWindowTitle()
        Task { await captureArea(rect, appName: app, windowTitle: title, followUp: followUp) }
    }

    /// The title of the front window of the app in front, for file names that use it; read before the overlay takes
    /// the focus. Nil when no pattern asks for it.
    private func frontWindowTitle() -> String? {
        guard settings.fileNamePattern.contains(FilenameTemplate.Token.window.placeholder),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return WindowCatalog.frontWindowTitle(ofProcess: pid)
    }

    /// Read session appearance directly so a changed preference applies before observation is delivered.
    private func configureCaptureOverlay() {
        overlay.captureLoupeStyle = settings.captureLoupeStyle
        overlay.captureLoupeSize = settings.captureLoupeSize
    }

    // MARK: All-In-One

    /// All-In-One's area's text, with the area as it was frozen when the screen held still.
    var allInOneText: ((CGRect, CapturedFrame?) -> Void)?
    /// A scrolling capture of All-In-One's area, started at once.
    var allInOneScroll: ((CGRect) -> Void)?
    /// A recording All-In-One set up: what, where, with what, and the app in front.
    var onRecord: ((RecordingTarget, DisplayInfo, RecordingChoices, String?) -> Void)?
    /// A recording All-In-One set up was cancelled, leaving a camera preview to put away.
    var recordingSetupCancelled: (() -> Void)?
    /// Whether an upload destination is set up, for All-In-One's Upload.
    var canUpload: (() -> Bool)?

    /// All-In-One: choose an area, adjust it, then take it any way: capture it (and copy, save, annotate, pin, or
    /// upload it), read its text, capture it scrolling, or record it. A window or the whole screen is captured at
    /// once. The area last taken comes back framed while Settings keep it; `area` (global points, the URL API's)
    /// comes instead.
    /// - Parameters:
    ///   - copiesToClipboard: false for scripted checks, which never touch the clipboard.
    ///   - freezes: whether the screen holds still; nil follows the setting.
    func allInOne(choosing area: CGRect? = nil, copiesToClipboard: Bool = true, freezes: Bool? = nil) {
        guard !overlay.isActive else { return }
        cancelSelfTimer()
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        let title = frontWindowTitle()
        overlay.freezesScreen = freezes ?? settings.freezeScreen
        overlay.isAllInOne = true
        overlay.allInOneOffersUpload = canUpload?() ?? false
        overlay.allInOneShowsCopy = !settings.copyAfterCapture
        let start = area ?? (settings.allInOneRemembersArea ? settings.allInOneArea?.area(in: displays.layout) : nil)
        configureCaptureOverlay()
        overlay.begin(mode: .area, choosing: start) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .allInOne(let choice, let rect, let display, let frozen):
                remember(rect, on: display)
                switch choice {
                case .screenshot(let action):
                    previousArea = rect
                    let followUp = CaptureFollowUp(action: action)
                    if let frozen {
                        Task { await self.deliver(frozen, appName: app, windowTitle: title, copiesToClipboard: copiesToClipboard, followUp: followUp) }
                    } else {
                        Task { await self.captureArea(rect, appName: app, windowTitle: title, copiesToClipboard: copiesToClipboard, followUp: followUp) }
                    }
                case .text: allInOneText?(rect, frozen)
                case .scroll: allInOneScroll?(rect)
                case .record: break
                }
            case .window(let target, let modifiers):
                Task { await self.captureWindow(target, copiesToClipboard: copiesToClipboard, modifiers: modifiers) }
            case .record(let target, let display, let choices):
                if case .area(let rect) = target { remember(rect, on: display) }
                onRecord?(target, display, choices, app)
            case .color(let color, let point, _, let modifiers, let keyboard):
                onColor?(color, point, modifiers, keyboard)
            case .cancelled:
                if overlay.didSetUpRecording { recordingSetupCancelled?() }
            case .region, .annotated, .scroll:
                break
            }
        }
    }

    /// Keeps All-In-One's area for next time, while Settings say to; the whole display is no area to keep.
    private func remember(_ area: CGRect, on display: DisplayInfo) {
        guard settings.allInOneRemembersArea, area != display.frame else { return }
        settings.allInOneArea = RememberedArea(area: area, on: display)
    }

    /// Choose an area (or a window) and mark it up in place, on the frozen screen; then copy it, save
    /// it, or carry on in the editor.
    /// - Parameter copiesToClipboard: false for scripted checks, which never touch the clipboard.
    func annotateArea(copiesToClipboard: Bool = true) {
        guard !overlay.isActive else { return }
        cancelSelfTimer()
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        let title = frontWindowTitle()
        overlay.onAnnotate = { [weak self] request in self?.annotateInPlace(request, appName: app, windowTitle: title, copiesToClipboard: copiesToClipboard) }
        configureCaptureOverlay()
        overlay.begin(mode: .area, purpose: .annotate) { [weak self] outcome in
            if case .color(let color, let point, _, let modifiers, let keyboard) = outcome { self?.onColor?(color, point, modifiers, keyboard) }
        }
    }

    private func annotateInPlace(_ request: OverlayController.AnnotationRequest, appName: String?, windowTitle: String?, copiesToClipboard: Bool) {
        let display = request.display
        let host = request.host
        // The overlay is y up in global points; the frozen frame is y down from the display's corner.
        let area = CGRect(
            x: request.area.minX - display.frame.minX, y: display.frame.maxY - request.area.maxY,
            width: request.area.width, height: request.area.height
        )
        let scale = CGFloat(request.frame.image.width) / max(display.frame.width, 1)
        // Back to global points, y up, from wherever the selection was moved or resized to.
        let frame = { (result: InPlaceAnnotationView.Result) in
            CapturedFrame(image: result.capture, hdrImage: nil, displayID: display.id, frame: CGRect(
                x: display.frame.minX + result.area.minX, y: display.frame.maxY - result.area.maxY,
                width: result.area.width, height: result.area.height
            ))
        }
        let view = InPlaceAnnotationView(
            frame: request.frame.image, scale: scale, size: host.bounds.size, selection: area,
            actions: .init(
                copy: { [weak self] result in
                    // The overlay goes first, so the screen comes back at once; the result renders after.
                    self?.overlay.finishAnnotation()
                    Task { await self?.deliver(frame(result), appName: appName, windowTitle: windowTitle, copiesToClipboard: copiesToClipboard, marks: result.document, copy: .always) }
                },
                save: { [weak self] result in
                    self?.overlay.finishAnnotation()
                    Task { await self?.deliver(frame(result), appName: appName, windowTitle: windowTitle, copiesToClipboard: copiesToClipboard, marks: result.document, savesCopy: true) }
                },
                openInEditor: { [weak self] result in
                    self?.overlay.finishAnnotation()
                    Task { [weak self] in
                        guard let self, let entry = await self.deliver(
                            frame(result), appName: appName, windowTitle: windowTitle, marks: result.document, copy: .never, showsCard: false, playsSound: false
                        ) else { return }
                        self.openInEditor?(entry, scale)
                    }
                },
                cancel: { [weak self] in self?.overlay.cancel() }
            )
        )
        view.frame = host.bounds
        host.addSubview(view)
        view.begin()
        #if DEBUG
        inPlaceView = view
        #endif
    }

    // MARK: Capture Area and Pin

    /// Capture Area and Pin: choose an area (or a window), and it stays on screen as a pin where it was,
    /// at its own size. It is kept in the history like any capture, without a Quick Access card or the
    /// clipboard: the pin is where it went.
    /// - Parameter freezes: whether the screen holds still while choosing; nil follows the setting.
    func pinArea(freezes: Bool? = nil, followUp: CaptureFollowUp = .none) {
        begin(mode: .area, freezes: freezes, followUp: CaptureFollowUp(action: .pin, asksForName: followUp.asksForName, done: followUp.done))
    }

    /// Saves a picture with no file of its own (a pin from the clipboard) to the export location, named
    /// as captures are.
    func save(image: CGImage, scale: Double?) async -> URL? {
        await files.saveScreenshot(.init(image), scale: scale, asks: true)
    }

    // MARK: Self-Timer

    /// What Self-Timer captures at zero.
    private enum TimerTarget {
        case area(CGRect)
        /// With the keys held as it was clicked: Shift turns its background the other way round.
        case window(WindowTarget, NSEvent.ModifierFlags)
    }

    var isSelfTimerRunning: Bool {
        countdown.isRunning
    }

    /// Self-Timer: choose an area, a window, or the screen as for a screenshot; it is captured once the
    /// delay is over, as it is on screen then, so a menu or a hover card can be opened meanwhile.
    /// Pressing the shortcut again while it counts down cancels it.
    /// - Parameters:
    ///   - copiesToClipboard: false for scripted checks, which never touch the clipboard.
    ///   - freezes: whether the screen holds still while choosing; nil follows the setting.
    ///   - delay: seconds to wait; nil follows the setting. Scripted checks keep it short.
    ///   - followUp: the URL API's action, and whoever waits for the capture.
    func selfTimer(copiesToClipboard: Bool = true, freezes: Bool? = nil, delay: Int? = nil, followUp: CaptureFollowUp = .none) {
        if countdown.isRunning {
            cancelSelfTimer()
            return followUp.finish(nil)
        }
        guard !overlay.isActive else { return followUp.finish(nil) }
        overlay.freezesScreen = freezes ?? settings.freezeScreen
        // What is captured is the screen once the time is up: the frozen one, pointer or not, is only for choosing on.
        overlay.recapturesLive = true
        configureCaptureOverlay()
        overlay.begin(mode: .area) { [weak self] outcome in
            guard let self else { return followUp.finish(nil) }
            let seconds = delay ?? settings.selfTimerDelay
            switch outcome {
            case .region(let rect, _, _, _):
                // Whatever was frozen while choosing, what is captured is the screen once the time is up.
                countDown(to: .area(rect), seconds: seconds, copiesToClipboard: copiesToClipboard, followUp: followUp)
            case .window(let target, let modifiers):
                countDown(to: .window(target, modifiers), seconds: seconds, copiesToClipboard: copiesToClipboard, followUp: followUp)
            case .color(let color, let point, _, let modifiers, let keyboard):
                onColor?(color, point, modifiers, keyboard)
                followUp.finish(nil)
            case .annotated, .record, .scroll, .allInOne, .cancelled:
                followUp.finish(nil)
            }
        }
    }

    /// Stops a running Self-Timer; nothing is captured.
    func cancelSelfTimer() {
        guard countdown.isRunning else { return }
        countdown.cancel()
        timerFollowUp?.finish(nil)
        timerFollowUp = nil
        Log.capture.notice("Self-Timer cancelled")
        announce(String(localized: "Self-Timer cancelled."))
    }

    private func countDown(to target: TimerTarget, seconds: Int, copiesToClipboard: Bool, followUp: CaptureFollowUp) {
        let area = switch target {
        case .area(let rect): rect
        case .window(let window, _): window.frame
        }
        let keys = selfTimerKeys?()
        announce(keys.map { String(localized: "Capturing in \(seconds) seconds. Press \($0) again to cancel.") }
            ?? String(localized: "Capturing in \(seconds) seconds. Choose Cancel Self-Timer in the menu bar to cancel."))
        timerFollowUp = followUp
        countdown.start(seconds: seconds, area: area, layout: displays.layout) { [weak self] in
            guard let self else { return followUp.finish(nil) }
            timerFollowUp = nil
            // Another capture is being chosen: not captured under its overlay.
            guard !overlay.isActive else {
                Log.capture.notice("Self-Timer skipped: another capture was being chosen")
                return followUp.finish(nil)
            }
            // Named after what is in front now, which is what the capture shows.
            let app = NSWorkspace.shared.frontmostApplication?.localizedName
            let title = frontWindowTitle()
            #if DEBUG
            if let stand = selfTimerCapture, case .area(let rect) = target {
                if let frame = stand(rect) { Task { await self.deliver(frame, appName: "Demo", copiesToClipboard: false, followUp: followUp) } } else { followUp.finish(nil) }
                return
            }
            #endif
            Task {
                switch target {
                case .area(let rect): await self.captureArea(rect, appName: app, windowTitle: title, copiesToClipboard: copiesToClipboard, followUp: followUp)
                case .window(let window, let modifiers):
                    await self.captureWindow(window, copiesToClipboard: copiesToClipboard, followUp: followUp, modifiers: modifiers)
                }
            }
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    /// The area last chosen for a capture, in global points: what Capture Previous Area takes again.
    private(set) var previousArea: CGRect?

    /// Captures the area chosen last, as it is on screen now. Does nothing, but beep, before any was chosen.
    func capturePreviousArea(followUp: CaptureFollowUp = .none) {
        guard let rect = previousArea, !overlay.isActive else {
            NSSound.beep()
            return followUp.finish(nil)
        }
        cancelSelfTimer()
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        let title = frontWindowTitle()
        Task { await captureArea(rect, appName: app, windowTitle: title, followUp: followUp) }
    }

    /// Hover a window and click it: captured on its own, with its rounded corners and shadow.
    func captureWindow(followUp: CaptureFollowUp = .none) {
        begin(mode: .window, followUp: followUp)
    }

    /// Captures the whole display under the pointer.
    func captureFullscreen(followUp: CaptureFollowUp = .none) {
        let layout = displays.layout
        guard let display = layout.display(at: NSEvent.mouseLocation) ?? layout.primary else { return followUp.finish(nil) }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        let title = frontWindowTitle()
        Task {
            let probe = LatencyProbe("capture.fullscreen")
            do {
                let frame = try await capturer.captureDisplay(
                    display, dynamicRange: ScreenCapturer.dynamicRange(wantsHDR: wantsHDR, on: display), showsCursor: settings.screenshotShowsCursor
                )
                probe.end()
                await deliver(frame, appName: app, windowTitle: title, followUp: followUp)
            } catch {
                Log.capture.error("Fullscreen capture failed: \(error.localizedDescription, privacy: .public)")
                followUp.finish(nil)
            }
        }
    }

    /// Whether a capture asks for the extended-range copy of the screen: only a HEIC kept as the display shows it can
    /// use one (an sRGB conversion would throw its brightness away), so the others do not pay for it.
    private var wantsHDR: Bool {
        settings.screenshotFormat == .heic && !settings.convertsToSRGB
    }

    /// Captures an area, on one display or across several, and delivers it, as the overlay does after a
    /// drag on a live screen. Also used by scripted checks.
    /// - Parameter copiesToClipboard: false leaves the clipboard alone whatever the settings say, so
    ///   scripted test captures never replace what the user copied.
    func captureArea(_ rect: CGRect, appName: String?, windowTitle: String? = nil, copiesToClipboard: Bool = true, followUp: CaptureFollowUp = .none) async {
        let probe = LatencyProbe("capture.region")
        do {
            let frame = try await capturer.captureArea(rect, in: displays.layout, wantsHDR: wantsHDR, showsCursor: settings.screenshotShowsCursor)
            probe.end()
            await deliver(frame, appName: appName, windowTitle: windowTitle, copiesToClipboard: copiesToClipboard, followUp: followUp)
        } catch {
            Log.capture.error("Region capture failed: \(error.localizedDescription, privacy: .public)")
            followUp.finish(nil)
        }
    }

    /// Keeps a scrolling capture's picture as a screenshot is kept: History, the clipboard as the settings say,
    /// a card, the shutter. `area` is where the capture began (global points), `pixelsPerPoint` its display's.
    @discardableResult
    func deliverScrollingCapture(
        _ image: CGImage, area: CGRect, pixelsPerPoint: CGFloat, displayID: CGDirectDisplayID, appName: String?, copiesToClipboard: Bool = true
    ) async -> HistoryItem? {
        let size = CGSize(width: CGFloat(image.width) / pixelsPerPoint, height: CGFloat(image.height) / pixelsPerPoint)
        let frame = CapturedFrame(
            image: image, hdrImage: nil, displayID: displayID,
            frame: CGRect(x: area.minX, y: area.maxY - size.height, width: size.width, height: size.height)
        )
        // Kept as captured: the background chosen for every screenshot pads by the picture's size and grows it to its
        // shape, which for a picture tens of thousands of pixels long is gigabytes; the editor still adds one.
        return await deliver(frame, appName: appName, copiesToClipboard: copiesToClipboard, background: .none)
    }

    #if DEBUG
    /// Delivers a drawn picture as if it were a capture (history and a card), never touching the
    /// clipboard: for scripted checks that must not read the screen.
    func deliverDemo(_ image: CGImage, displayID: CGDirectDisplayID) async {
        let frame = CapturedFrame(image: image, hdrImage: nil, displayID: displayID, frame: CGRect(x: 0, y: 0, width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
        await deliver(frame, appName: "Demo", copiesToClipboard: false)
    }
    #endif

    // MARK: Saving

    /// Saves a copy of a capture to the export location, in the format Settings choose and named from the file name
    /// pattern; asks for the name first when Settings say so and `asks` is true (a save nobody waits at, as a card's
    /// closing by itself or Save All is, passes false). Nil when it was cancelled or failed.
    func save(_ item: QuickAccessItem, asks: Bool = true) async -> URL? {
        guard ExportedFiles.isPicture(item.fileURL) else { return save(fileAt: item.fileURL) }
        return await files.saveScreenshot(fileAt: item.fileURL, asks: asks)
    }

    /// Saves a copy of a recording's file, or any file that is no screenshot, to the export location, under the file's
    /// name and kind.
    func save(fileAt url: URL) -> URL? {
        do {
            let directory = settings.exportDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = url.deletingPathExtension().lastPathComponent
            let destination = ImageExporter.availableURL(in: directory, name: name, fileExtension: url.pathExtension)
            try FileManager.default.copyItem(at: url, to: destination)
            Log.capture.notice("Saved \(destination.lastPathComponent, privacy: .public)")
            return destination
        } catch {
            Log.capture.error("Saving failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
            return nil
        }
    }

    /// Asks where to save a copy. A screenshot is saved in the format of the name typed, else the one Settings choose.
    func saveAs(_ item: QuickAccessItem) async -> URL? {
        guard ExportedFiles.isPicture(item.fileURL) else { return await files.saveRecordingAs(item.fileURL) }
        return await files.saveScreenshotAs(fileAt: item.fileURL)
    }

    // MARK: Private

    private func begin(
        mode: OverlayController.Mode, copiesToClipboard: Bool = true, freezes: Bool? = nil, area: CGRect? = nil, followUp: CaptureFollowUp = .none
    ) {
        guard !overlay.isActive else { return followUp.finish(nil) }
        // A new capture replaces a Self-Timer still counting down, rather than leaving it under the overlay.
        cancelSelfTimer()
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        let title = frontWindowTitle()
        overlay.freezesScreen = freezes ?? settings.freezeScreen
        configureCaptureOverlay()
        overlay.begin(mode: mode, choosing: area) { [weak self] outcome in
            guard let self else { return followUp.finish(nil) }
            switch outcome {
            case .region(let rect, _, _, let frozen?):
                // The screen was held still: the selection is kept as it was seen.
                previousArea = rect
                Task { await self.deliver(frozen, appName: app, windowTitle: title, copiesToClipboard: copiesToClipboard, followUp: followUp) }
            case .region(let rect, _, _, nil):
                previousArea = rect
                Task { await self.captureArea(rect, appName: app, windowTitle: title, copiesToClipboard: copiesToClipboard, followUp: followUp) }
            case .window(let target, let modifiers):
                // A window is captured on its own, frozen or not: with its shadow and its transparent
                // corners, which the frozen screen does not have.
                Task { await self.captureWindow(target, copiesToClipboard: copiesToClipboard, followUp: followUp, modifiers: modifiers) }
            case .color(let color, let point, _, let modifiers, let keyboard):
                onColor?(color, point, modifiers, keyboard)
                followUp.finish(nil)
            case .annotated, .record, .scroll, .allInOne, .cancelled:
                followUp.finish(nil)
            }
        }
    }

    /// Captures a window on its own, with its shadow while Settings keep it, on the background Settings choose for
    /// windows; `modifiers` with Shift, as the window was clicked, takes it the other way round.
    private func captureWindow(
        _ target: WindowTarget, copiesToClipboard: Bool = true, followUp: CaptureFollowUp = .none, modifiers: NSEvent.ModifierFlags = []
    ) async {
        let probe = LatencyProbe("capture.window")
        do {
            let frame = try await capturer.captureWindow(target, shadow: settings.windowShadow, layout: displays.layout, showsCursor: settings.screenshotShowsCursor)
            probe.end()
            let background = await windowBackground(for: frame, shiftHeld: modifiers.contains(.shift))
            // The display's scale: the capture is larger than the window's frame by its shadow.
            await deliver(
                frame, appName: target.ownerName, windowTitle: target.title, copiesToClipboard: copiesToClipboard, background: background,
                pixelsPerPoint: displays.layout.display(id: frame.displayID)?.pixelsPerPoint, followUp: followUp
            )
        } catch {
            Log.capture.error("Window capture failed: \(error.localizedDescription, privacy: .public)")
            followUp.finish(nil)
        }
    }

    /// What a window screenshot is put on: Settings' choice for windows, flipped by Shift as it was clicked. The
    /// desktop picture is taken around the window as the display shows it now and kept with the pictures backgrounds
    /// use, so the capture can be marked up and kept the same later.
    private func windowBackground(for frame: CapturedFrame, shiftHeld: Bool) async -> CaptureBackground {
        let resolved = settings.windowBackground.resolved(automaticPreset: BackdropPresets.shared.automatic != nil, shiftHeld: shiftHeld)
        switch resolved {
        case .none: return .none
        case .preset: return .automatic
        case .wallpaper:
            guard let backdrop = await wallpaperBackdrop(around: frame) else {
                Log.capture.notice("Window screenshot without the desktop picture: it could not be taken")
                return .none
            }
            return .backdrop(backdrop)
        }
    }

    #if DEBUG
    /// A drawn window (`image`, at `frame` in global points) put on the desktop picture as a window screenshot would
    /// be, rendered and returned; nothing is kept. For scripted checks.
    func debugWindowOnWallpaper(_ image: CGImage, frame: CGRect, displayID: CGDirectDisplayID) async -> CGImage? {
        let captured = CapturedFrame(image: image, hdrImage: nil, displayID: displayID, frame: frame)
        guard let backdrop = await wallpaperBackdrop(around: captured) else { return nil }
        let scale = displays.layout.display(id: displayID)?.pixelsPerPoint ?? 2
        guard let composed = await composed(image, scale: scale, marks: nil, background: .backdrop(backdrop)),
              let document = try? JSONDecoder().decode(AnnotationDocument.self, from: composed.document) else { return nil }
        Log.capture.notice("debug window-on-wallpaper: background \(String(describing: document.backdrop?.fill), privacy: .public), \(composed.image.width, privacy: .public)x\(composed.image.height, privacy: .public)")
        // The piece of the wallpaper it stored is in no capture's marks: the next sweep takes it.
        return composed.image
    }
    #endif

    /// The desktop picture around a window capture as a background: as much of it as the finished picture covers.
    private func wallpaperBackdrop(around frame: CapturedFrame) async -> Backdrop? {
        let layout = displays.layout
        guard let display = layout.display(id: frame.displayID) ?? layout.display(at: CGPoint(x: frame.frame.midX, y: frame.frame.midY)),
              let wallpaper = try? await capturer.captureWallpapers(of: [display])[display.id] else { return nil }
        let padding = CaptureBackground.wallpaperPadding
        let picture = WallpaperCrop.pictureFrame(of: frame.image, window: frame.frame, pixelsPerPoint: display.pixelsPerPoint)
        guard let region = WallpaperCrop.region(
            around: picture, picturePixels: CGSize(width: frame.image.width, height: frame.image.height), padding: padding, on: display
        ), let crop = wallpaper.cropping(to: region) else { return nil }
        // A background is soft: a JPEG of it, no larger than a background is ever read, keeps the pictures folder
        // small. The same picture is kept once.
        guard let data = try? await ImageExporter.encode(Self.shrunk(crop, toAtMost: PictureStore.backgroundLimit), as: .jpeg),
              let name = try? PictureStore.shared.add(data, fileExtension: "jpg", prefix: CaptureBackground.wallpaperPrefix)
        else {
            return nil
        }
        var backdrop = Backdrop(fill: .picture(name), padding: padding)
        // Without the window's shadow, none is drawn under a window with square corners either.
        if !settings.windowShadow { backdrop.shadow = 0 }
        return backdrop
    }

    /// `image` with its longer side at most `limit` pixels, its shape kept.
    private nonisolated static func shrunk(_ image: CGImage, toAtMost limit: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > limit else { return image }
        let factor = CGFloat(limit) / CGFloat(longest)
        let width = max(Int((CGFloat(image.width) * factor).rounded()), 1), height = max(Int((CGFloat(image.height) * factor).rounded()), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Whether a delivered capture goes to the clipboard: as the settings say, always (copying is what
    /// finishing in-place annotation means), or never (it carries on in the editor).
    enum Copy {
        case asSet
        case always
        case never
    }

    /// Keeps a capture in the history, copies it, saves it, and gives it a Quick Access card, as the
    /// settings say. `marks` are drawn on it first (in-place annotation); the background chosen for
    /// every screenshot is set under them. Returns its record.
    /// `followUp`'s action comes on top of the settings: copy copies whatever they say, save saves; annotate and
    /// pin keep the capture as the editor and Capture Area and Pin do, off the clipboard and without a card.
    /// `pixelsPerPoint` is the capture's scale where its frame does not give it (a window's, larger by its shadow).
    @discardableResult
    private func deliver(
        _ frame: CapturedFrame, appName: String?, windowTitle: String? = nil, copiesToClipboard: Bool = true,
        marks: AnnotationDocument? = nil, copy: Copy = .asSet, savesCopy: Bool = false, showsCard: Bool = true, playsSound: Bool = true,
        background: CaptureBackground = .automatic, pixelsPerPoint: CGFloat? = nil, followUp: CaptureFollowUp = .none
    ) async -> HistoryItem? {
        let action = followUp.action
        let copying: Copy = switch action {
        case .copy: .always
        case .annotate, .pin: .never
        case .save, .upload, nil: copy
        }
        let saving = savesCopy || action == .save
        let carded = showsCard && action != .annotate && action != .pin
        if settings.playSounds, playsSound { shutter?.play() }
        let probe = LatencyProbe("capture.deliver")
        // The picture still to be put on the clipboard, with the file beside it, once the file is there.
        var waiting: (picture: ScreenshotFiles.Picture, png: Data, scale: Double)?
        do {
            let png = try await ImageExporter.encode(frame.image, as: .png)
            // Marks drawn in place, and the background chosen for every screenshot, are drawn in first. The
            // capture's file then shows them while the capture and the document stay beside it, as edits
            // do, so the editor can change or remove them.
            var shown = (image: frame.image, png: png)
            var document: Data?
            let scale = pixelsPerPoint ?? (frame.frame.width > 0 ? CGFloat(frame.image.width) / frame.frame.width : 1)
            if let composed = await composed(frame.image, scale: scale, marks: marks, background: background),
               let composedPNG = try? await ImageExporter.encode(composed.image, as: .png) {
                shown = (composed.image, composedPNG)
                document = composed.document
            }
            let copies = switch copying {
            case .asSet: copiesToClipboard && settings.copyAfterCapture
            case .always: copiesToClipboard
            case .never: false
            }
            // The extended-range copy goes only with the picture as it was captured: marks or a background change it.
            let picture = ScreenshotFiles.Picture(shown.image, hdr: document == nil ? frame.hdrImage : nil)
            // One moment for the name and the record, which a copy saved later is named from again.
            let takenAt = Date.now
            let name = settings.nextFileName(date: takenAt, appName: appName, windowTitle: windowTitle)
            // On the clipboard before anything is written, so the picture is not lost if keeping it fails; with the
            // file beside it, once the file is there.
            if copies, settings.clipboardFormat == .fileAndPicture {
                waiting = (picture, shown.png, Double(scale))
            } else if copies {
                await files.copy(picture, png: shown.png, name: name, scale: Double(scale))
            }
            var entry = try history.add(
                data: png,
                name: name,
                fileExtension: ImageExporter.Format.png.fileExtension,
                kind: .screenshot,
                pixelWidth: frame.image.width,
                pixelHeight: frame.image.height,
                appName: appName,
                pixelsPerPoint: Double(scale),
                windowTitle: windowTitle,
                isTemplateNamed: true,
                date: takenAt
            )
            if let document {
                entry = try history.replaceImage(
                    of: entry, with: shown.png, pixelWidth: shown.image.width, pixelHeight: shown.image.height, annotations: document
                )
            }
            if let pending = waiting {
                waiting = nil
                await files.copy(pending.picture, png: pending.png, name: (entry.fileName as NSString).deletingPathExtension, scale: pending.scale, historyFile: history.fileURL(for: entry))
            }
            var item = QuickAccessItem(
                id: entry.id,
                fileURL: history.fileURL(for: entry),
                thumbnail: await HistoryStore.cardThumbnail(of: shown.image, maxPixels: 560) ?? shown.image,
                pixelWidth: shown.image.width,
                pixelHeight: shown.image.height,
                displayID: frame.displayID,
                createdAt: entry.createdAt
            )
            if settings.saveAfterCapture || saving {
                // Asking for the name is for someone at the keyboard: All-In-One's Save is asked, a save the URL API or a
                // shortcut asked for is not.
                item.savedURL = await files.saveScreenshot(
                    fileAt: item.fileURL, entry: entry, scale: Double(scale), picture: picture, asks: followUp.asksForName
                )
            }
            probe.end()
            Log.capture.notice("Captured \(frame.image.width, privacy: .public)x\(frame.image.height, privacy: .public) into history as \(entry.fileName, privacy: .public)\(marks.map { " with \($0.items.count) mark(s)" } ?? "", privacy: .public)")
            // Before the card, so a follow-up that holds the capture (an upload) is in place when the card
            // decides whether anything else still needs the file.
            if action == .upload || (settings.uploadAfterCapture && carded) { uploadKept?(entry) }
            switch action {
            case .annotate: openInEditor?(entry, scale)
            case .pin: onPin?(frame, entry)
            case .copy, .save, .upload, nil: break
            }
            if carded { onCaptured?(item) }
            followUp.finish(entry)
            return entry
        } catch {
            Log.capture.error("Keeping the capture failed: \(error.localizedDescription, privacy: .public)")
            // The picture is still copied, without a file.
            if let pending = waiting {
                await files.copy(pending.picture, png: pending.png, name: "OhMyShot", scale: pending.scale, withFile: false)
            }
            // Said out loud too: the overlay is gone, and nothing else would show that the capture was not kept.
            NSSound.beep()
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: String(localized: "The capture couldn’t be kept."), .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
            followUp.finish(nil)
            return nil
        }
    }

    /// The capture as it is kept: with marks drawn in place and the background chosen for every new
    /// screenshot set under them, and the document that recreates it; nil when it is kept as captured.
    private func composed(_ image: CGImage, scale: CGFloat, marks: AnnotationDocument?, background: CaptureBackground = .automatic) async -> (image: CGImage, document: Data)? {
        var document = marks ?? AnnotationDocument(pixelSize: CGSize(width: image.width, height: image.height), scale: scale)
        if document.backdrop == nil {
            switch background {
            case .automatic: document.backdrop = BackdropPresets.shared.automatic?.backdrop
            case .none: break
            case .backdrop(let backdrop): document.backdrop = backdrop
            }
        }
        guard !document.isEmpty, let rendered = await AnnotationRenderer.render(document, base: image), let data = try? JSONEncoder().encode(document) else { return nil }
        return (rendered, data)
    }
}

/// What else happens to a capture once it is kept, beyond what Settings says: the URL API's `action`, and a
/// shortcut's action waiting for the capture.
struct CaptureFollowUp {
    var action: CaptureAction?
    /// Told the capture's record once it is kept, or nil when none is: it was cancelled, or failed.
    var done: ((HistoryItem?) -> Void)?
    /// Whether saving the capture asks for the file's name first, when Settings say to. Someone at the keyboard is
    /// asked (All-In-One's Save too); a save the URL API or a shortcut asked for is nobody's to answer, so it is not.
    var asksForName: Bool

    static let none = CaptureFollowUp()

    init(action: CaptureAction? = nil, asksForName: Bool = true, done: ((HistoryItem?) -> Void)? = nil) {
        self.action = action
        self.asksForName = asksForName
        self.done = done
    }

    func finish(_ entry: HistoryItem?) {
        done?(entry)
    }
}

/// What a kept capture is put on: the background chosen for every new screenshot, none, or one of its own (a window
/// screenshot on the desktop picture).
enum CaptureBackground {
    case automatic
    case none
    case backdrop(Backdrop)

    /// The room around a window on the desktop picture, as a fraction of its measure.
    static let wallpaperPadding: CGFloat = 0.08
    /// What the desktop pictures' pieces kept for window screenshots are named with, so they can go again once
    /// nothing uses them.
    nonisolated static let wallpaperPrefix = "wallpaper-"
}
