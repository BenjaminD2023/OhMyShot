import AppKit
import Testing
@testable import OMSUI

@MainActor
struct PinViewTests {
    @Test func cornerButtonsTakeClicksOnlyWhileTheyShow() throws {
        // A one-line text card, where Close and More stand over the ends of the line.
        let content = PinController.Content.text("npm run dev")
        let view = PinView(content: content, appearance: PinAppearance(cornerRadius: 12, shadow: true, border: true))
        view.frame = CGRect(origin: .zero, size: PinWindow.baseSize(of: content))
        view.layout()
        let buttons = PinGeometry.cornerButtons(in: view.bounds.size, button: 24)
        let close = try #require(buttons.close)
        let more = try #require(buttons.more)
        // Faded out, they let the pin take the click, so it drags from there.
        for place in [close, more] {
            #expect(view.hitTest(CGPoint(x: place.midX, y: place.midY)) === view)
        }
        let entered = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        view.mouseEntered(with: entered)
        for place in [close, more] {
            #expect(view.hitTest(CGPoint(x: place.midX, y: place.midY)) is CardButton)
        }
    }
}
