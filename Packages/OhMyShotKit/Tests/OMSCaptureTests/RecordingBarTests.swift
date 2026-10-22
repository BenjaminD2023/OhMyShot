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
}
