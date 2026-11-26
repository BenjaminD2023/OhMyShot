import AppKit
import AVFoundation
import OMSCore
import Testing
@testable import OMSCapture

/// The recording bar's microphone and camera chips, which open menus: they name what they record.
@MainActor
struct RecordingBarTests {
    /// The chip VoiceOver calls `name`.
    private func chip(_ name: String, in bar: RecordingBar) -> NSButton? {
        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
        }
        return buttons(in: bar).first { $0.accessibilityLabel() == name }
    }

    /// The test runner may have been refused the microphone or camera, which steps their chips back instead.
    nonisolated private static var mayAsk: Bool {
        [AVMediaType.audio, .video].allSatisfy { [.authorized, .notDetermined].contains(AVCaptureDevice.authorizationStatus(for: $0)) }
    }

    @Test(.enabled(if: mayAsk)) func aChipThatIsOnNamesItsDevice() throws {
        var asked: [(RecordingBar.Toggle, String)] = []
        let bar = RecordingBar(choices: RecordingChoices(microphone: true, microphoneID: "usb-1", camera: true)) { toggle, id in
            asked.append((toggle, id))
            return toggle == .microphone ? "Studio Mic" : "FaceTime HD Camera"
        }
        let microphone = try #require(chip("Microphone", in: bar))
        let camera = try #require(chip("Camera", in: bar))
        #expect(microphone.toolTip == "Microphone: Studio Mic")
        #expect(microphone.accessibilityValue() as? String == "Studio Mic")
        #expect(camera.toolTip == "Camera: FaceTime HD Camera")
        #expect(camera.accessibilityValue() as? String == "FaceTime HD Camera")
        // Each device is asked for once, however often the bar updates.
        bar.update(RecordingChoices(microphone: true, microphoneID: "usb-1", camera: true))
        #expect(asked.count == 2)
        #expect(asked.contains { $0.0 == .microphone && $0.1 == "usb-1" })
    }

    @Test func aChipThatIsOffSaysSoAndAsksNothing() throws {
        var asked = 0
        let bar = RecordingBar(choices: RecordingChoices()) { _, _ in
            asked += 1
            return "Studio Mic"
        }
        let microphone = try #require(chip("Microphone", in: bar))
        let camera = try #require(chip("Camera", in: bar))
        #expect(microphone.toolTip == "Choose a microphone to record")
        #expect(microphone.accessibilityValue() as? String == "No Microphone")
        #expect(camera.accessibilityValue() as? String == "No Camera")
        #expect(chip("Show Clicks", in: bar)?.accessibilityValue() as? String == "Off")
        #expect(asked == 0)
    }

    /// Without a name (no access yet), the chip says what it does, and VoiceOver hears that it is on.
    @Test(.enabled(if: mayAsk)) func aChipWithoutANameSaysWhatItDoes() throws {
        let bar = RecordingBar(choices: RecordingChoices(microphone: true)) { _, _ in nil }
        let microphone = try #require(chip("Microphone", in: bar))
        #expect(microphone.toolTip == "Choose a microphone to record")
        #expect(microphone.accessibilityValue() as? String == "On")
    }

    /// `U-23` + Studio single-window camera: Updating `recordsWindow` from `true` to `false` re-enables Camera
    /// and Show Keystrokes for Video, while Studio allows both even for single-window recordings.
    @Test func updatingRecordsWindowFromTrueToFalseEnablesCameraAndKeystrokes() throws {
        let bar = RecordingBar(choices: RecordingChoices(output: .video), recordsWindow: true)
        let camera = try #require(chip("Camera", in: bar))
        let keystrokes = try #require(chip("Show Keystrokes", in: bar))
        #expect(bar.recordsWindow)
        #expect(!camera.isEnabled && !keystrokes.isEnabled)

        // Single-window Studio composites camera and keystrokes itself, so both chips stay enabled.
        bar.update(RecordingChoices(output: .studio), recordsWindow: true)
        #expect(bar.recordsWindow)
        #expect(camera.isEnabled && keystrokes.isEnabled)

        bar.update(RecordingChoices(output: .video), recordsWindow: false)
        #expect(!bar.recordsWindow)
        #expect(camera.isEnabled && keystrokes.isEnabled)
    }

    /// `U-21`: In Studio output mode, Show Clicks and Show Keystrokes tooltips explain they are recorded for
    /// Studio and remain editable after recording.
    @Test func studioTooltipsExplainClicksAndKeystrokesAreEditableAfterRecording() throws {
        let bar = RecordingBar(choices: RecordingChoices(output: .studio), recordsWindow: false)
        let clicks = try #require(chip("Show Clicks", in: bar))
        #expect(clicks.toolTip?.contains("Studio") == true)
        #expect(clicks.toolTip?.contains("after recording") == true)
        if CGPreflightListenEventAccess() {
            let keystrokes = try #require(chip("Show Keystrokes", in: bar))
            #expect(keystrokes.toolTip?.contains("Studio") == true)
            #expect(keystrokes.toolTip?.contains("after recording") == true)
        }
    }

    /// Deterministic fake monitor for `F-18` microphone level lifecycle tests (zero hardware access).
    private final class MockLevelMonitor: MicrophoneLevelMonitoring {
        var startedDeviceIDs: [String] = []
        var stopCount = 0
        var emit: ((CGFloat) -> Void)?

        func start(deviceID: String, onLevel: @escaping (CGFloat) -> Void) {
            startedDeviceIDs.append(deviceID)
            emit = onLevel
        }

        func stop() {
            stopCount += 1
            emit = nil
        }
    }

    /// `F-18`: Picking a microphone while access is `.notDetermined` requests permission immediately and only
    /// enables the microphone when granted; turning it off never prompts.
    @Test func choosingMicrophoneRequestsPermissionImmediatelyWhenNotDetermined() async throws {
        let bar = RecordingBar(choices: RecordingChoices())
        var status: AVAuthorizationStatus = .notDetermined
        var requestCount = 0
        var grantResult = true
        var selected: [String?] = []

        bar.microphoneAuthorizationStatus = { status }
        bar.requestMicrophoneAccess = {
            requestCount += 1
            if grantResult { status = .authorized }
            return grantResult
        }
        bar.onMicrophone = { selected.append($0) }

        // Turning microphone off does not prompt.
        bar.chooseMicrophone(nil)
        #expect(requestCount == 0 && selected == [nil])

        // Picking a mic when denied does not enable it.
        grantResult = false
        bar.chooseMicrophone("usb-1")
        for _ in 0..<40 where requestCount == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(10))
        #expect(requestCount == 1 && selected == [nil])

        // Picking a mic when granted calls onMicrophone with the chosen ID.
        grantResult = true
        bar.chooseMicrophone("usb-1")
        for _ in 0..<40 where selected.count < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(requestCount == 2 && selected == [nil, "usb-1"])
    }

    /// `F-18`: Live input-level monitoring runs only while the setup bar is attached, visible, microphone is
    /// enabled with audio output, and audio permission is granted — with clean teardown on hide/GIF/detach/stop.
    @Test func microphoneLevelMonitorLifecycleTracksWindowVisibilityOutputAndPermission() throws {
        var status: AVAuthorizationStatus = .notDetermined
        var monitors: [MockLevelMonitor] = []

        let bar = RecordingBar(choices: RecordingChoices(microphone: true, microphoneID: "usb-1"))
        bar.microphoneAuthorizationStatus = { status }
        bar.makeLevelMonitor = {
            let monitor = MockLevelMonitor()
            monitors.append(monitor)
            return monitor
        }

        // Detached or ungranted: zero monitors created.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 100))
        window.contentView = host
        host.addSubview(bar)
        #expect(monitors.isEmpty && !bar.isMonitoringMicrophoneLevel)

        // Authorized with mic on: monitor starts and feeds input level.
        status = .authorized
        bar.update(RecordingChoices(microphone: true, microphoneID: "usb-1"))
        #expect(monitors.count == 1 && bar.isMonitoringMicrophoneLevel)
        #expect(monitors[0].startedDeviceIDs == ["usb-1"])
        monitors[0].emit?(0.65)
        #expect(bar.microphoneInputLevel == 0.65)

        // Switching to a different microphone tears down the first monitor and starts a new one.
        bar.update(RecordingChoices(microphone: true, microphoneID: "usb-2"))
        #expect(monitors[0].stopCount == 1)
        #expect(monitors.count == 2 && monitors[1].startedDeviceIDs == ["usb-2"])

        // Switching to GIF (no audio) stops monitoring and clears level.
        bar.update(RecordingChoices(output: .gif, microphone: true, microphoneID: "usb-2"))
        #expect(monitors[1].stopCount == 1 && !bar.isMonitoringMicrophoneLevel && bar.microphoneInputLevel == 0)

        // Switching back to Video restarts monitoring; hiding the bar tears it down.
        bar.update(RecordingChoices(output: .video, microphone: true, microphoneID: "usb-2"))
        #expect(monitors.count == 3 && bar.isMonitoringMicrophoneLevel)
        bar.isHidden = true
        #expect(monitors[2].stopCount == 1 && !bar.isMonitoringMicrophoneLevel)
        bar.isHidden = false
        #expect(monitors.count == 4 && bar.isMonitoringMicrophoneLevel)

        // Explicit stopLevelMonitoring prevents further restarts before recording starts.
        bar.stopLevelMonitoring()
        #expect(monitors[3].stopCount == 1 && !bar.isMonitoringMicrophoneLevel)
        bar.update(RecordingChoices(output: .video, microphone: true, microphoneID: "usb-2"))
        #expect(monitors.count == 4 && !bar.isMonitoringMicrophoneLevel)

        bar.removeFromSuperview()
    }
}
