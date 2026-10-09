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

    @Test func aPicturesTextTakesPressesOnlyWhereThereIsText() async throws {
        // A line of text near the top that starts at the left edge, and nothing below it.
        let image = try #require(Self.picture(size: CGSize(width: 600, height: 200)) {
            ("Capture Area and Pin keeps the capture in the history." as NSString).draw(
                at: CGPoint(x: 1, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black]
            )
        })
        // At its own size in points, whatever the screen's scale it was drawn at.
        let content = PinController.Content.image(image, scale: CGFloat(image.width) / 600)
        let view = PinView(content: content, appearance: PinAppearance(cornerRadius: 12, shadow: true, border: true), textReader: PinTextReader())
        // In a window, as a pin is, though never shown: out of one, VisionKit's hit queries go astray.
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: PinWindow.baseSize(of: content)), styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = view
        view.layout()
        #expect(await view.debugReadText(selectAll: false) > 0)
        // The line spans about 22 to 54 pt from the top, so 162 pt from the bottom is on it.
        let onText = CGPoint(x: 160, y: 162)
        #expect(view.debugHasText(at: onText))
        #expect(view.hitTest(onText) !== view)
        // Below the line the pin takes the press and drags.
        let below = CGPoint(x: 300, y: 60)
        #expect(!view.debugHasText(at: below))
        #expect(view.hitTest(below) === view)
        // So it does on the text within 6 pt of the edge.
        let edge = CGPoint(x: 4, y: 162)
        #expect(view.debugHasText(at: edge))
        #expect(view.hitTest(edge) === view)
    }

    /// A white picture at 1 pixel per point with `draw` run in it, from its top left.
    private static func picture(size: CGSize, draw: @escaping () -> Void) -> CGImage? {
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            draw()
            return true
        }
        var rect = CGRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
