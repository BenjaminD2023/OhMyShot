import AppKit
import OMSCore
import Testing
@testable import OMSCapture

struct ColorCopyGestureTests {
    @Test func modifiersMatchExactlyAndIgnoreDeviceFlags() {
        let cases: [(ColorCopyGesture, NSEvent.ModifierFlags)] = [
            (.option, .option), (.control, .control), (.command, .command),
            (.shiftOption, [.shift, .option]), (.commandOption, [.command, .option]),
        ]
        let modifiers: [NSEvent.ModifierFlags] = [.command, .control, .option, .shift]
        for (gesture, expected) in cases {
            for bits in 0..<16 {
                var flags: NSEvent.ModifierFlags = []
                for (index, modifier) in modifiers.enumerated() where bits & (1 << index) != 0 { flags.insert(modifier) }
                #expect(gesture.matches(flags) == (flags == expected), "\(gesture): \(bits)")
                #expect(gesture.matches(flags.union([.capsLock, .numericPad, .function])) == (flags == expected))
                #expect(!ColorCopyGesture.disabled.matches(flags))
            }
        }
    }
}
