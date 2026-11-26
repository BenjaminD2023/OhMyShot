import AppKit
import CoreGraphics
import OMSCore
import Testing
@testable import OMSCapture

/// Unit tests for `SelfTimerDelayBar` and the overlay's temporary Self-Timer delay switcher (`M-21`).
@MainActor
struct SelfTimerDelayBarTests {
    @Test func configureIncludesCustomDelayInSortedOrderAndPreservesItWhileSwitching() {
        let bar = SelfTimerDelayBar()
        bar.configure(selected: 7)

        #expect(bar.availableDelays == [2, 3, 5, 7, 10, 15])
        #expect(bar.selectedDelay == 7)
        #expect(bar.visibleChips.count == 6)

        // Accessibility label and tooltip describe each chip for VoiceOver and hover help.
        let sevenChip = bar.visibleChips[3]
        #expect(sevenChip.tag == 7)
        #expect(sevenChip.state == .on)
        #expect(sevenChip.accessibilityLabel() == "7 seconds")
        #expect(sevenChip.toolTip == "Capture after 7 seconds (this capture only)")

        // Switching to a preset during the same session preserves the custom 7s chip.
        var picked: [Int] = []
        bar.onSelect = { picked.append($0) }
        bar.visibleChips[2].performClick(nil) // 5s
        #expect(picked == [5])
        #expect(bar.selectedDelay == 5)
        #expect(bar.availableDelays == [2, 3, 5, 7, 10, 15])
        #expect(bar.visibleChips[2].state == .on)
        #expect(bar.visibleChips[3].state == .off)

        // Starting a fresh session with a standard preset resets to the 5 default presets.
        bar.configure(selected: 3)
        #expect(bar.availableDelays == SelfTimerDelayBar.defaultDelays)
        #expect(bar.selectedDelay == 3)
        #expect(bar.visibleChips.count == 5)
    }

    @Test func cycleNextWrapsAroundAndPresetIndexChecksBounds() {
        let bar = SelfTimerDelayBar()
        bar.configure(selected: 10)

        #expect(bar.delay(atPresetIndex: 0) == 2)
        #expect(bar.delay(atPresetIndex: 4) == 15)
        #expect(bar.delay(atPresetIndex: 5) == nil)
        #expect(bar.delay(atPresetIndex: -1) == nil)

        #expect(bar.cycleNext() == 15)
        #expect(bar.selectedDelay == 15)
        #expect(bar.cycleNext() == 2)
        #expect(bar.selectedDelay == 2)
    }
}

#if DEBUG
@MainActor
struct SelfTimerDelayOverlayTests {
    /// Two synthetic displays far from real screen coordinates so `layout.primary` (`displayA`) is
    /// deterministically chosen as the pointer display.
    private static let displayA = DisplayInfo(
        id: 201, name: "Left", frame: CGRect(x: 100_000, y: 0, width: 1000, height: 700),
        pixelSize: CGSize(width: 2000, height: 1400), backingScale: 2, maximumPotentialEDR: 1
    )
    private static let displayB = DisplayInfo(
        id: 202, name: "Right", frame: CGRect(x: 101_000, y: 0, width: 1000, height: 700),
        pixelSize: CGSize(width: 2000, height: 1400), backingScale: 2, maximumPotentialEDR: 1
    )
    private static let layout = DisplayLayout(displays: [displayA, displayB])

    private static func solidFrame(on display: DisplayInfo) throws -> CapturedFrame {
        let width = Int(display.pixelSize.width)
        let height = Int(display.pixelSize.height)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return CapturedFrame(image: try #require(context.makeImage()), hdrImage: nil, displayID: display.id, frame: display.frame)
    }

    private func makeController() throws -> OverlayController {
        let controller = OverlayController(layoutProvider: { Self.layout }, capturer: ScreenCapturer(content: ShareableContentCache()))
        controller.presentsPanels = false
        controller.freezesScreen = false
        controller.injectedFrames = [
            Self.displayA.id: try Self.solidFrame(on: Self.displayA),
            Self.displayB.id: try Self.solidFrame(on: Self.displayB),
        ]
        return controller
    }

    private func keyEvent(_ character: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode
        ))
    }

    @Test func barIsHiddenForNormalSessionsAndShownAboveToolbarForSelfTimerSessions() throws {
        let controller = try makeController()
        defer { controller.cancel() }

        // Normal screenshot session: delay bar stays hidden and currentSelfTimerDelay is nil.
        controller.begin(mode: .area, purpose: .screenshot) { _ in }
        let viewA = try #require(controller.overlayView(for: Self.displayA.id))
        let viewB = try #require(controller.overlayView(for: Self.displayB.id))
        viewA.layoutSubtreeIfNeeded()
        #expect(controller.currentSelfTimerDelay == nil)
        #expect(viewA.debugSelfTimerBarFrame == nil)
        #expect(viewA.debugSelfTimerDelay == nil)
        #expect(viewB.debugSelfTimerBarFrame == nil)

        var changes: [Int] = []
        controller.onSelfTimerDelayChange = { changes.append($0) }
        viewA.keyDown(with: try keyEvent("d", keyCode: 2))
        viewA.keyDown(with: try keyEvent("1", keyCode: 18))
        #expect(changes.isEmpty)
        controller.cancel()

        // Re-inject frames before starting the reused session (`end(_:)` clears `injectedFrames`).
        controller.injectedFrames = [
            Self.displayA.id: try Self.solidFrame(on: Self.displayA),
            Self.displayB.id: try Self.solidFrame(on: Self.displayB),
        ]
        // Reused session with selfTimerDelay: delay bar appears centered just above the mode toolbar on displayA.
        controller.begin(mode: .area, purpose: .screenshot, options: .init(recapturesLive: true, selfTimerDelay: 5)) { _ in }
        viewA.layoutSubtreeIfNeeded()
        #expect(controller.currentSelfTimerDelay == 5)
        #expect(viewA.debugSelfTimerDelay == 5)
        #expect(viewB.debugSelfTimerDelay == 5)
        let barFrame = try #require(viewA.debugSelfTimerBarFrame)
        let toolbarFrame = viewA.debugToolbarFrame
        #expect(barFrame.minY >= toolbarFrame.maxY + 9)
        #expect(!barFrame.intersects(toolbarFrame))
        #expect(viewB.debugSelfTimerBarFrame == nil)
        #expect(viewA.accessibilityHelp()?.contains("D") == true)
    }

    @Test func barCallbackAndKeyboardShortcutsUpdateControllerAndSyncAllDisplays() throws {
        let controller = try makeController()
        defer { controller.cancel() }

        var changes: [Int] = []
        var delayDuringCompletion: Int?
        controller.onSelfTimerDelayChange = { changes.append($0) }
        controller.begin(mode: .area, purpose: .screenshot, options: .init(recapturesLive: true, selfTimerDelay: 5)) { _ in
            delayDuringCompletion = controller.currentSelfTimerDelay
        }

        let viewA = try #require(controller.overlayView(for: Self.displayA.id))
        let viewB = try #require(controller.overlayView(for: Self.displayB.id))

        // Clicking a chip on the delay bar fires onSelfTimerDelayChange and syncs both displays.
        viewA.debugSelfTimerBar.visibleChips[3].performClick(nil) // 10s
        #expect(controller.currentSelfTimerDelay == 10)
        #expect(viewA.debugSelfTimerDelay == 10 && viewB.debugSelfTimerDelay == 10)
        #expect(changes == [10])

        // Pressing "d" cycles from 10s -> 15s -> 2s, including from the secondary display.
        viewB.keyDown(with: try keyEvent("d", keyCode: 2))
        #expect(controller.currentSelfTimerDelay == 15)
        #expect(viewA.debugSelfTimerDelay == 15 && viewB.debugSelfTimerDelay == 15)

        viewA.keyDown(with: try keyEvent("d", keyCode: 2))
        #expect(controller.currentSelfTimerDelay == 2)
        #expect(viewA.debugSelfTimerDelay == 2 && viewB.debugSelfTimerDelay == 2)

        // Pressing "1"–"5" selects the corresponding preset directly; modified keys are ignored.
        viewA.keyDown(with: try keyEvent("2", keyCode: 19, modifiers: .command))
        #expect(controller.currentSelfTimerDelay == 2)

        viewA.keyDown(with: try keyEvent("2", keyCode: 19))
        #expect(controller.currentSelfTimerDelay == 3)
        viewA.keyDown(with: try keyEvent("5", keyCode: 23))
        #expect(controller.currentSelfTimerDelay == 15)
        viewA.keyDown(with: try keyEvent("1", keyCode: 18))
        #expect(controller.currentSelfTimerDelay == 2)
        #expect(changes == [10, 15, 2, 3, 15, 2])

        // Ending the session keeps currentSelfTimerDelay readable inside completion and clears it afterward.
        controller.simulateSelection(CGRect(x: 100_100, y: 100, width: 240, height: 180))
        #expect(delayDuringCompletion == 2)
        #expect(controller.currentSelfTimerDelay == nil)
    }

    @Test func wantsSystemCursorIsTrueOverVisibleDelayBarAndFalseDuringDrag() throws {
        let controller = try makeController()
        defer { controller.cancel() }

        controller.begin(mode: .area, purpose: .screenshot, options: .init(recapturesLive: true, selfTimerDelay: 5)) { _ in }
        let viewA = try #require(controller.overlayView(for: Self.displayA.id))
        viewA.layoutSubtreeIfNeeded()

        let barFrame = try #require(viewA.debugSelfTimerBarFrame)
        let onBar = CGPoint(
            x: Self.displayA.frame.minX + barFrame.midX,
            y: Self.displayA.frame.minY + barFrame.midY
        )
        viewA.movePointer(to: onBar)
        #expect(viewA.wantsSystemCursor(at: onBar))
        #expect(!viewA.debugPointerLayers.crosshair)

        // While dragging a selection, the delay bar fades out and releases the system cursor.
        // The fork hides the drawn picker and crosshair after the first area press.
        var selection = SelectionModel(bounds: Self.displayA.frame, pixelsPerPoint: Self.displayA.pixelsPerPoint)
        selection.begin(at: CGPoint(x: Self.displayA.frame.minX + 100, y: Self.displayA.frame.minY + 400))
        selection.drag(to: onBar, modifiers: [], snapping: nil)
        viewA.show(selection: selection, showsReading: true, isDragging: true)
        viewA.movePointer(to: onBar)
        #expect(viewA.debugSelfTimerBarFrame == nil)
        #expect(!viewA.wantsSystemCursor(at: onBar))
        #expect(!viewA.debugPointerLayers.crosshair)
    }

    @Test func draggingToolbarToTheTopKeepsTimerControlsOnScreen() throws {
        let controller = try makeController()
        defer { controller.cancel() }
        controller.begin(mode: .area, purpose: .screenshot, options: .init(recapturesLive: true, selfTimerDelay: 5)) { _ in }
        let view = try #require(controller.overlayView(for: Self.displayA.id))
        view.layoutSubtreeIfNeeded()
        view.debugMoveToolbar(by: CGVector(dx: 0, dy: 10000))
        let timer = try #require(view.debugSelfTimerBarFrame)
        #expect(view.bounds.insetBy(dx: 8, dy: 8).contains(timer))
        #expect(!timer.intersects(view.debugToolbarFrame))
    }

    @Test func customInitialDelayAppearsInOverlayBarAndWindowHintClearsIt() throws {
        let controller = try makeController()
        defer { controller.cancel() }

        controller.begin(mode: .area, purpose: .screenshot, options: .init(recapturesLive: true, selfTimerDelay: 7)) { _ in }
        let viewA = try #require(controller.overlayView(for: Self.displayA.id))
        viewA.layoutSubtreeIfNeeded()

        #expect(controller.currentSelfTimerDelay == 7)
        #expect(viewA.debugSelfTimerBar.availableDelays == [2, 3, 5, 7, 10, 15])

        // Switching to window mode keeps the hint pill clear of both the toolbar and the self-timer bar.
        viewA.switchMode(to: .window, windows: [])
        viewA.movePointer(to: CGPoint(x: Self.displayA.frame.minX + 300, y: Self.displayA.frame.minY + 400))
        let barFrame = try #require(viewA.debugSelfTimerBarFrame)
        let hintFrame = try #require(viewA.debugHintFrame)
        #expect(!hintFrame.intersects(barFrame))
        #expect(!hintFrame.intersects(viewA.debugToolbarFrame))
    }
}
#endif
