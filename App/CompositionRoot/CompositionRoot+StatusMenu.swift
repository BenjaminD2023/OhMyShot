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

/// The menu bar icon and its menu.
extension CompositionRoot {
    /// The menu bar icon and its menu: the captures, the tools, the pictures to open or pin, the history, and the app.
    func makeStatusItem() -> StatusItemController {
        let statusItem = StatusItemController(
            captureEntries: [
                .init(title: String(localized: "All-In-One"), systemImage: "camera.viewfinder", shortcut: .allInOne) { [weak self] in self?.handle(.allInOne) },
                .init(title: String(localized: "Capture Area"), systemImage: "rectangle.dashed", shortcut: .captureArea) { [weak self] in self?.handle(.captureArea) },
                .init(title: String(localized: "Annotate Area"), systemImage: "pencil.and.scribble", shortcut: .annotateArea) { [weak self] in self?.handle(.annotateArea) },
                .init(title: String(localized: "Capture Area and Pin"), systemImage: "pin", shortcut: .pinArea) { [weak self] in self?.handle(.pinArea) },
                // The rest of what an area can go straight to, out of the way of the ones used most.
                .init(title: String(localized: "More Area Captures"), systemImage: "rectangle.dashed.badge.record") { [weak self] in
                    [
                        .init(title: String(localized: "Capture Area and Copy"), shortcut: .captureAreaAndCopy) { [weak self] in self?.handle(.captureAreaAndCopy) },
                        .init(title: String(localized: "Capture Area and Save"), shortcut: .captureAreaAndSave) { [weak self] in self?.handle(.captureAreaAndSave) },
                        .init(title: String(localized: "Capture Area and Annotate"), shortcut: .captureAreaAndAnnotate) { [weak self] in self?.handle(.captureAreaAndAnnotate) },
                        .init(
                            title: String(localized: "Capture Area and Upload"),
                            shortcut: .captureAreaAndUpload,
                            isHidden: { [weak self] in self?.uploads.destinations.menu.isHidden != false }
                        ) { [weak self] in self?.handle(.captureAreaAndUpload) },
                    ]
                },
                .init(title: String(localized: "Capture Window"), systemImage: "macwindow", shortcut: .captureWindow) { [weak self] in self?.handle(.captureWindow) },
                .init(title: String(localized: "Capture Fullscreen"), systemImage: "display", shortcut: .captureFullscreen) { [weak self] in self?.handle(.captureFullscreen) },
                .init(
                    title: String(localized: "Self-Timer"),
                    systemImage: "timer",
                    shortcut: .selfTimer,
                    currentTitle: { [weak self] in
                        self?.captures.isSelfTimerRunning == true ? String(localized: "Cancel Self-Timer") : String(localized: "Self-Timer")
                    }
                ) { [weak self] in
                    self?.handle(.selfTimer)
                },
                .init(
                    title: String(localized: "Scrolling Capture"),
                    systemImage: "scroll",
                    shortcut: .scrollingCapture,
                    currentTitle: { [weak self] in self?.scrolling.menuTitle ?? String(localized: "Scrolling Capture") }
                ) { [weak self] in
                    self?.handle(.scrollingCapture)
                },
                .init(
                    title: String(localized: "Cancel Scrolling Capture"),
                    systemImage: "xmark.circle",
                    isHidden: { [weak self] in self?.scrolling.isCapturing != true }
                ) { [weak self] in
                    self?.scrolling.cancel()
                },
                .init(
                    title: String(localized: "Record Screen"),
                    systemImage: "record.circle",
                    shortcut: .recordScreen,
                    currentTitle: { [weak self] in
                        guard let self else { return String(localized: "Record Screen") }
                        if recordings.isRecording { return String(localized: "Stop Recording") }
                        if recordings.isCountingDown { return String(localized: "Cancel Recording") }
                        return String(localized: "Record Screen")
                    }
                ) { [weak self] in
                    self?.handle(.recordScreen)
                },
                // While a Studio movie is exported after its window closed, it can be stopped from here.
                .init(
                    title: String(localized: "Cancel Studio Export"),
                    systemImage: "xmark.circle",
                    isHidden: { [weak self] in self?.recordings.isExportingStudio != true }
                ) { [weak self] in
                    self?.recordings.cancelStudioExports()
                },
            ] + replayEntries() + [
                .init(title: String(localized: "Capture Text"), systemImage: "text.viewfinder", shortcut: .captureText) { [weak self] in self?.handle(.captureText) },
                .init(
                    title: String(localized: "Capture Formula"), systemImage: "function", shortcut: .captureFormula,
                    isHidden: { [weak self] in self?.readerPacks.formula == nil }
                ) { [weak self] in
                    self?.handle(.captureFormula)
                },
                .init(title: String(localized: "Translate Area"), systemImage: "translate", shortcut: .translateArea) { [weak self] in self?.handle(.translateArea) },
            ],
            // The status menu holds these in Tools; the launcher lists them.
            toolEntries: [
                .init(title: String(localized: "Pick Color"), systemImage: "eyedropper", shortcut: .pickColor) { [weak self] in self?.handle(.pickColor) },
                .init(title: String(localized: "Measure"), systemImage: "ruler", shortcut: .measure) { [weak self] in self?.handle(.measure) },
                .separator,
                .init(
                    title: String(localized: "Hide Desktop Icons"),
                    systemImage: "eye.slash",
                    currentTitle: { [weak self] in
                        self?.settings.hidesDesktopIcons == true ? String(localized: "Show Desktop Icons") : String(localized: "Hide Desktop Icons")
                    }
                ) { [weak self] in
                    guard let self else { return }
                    setDesktopIconsHidden(!settings.hidesDesktopIcons)
                },
            ],
            imageEntries: [
                // A picture already on disk or on the clipboard, to annotate, pin, or read.
                .init(title: String(localized: "Open Image"), systemImage: "photo") { [weak self] in
                    [
                        .init(title: String(localized: "Annotate…")) { [weak self] in self?.chooseFilesToAnnotate() },
                        .init(title: String(localized: "Pin…")) { [weak self] in self?.choosePicturesToPin() },
                        .init(title: String(localized: "Recognize Text…")) { [weak self] in self?.textCapture.openImageFile() },
                    ]
                },
                .init(title: String(localized: "From Clipboard"), systemImage: "list.clipboard") { [weak self] in
                    [
                        .init(
                            title: String(localized: "Annotate"),
                            shortcut: .openFromClipboard,
                            isEnabled: { PasteboardImage.mayHoldImage(.general) }
                        ) { [weak self] in
                            self?.handle(.openFromClipboard)
                        },
                        .init(title: String(localized: "Pin"), isEnabled: { Self.clipboardMayHoldPin() }) { [weak self] in self?.pinClipboard() },
                        .init(
                            title: String(localized: "Recognize Text"),
                            isEnabled: { PasteboardImage.mayHoldImage(.general) }
                        ) { [weak self] in
                            self?.textCapture.openClipboardImage()
                        },
                    ]
                },
                .init(title: String(localized: "Pins"), systemImage: "pin.circle") { [weak self] in
                    [
                        .init(
                            title: String(localized: "Hide Pins"),
                            isEnabled: { [weak self] in !(self?.pins.isEmpty ?? true) },
                            currentTitle: { [weak self] in self?.pins.areHidden == true ? String(localized: "Show Pins") : String(localized: "Hide Pins") }
                        ) { [weak self] in
                            guard let self else { return }
                            pins.setHidden(!pins.areHidden)
                        },
                        .init(
                            title: String(localized: "Unlock Pins"),
                            isEnabled: { [weak self] in self?.pins.hasLockedPins ?? false }
                        ) { [weak self] in
                            self?.pins.unlockAll()
                        },
                        .init(
                            title: String(localized: "Close All Pins"),
                            isEnabled: { [weak self] in !(self?.pins.isEmpty ?? true) }
                        ) { [weak self] in
                            self?.pins.closeAll()
                        },
                    ]
                },
            ],
            historyEntries: [
                .init(title: String(localized: "Annotate Latest Capture"), systemImage: "pencil.tip.crop.circle", shortcut: .annotateLatestCapture) { [weak self] in self?.handle(.annotateLatestCapture) },
                .init(title: String(localized: "Capture History…"), systemImage: "clock.arrow.circlepath", shortcut: .openHistory) { [weak self] in self?.showHistory() },
                .init(
                    title: String(localized: "Restore Recently Closed"),
                    systemImage: "arrow.uturn.backward.circle",
                    isEnabled: { [weak self] in self?.quickAccess.canRestoreRecentlyClosed ?? false }
                ) { [weak self] in
                    self?.quickAccess.restoreRecentlyClosed()
                },
            ],
            priorityEntries: [
                .init(title: String(localized: "Check for Updates…"), systemImage: "arrow.down.circle.fill",
                      isEnabled: { [weak self] in self?.updates?.status.canCheck ?? false },
                      currentTitle: { [weak self] in self?.updates?.menuTitle ?? "" },
                      isHidden: { [weak self] in self?.updates?.status.waiting == nil }) { [weak self] in self?.updates?.checkNow() },
            ],
            appEntries: [
                .init(title: String(localized: "Getting Started…"), systemImage: "questionmark.circle") { [weak self] in self?.replayOnboarding() },
                .init(title: String(localized: "Join Discord"), systemImage: "bubble.left.and.bubble.right") { NSWorkspace.shared.open(CommunityInvite.discord) },
                .init(
                    title: String(localized: "Check for Updates…"),
                    systemImage: "arrow.triangle.2.circlepath",
                    isEnabled: { [weak self] in self?.updates?.status.canCheck ?? false },
                    currentTitle: { [weak self] in self?.updates?.menuTitle ?? "" },
                    isHidden: { [weak self] in self?.updates == nil || self?.updates?.status.waiting != nil }
                ) { [weak self] in
                    self?.updates?.checkNow()
                },
                .init(title: String(localized: "What’s New…"), systemImage: "sparkles", isHidden: { [weak self] in self?.updates == nil }) { [weak self] in self?.updates?.showReleaseNotes() },
            ],
            openSettings: { [weak self] in self?.showSettings() },
            // A shortcut's row in Settings › Shortcuts, lit up, or the pane's top for none.
            editShortcut: { [weak self] shortcut in self?.showSettings(.shortcuts, landingOn: shortcut?.title) },
            quit: { NSApp.terminate(nil) },
            debugEntries: debugMenuEntries()
        )
        statusItem.onDrop = { [weak self] pasteboard in
            self?.textCapture.openPanel(from: pasteboard, source: String(localized: "Dropped Image")) ?? false
        }
        return statusItem
    }

    /// The replay's menu bar entries: the displays to keep (with how saved clips sound), and Save.
    private func replayEntries() -> [StatusItemController.Entry] {
        guard #available(macOS 27, *), replay != nil else { return [] }
        return [
            .init(title: String(localized: "Keep Last 15 Seconds"), systemImage: "gobackward.15") { [weak self] in self?.replayMenu() ?? [] },
        ]
    }

    /// The replay's submenu, made each time it opens: saving what was kept, a checkmark for each display
    /// kept, then the sound saved clips keep.
    @available(macOS 27, *)
    private func replayMenu() -> [StatusItemController.Entry] {
        guard let replay else { return [] }
        var entries: [StatusItemController.Entry] = [
            .init(
                title: String(localized: "Save Last 15 Seconds"), shortcut: .saveReplay,
                isEnabled: { [weak replay] in replay?.canSave == true }
            ) { [weak self] in
                self?.handle(.saveReplay)
            },
            .separator,
            .header(String(localized: "Displays")),
        ]
        for display in displays.layout.displays {
            entries.append(.init(title: display.name, isChecked: { [weak replay] in replay?.isKeeping(display.id) == true }) { [weak self, weak replay] in
                guard self?.permissions.status(of: .screenRecording) == .granted else {
                    self?.showOnboarding()
                    return
                }
                replay?.toggle(display)
            })
        }
        entries.append(.separator)
        entries.append(.header(String(localized: "Sound in Saved Clips")))
        for sound in ReplaySound.allCases {
            let title = switch sound {
            case .all: String(localized: "System and Microphone")
            case .system: String(localized: "System Only")
            case .microphone: String(localized: "Microphone Only")
            case .none: String(localized: "No Sound")
            }
            // Without microphone access only the system's sound is kept: the choices with the microphone
            // step back, their check kept for when access comes back.
            let needsMicrophone = sound.keepsMicrophone
            entries.append(.init(
                title: title,
                isEnabled: { [weak self] in !needsMicrophone || self?.permissions.status(of: .microphone) != .denied },
                isChecked: { [weak self] in self?.settings.replaySound == sound }
            ) { [weak self] in
                self?.settings.replaySound = sound
            })
        }
        return entries
    }
}
