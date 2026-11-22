import AppKit
import CoreGraphics
import OMSCore
import Testing
@testable import OMSCapture

@MainActor
struct OverlayTransientCaptureTests {
    @Test func transientPrecaptureIsLimitedToLiveAreaScreenshotsWithWindowsToPreserve() {
        #expect(OverlayController.shouldCaptureLiveTransientContent(
            mode: .area, purpose: .screenshot, holdsStill: false, allInOne: false, windowCount: 1
        ))
        #expect(!OverlayController.shouldCaptureLiveTransientContent(
            mode: .area, purpose: .screenshot, holdsStill: true, allInOne: false, windowCount: 1
        ))
        #expect(!OverlayController.shouldCaptureLiveTransientContent(
            mode: .area, purpose: .screenshot, holdsStill: false, allInOne: false, windowCount: 0
        ))
        #expect(!OverlayController.shouldCaptureLiveTransientContent(
            mode: .window, purpose: .screenshot, holdsStill: false, allInOne: false, windowCount: 1
        ))
        #expect(!OverlayController.shouldCaptureLiveTransientContent(
            mode: .area, purpose: .text, holdsStill: false, allInOne: false, windowCount: 1
        ))
        #expect(!OverlayController.shouldCaptureLiveTransientContent(
            mode: .area, purpose: .screenshot, holdsStill: false, allInOne: true, windowCount: 1
        ))
    }

    @Test func frontmostPanelStillVisibleAfterFirstTurnGetsABoundedSecondCheck() {
        let panel = TransientWindow(
            id: 50, ownerPID: 7, frame: CGRect(x: 10, y: 20, width: 30, height: 40), keepsWhenPresent: false
        )
        let visible = [OnScreenWindowOwner(id: 50, ownerPID: 7)]
        #expect(OverlayController.shouldObserveTransientDisappearance([panel], onScreenOwners: visible))
        #expect(!OverlayController.shouldObserveTransientDisappearance([panel], onScreenOwners: []))
        #expect(WindowCatalog.transientWindowsToRestore([panel], onScreenOwners: []).map(\.id) == [50])
    }

    @Test func watchdogDoesNotDismissAfterTheFirstTransientFrameArrives() {
        #expect(OverlayController.watchdogShouldDismiss(firstFrameArrived: false, windowPickerIsOpen: false))
        #expect(!OverlayController.watchdogShouldDismiss(firstFrameArrived: true, windowPickerIsOpen: false))
        #expect(!OverlayController.watchdogShouldDismiss(firstFrameArrived: false, windowPickerIsOpen: true))
    }

    #if DEBUG
    @Test func injectedTransientFrameSkipsScreenCaptureAndCaptureErrorsStillPropagate() async throws {
        let display = CGRect(x: 0, y: 0, width: 8, height: 8)
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        let injected = CapturedFrame(image: try #require(context.makeImage()), hdrImage: nil, displayID: 9, frame: display)
        var captureCalled = false
        let selected = try await OverlayController.captureFrame(injected: injected) {
            captureCalled = true
            return injected
        }
        #expect(!captureCalled)
        #expect(selected.displayID == injected.displayID)

        enum ExpectedFailure: Error { case capture }
        do {
            _ = try await OverlayController.captureFrame(injected: nil) {
                captureCalled = true
                throw ExpectedFailure.capture
            }
            #expect(Bool(false))
        } catch is ExpectedFailure {
            #expect(captureCalled)
        }
    }
    #endif

    @Test func ownWindowExceptionIsLimitedToAreaScreenshots() {
        let requested: CGWindowID = 42
        #expect(OverlayController.scopedOwnWindowID(mode: .area, purpose: .screenshot, requested: requested) == requested)
        #expect(OverlayController.scopedOwnWindowID(mode: .window, purpose: .screenshot, requested: requested) == nil)
        #expect(OverlayController.scopedOwnWindowID(mode: .area, purpose: .record, requested: requested) == nil)
        #expect(OverlayController.scopedOwnWindowID(mode: .area, purpose: .text, requested: requested) == nil)
    }

    @Test func pendingTransientComparisonAllowsOnlyEscapeInput() {
        #expect(OverlayPanel.dispatches(.keyDown, keyCode: 53, whileComparisonPending: true))
        #expect(!OverlayPanel.dispatches(.keyDown, keyCode: 0, whileComparisonPending: true))
        #expect(!OverlayPanel.dispatches(.leftMouseDown, keyCode: 0, whileComparisonPending: true))
        #expect(OverlayPanel.dispatches(.leftMouseDown, keyCode: 0, whileComparisonPending: false))
    }

    @Test func transientPrecaptureBuffersAndReleasesSyntheticMouseEventsInOrderAndResetsForReuse() throws {
        let panel = OverlayPanel(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        panel.configureInput(acceptingInput: false, suppressingInputUntilComparison: true)
        #expect(!panel.ignoresMouseEvents)
        #expect(panel.suppressesInputUntilTransientComparison)
        func mouseEvent(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: CGPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        let events = [try mouseEvent(.leftMouseDown), try mouseEvent(.leftMouseDragged), try mouseEvent(.leftMouseUp)]
        for event in events { panel.sendEvent(event) }

        #if DEBUG
        #expect(panel.debugDeferredMouseEventCount == events.count)
        #endif
        var queued: [NSEvent] = []
        panel.configureInput(acceptingInput: true, suppressingInputUntilComparison: false) { event, atStart in
            #expect(atStart)
            queued.insert(event, at: 0)
        }

        #expect(!panel.suppressesInputUntilTransientComparison)
        #expect(!panel.ignoresMouseEvents)
        #expect(queued.map(\.type) == events.map(\.type))
        #if DEBUG
        #expect(panel.debugDeferredMouseEventCount == 0)
        #endif

        panel.configureInput(acceptingInput: false, suppressingInputUntilComparison: true)
        panel.sendEvent(events[0])
        #if DEBUG
        #expect(panel.debugDeferredMouseEventCount == 1)
        #endif
        panel.configureInput(acceptingInput: false, suppressingInputUntilComparison: false)
        #expect(!panel.suppressesInputUntilTransientComparison)
        #expect(panel.ignoresMouseEvents)
        #if DEBUG
        #expect(panel.debugDeferredMouseEventCount == 0)
        #endif

        panel.configureInput(acceptingInput: false, suppressingInputUntilComparison: true)
        #expect(panel.suppressesInputUntilTransientComparison)
        panel.configureInput(acceptingInput: false, suppressingInputUntilComparison: false)
        #expect(!panel.suppressesInputUntilTransientComparison)
    }

    @Test func liveTransientPreviewIsBelowDimmingAndSelectionAndClearedOnResetAndCancel() throws {
        let display = DisplayInfo(
            id: 1, name: "Synthetic", frame: CGRect(x: -100, y: 0, width: 100, height: 100),
            pixelSize: CGSize(width: 200, height: 200), backingScale: 2, maximumPotentialEDR: 1
        )
        let context = try #require(CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let frame = CapturedFrame(image: try #require(context.makeImage()), hdrImage: nil, displayID: display.id, frame: display.frame)
        let snapshot = TransientCaptureSnapshot(frame: frame, regions: [CGRect(x: -80, y: 20, width: 30, height: 40)])
        let view = OverlayView(display: display)
        defer { view.clear() }

        view.reset(pointer: .zero, mode: .area, windows: [], showsToolbar: false)
        view.showTransientContent(from: [])
        #expect(view.debugTransientPatchCount == 0)
        view.showTransientContent(from: [TransientCaptureSnapshot(frame: frame, regions: [CGRect(x: 20, y: 20, width: 10, height: 10)])])
        #expect(view.debugTransientPatchCount == 0)
        view.showTransientContent(from: [snapshot])
        #expect(view.debugTransientPatchCount == 1)
        #expect(!view.debugTransientContentIsHidden)
        #expect(view.debugTransientPatchFrames == [CGRect(x: 20, y: 20, width: 30, height: 40)])
        #expect(view.debugTransientContentIsBelowDimmingAndSelection)

        view.switchMode(to: .window, windows: [])
        #expect(view.debugTransientPatchCount == 1)
        #expect(view.debugTransientContentIsHidden)
        view.switchMode(to: .area, windows: [])
        #expect(view.debugTransientPatchCount == 1)
        #expect(!view.debugTransientContentIsHidden)

        view.reset(pointer: .zero, mode: .area, windows: [], showsToolbar: false)
        #expect(view.debugTransientPatchCount == 0)
        view.showTransientContent(from: [snapshot])
        view.clear()
        #expect(view.debugTransientPatchCount == 0)
    }
}
