import AppKit
import OMSCore
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

extension PinViewTests {
    private static let appearance = PinAppearance(cornerRadius: 12, shadow: true, border: true)

    /// A text card at `zoom` in its pin window, which is never shown.
    private func card(_ text: String, zoom: CGFloat = 1) throws -> (view: PinView, text: PinTextView) {
        let content = PinController.Content.text(text)
        let size = PinWindow.baseSize(of: content)
        let actions = PinController.Actions(copy: { _ in }, save: { _ in }, saveAs: { _ in }, annotate: { _ in }, recognizeText: { _ in })
        let window = PinWindow(
            pin: PinController.Pin(id: UUID(), content: content, origin: .clipboard),
            frame: CGRect(x: 0, y: 0, width: size.width * zoom, height: size.height * zoom), zoom: zoom, appearance: Self.appearance, actions: actions
        )
        let view = try #require(window.contentView as? PinView)
        view.layout()
        return (view, try #require(view.textView))
    }

    @Test func aPictureGoesOnlyAsTheAppHandsItOver() throws {
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let content = PinController.Content.image(try #require(context.makeImage()), scale: 1)
        let pin = PinController.Pin(id: UUID(), content: content, origin: .capture(UUID()))
        var actions = PinController.Actions(copy: { _ in }, save: { _ in }, saveAs: { _ in }, annotate: { _ in }, recognizeText: { _ in })
        let frame = CGRect(origin: .zero, size: PinWindow.baseSize(of: content))
        // The app could not make the copy Settings ask for: the pin's own picture does not go in its place.
        actions.fileForDrag = { _ in nil }
        #expect(PinWindow(pin: pin, frame: frame, zoom: 1, appearance: Self.appearance, actions: actions).fileForDrag() == nil)
        // Left to itself, a pin hands over its own picture.
        actions.fileForDrag = nil
        let own = try #require(PinWindow(pin: pin, frame: frame, zoom: 1, appearance: Self.appearance, actions: actions).fileForDrag())
        defer { try? FileManager.default.removeItem(at: own) }
        #expect(FileManager.default.fileExists(atPath: own.path(percentEncoded: false)))
    }

    /// A picture resized in the editor to fewer pixels than points pins at the size the editor shows it; a scale that is
    /// none at all pins at one point a pixel.
    @Test func aPictureKeepsAScaleBelowOne() throws {
        let suite = "PinViewTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let actions = PinController.Actions(copy: { _ in }, save: { _ in }, saveAs: { _ in }, annotate: { _ in }, recognizeText: { _ in })
        let pins = PinController(settings: SettingsStore(defaults: defaults), actions: actions)
        defer { pins.closeAll() }
        let image = try #require(Self.picture(size: CGSize(width: 200, height: 100)) {})

        let resized = pins.pin(image, scale: 0.5, origin: .clipboard)
        let unknown = pins.pin(image, scale: 0, origin: .clipboard)

        // The picture has as many pixels as the screen it was drawn for gives it.
        let pixels = CGSize(width: image.width, height: image.height)
        let pinned = NSApplication.shared.windows.compactMap { $0 as? PinWindow }
        let size = { (id: UUID) in pinned.first { $0.pin.id == id }.map { PinWindow.baseSize(of: $0.pin.content) } }
        #expect(size(resized) == CGSize(width: pixels.width * 2, height: pixels.height * 2))
        #expect(size(unknown) == pixels)
    }

    @Test func aCardsTextBreaksWhereItsSizeWasMeasured() throws {
        for text in [
            "npm run dev",
            "Quick Access keeps every capture one click away. The text in a capture can be copied, edited, and searched, and a long line wraps where the card is widest.",
            "截图完成后，卡片会出现在屏幕左下角，可以直接拖到其他应用里。按住 Option 再松开鼠标，就能在面板里查看和编辑识别出的文字。",
            "func main() {\n    let pins = PinController()\n    pins.pinClipboard()\n}",
        ] {
            let (_, textView) = try card(text)
            let layout = try #require(textView.layoutManager), container = try #require(textView.textContainer)
            let used = layout.usedRect(for: container)
            let measured = PinText.textSize(for: text)
            #expect(ceil(used.height) == measured.height, "\(text.prefix(12)): \(used) vs \(measured)")
            #expect(used.width <= measured.width + 0.5, "\(text.prefix(12)): \(used) vs \(measured)")
        }
    }

    @Test func aLongCardStopsAtThirtyLinesWithAnEllipsis() throws {
        let text = (1...45).map { "Line \($0) of the log" }.joined(separator: "\n")
        let (_, textView) = try card(text)
        let layout = try #require(textView.layoutManager), container = try #require(textView.textContainer)
        var lines = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
        #expect(lines == PinText.maxLines)
        // The last line shown ends in an ellipsis in place of what follows.
        let last = layout.characterRange(forGlyphRange: layout.glyphRange(for: container), actualGlyphRange: nil)
        #expect(last.length < (textView.string as NSString).length)
        #expect(ceil(layout.usedRect(for: container).height) == PinText.textSize(for: text).height)
    }

    @Test func aCardsTextTakesPressesOnlyOnItsLines() throws {
        let (view, textView) = try card("Quick Access keeps every capture one click away.")
        // The pin's coordinates are y-up: the line is in the middle of the card's height.
        let middle = view.bounds.midY
        #expect(view.hitTest(CGPoint(x: PinText.padding.width + 30, y: middle)) === textView)
        // In the padding beside the text, and within 6 pt of the edge, the pin takes the press and drags.
        #expect(view.hitTest(CGPoint(x: PinText.padding.width / 2 + 2, y: middle)) === view)
        #expect(view.hitTest(CGPoint(x: 3, y: middle)) === view)
        // Past the end of a short line, too.
        let (short, _) = try card("npm run dev\nand a second, longer line that sets the card's width")
        #expect(short.hitTest(CGPoint(x: short.bounds.maxX - PinText.padding.width - 20, y: short.bounds.maxY - PinText.padding.height - 6)) === short)
    }

    @Test func atAZoomItsTextStillTakesPressesWhereItIs() throws {
        let (view, textView) = try card("Quick Access keeps every capture one click away.", zoom: 2)
        #expect(textView.bounds.width == textView.frame.width / 2)
        #expect(view.hitTest(CGPoint(x: (PinText.padding.width + 30) * 2, y: view.bounds.midY)) === textView)
    }

    @Test func copyingASelectionTakesItOrAllOfTheText() {
        let full = "first line\nsecond line\n\n"
        let shown = "first line\nsecond line"
        #expect(PinText.copied(selecting: NSRange(location: 6, length: 4), in: shown, of: full) == "line")
        // All that the card holds selected: the whole text, the part past the card's cut too.
        #expect(PinText.copied(selecting: NSRange(location: 0, length: (shown as NSString).length), in: shown, of: full) == full)
        #expect(PinText.copied(selecting: NSRange(location: 3, length: 0), in: shown, of: full) == nil)
    }

    @Test func theMenuCopiesTheSelectionOrAllOfTheText() throws {
        let (view, textView) = try card("Quick Access keeps every capture one click away.")
        #expect(view.makeMenu().items.prefix(2).map(\.title) == ["Copy Text", "Select All Text"])
        textView.setSelectedRange(NSRange(location: 6, length: 6))
        #expect(view.makeMenu().items.prefix(3).map(\.title) == ["Copy", "Copy All Text", "Select All Text"])
        #expect(textView.selectionToCopy == "Access")
        // Over the text, after the text's own menu: the whole text, without ⌘C, which copies the selection.
        let after = try #require(view.makeMenu(afterLiveText: true).items.first)
        #expect(after.title == "Copy All Text" && after.keyEquivalent.isEmpty)
        // A right-click on the text gets the text's own menu with the pin's after it.
        let window = try #require(view.window)
        let onText = view.convert(CGPoint(x: PinText.padding.width + 30, y: view.bounds.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: onText, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let titles = try #require(textView.menu(for: click)).items.map(\.title)
        #expect(titles.contains("Copy All Text") && titles.last == "Close All Pins", "\(titles)")
    }

    @Test func lockedPinProvidesClickableUnlockBadgeAndCornerDragResizesWindow() throws {
        let (view, _) = try card("Quick Access keeps every capture one click away.")
        let pin = try #require(view.pinWindow)
        let originalFrame = pin.frame

        // Dragging bottomRight corner scales the pin proportionally around topLeft.
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: originalFrame.width - 3, y: 3), modifierFlags: [], timestamp: 0,
            windowNumber: pin.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let dragged = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: originalFrame.width * 1.5, y: -originalFrame.height * 0.5), modifierFlags: [], timestamp: 0,
            windowNumber: pin.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: CGPoint(x: originalFrame.width * 1.5, y: -originalFrame.height * 0.5), modifierFlags: [], timestamp: 0,
            windowNumber: pin.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        view.mouseDown(with: down)
        view.mouseDragged(with: dragged)
        view.mouseUp(with: up)
        #expect(abs(pin.zoom - 1.5) < 0.01)

        // Locking sets ignoresMouseEvents on main window, creates lockBadgePanel, and clicking badge unlocks this pin alone.
        pin.setLocked(true)
        #expect(pin.isLocked && pin.ignoresMouseEvents)
        let badgePanel = try #require(pin.lockBadgePanel)
        #expect(!badgePanel.ignoresMouseEvents)
        view.lockMark.sendAction(view.lockMark.action, to: view.lockMark.target)
        #expect(!pin.isLocked && !pin.ignoresMouseEvents && pin.lockBadgePanel == nil)

        // Double-clicking on non-text area toggles between 100% and previous zoom (1.5x).
        let doubleClick = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 4, y: 20), modifierFlags: [], timestamp: 0,
            windowNumber: pin.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1
        ))
        view.mouseDown(with: doubleClick)
        #expect(abs(pin.zoom - 1.0) < 0.01)
        view.mouseDown(with: doubleClick)
        #expect(abs(pin.zoom - 1.5) < 0.01)
    }

    @Test func zoomingOutAPinFittedBelowTheSmallestZoomLeavesItAsItIs() throws {
        let (view, _) = try card("npm run dev", zoom: 0.05)
        let pin = try #require(view.pinWindow)
        let frame = pin.frame
        pin.setZoom(pin.zoom / 1.25)
        #expect(pin.zoom == 0.05 && pin.frame == frame)
        pin.setZoom(0.08)
        #expect(pin.zoom == 0.08)
    }

    @Test func aClickBringsThePinInFrontOfTheOthers() throws {
        let (view, _) = try card("npm run dev")
        let pin = try #require(view.pinWindow)
        var raised: [PinWindow] = []
        pin.onRaise = { raised.append($0) }
        // At its bottom right corner, where a press only begins a resize.
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: pin.frame.width - 3, y: 3), modifierFlags: [], timestamp: 0,
            windowNumber: pin.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        pin.sendEvent(down)
        #expect(raised.count == 1 && raised.first === pin)
    }
}
