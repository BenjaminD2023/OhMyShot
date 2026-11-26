import AppKit
import CoreGraphics
import Foundation
import ImageIO
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

    @Test func aLongCardCapsWindowHeightAtThirtyLinesAndScrollsAllLines() throws {
        let text = (1...45).map { "Line \($0) of the log" }.joined(separator: "\n")
        let (view, textView) = try card(text)
        let scrollView = try #require(view.textScrollView)
        let layout = try #require(textView.layoutManager), container = try #require(textView.textContainer)
        var lines = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
        // Initial card height stays capped at 30 lines, while all 45 lines lay out and scroll smoothly inside.
        #expect(lines == 45)
        #expect(view.bounds.height == PinText.cardSize(for: text).height)
        #expect(scrollView.canScrollVertically)
        #expect(textView.frame.height > scrollView.contentView.bounds.height)
    }

    @Test func textPinDetectsClickableHTTPLinksWhilePreservingCommandDrag() throws {
        let text = "Visit https://example.com/docs for help."
        let (view, textView) = try card(text)
        let layout = try #require(textView.layoutManager), container = try #require(textView.textContainer)
        let linkRange = (text as NSString).range(of: "https://example.com/docs")
        let glyphRange = layout.glyphRange(forCharacterRange: linkRange, actualCharacterRange: nil)
        let linkRect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
        let linkCenter = CGPoint(x: linkRect.midX, y: linkRect.midY)
        #expect(textView.linkURL(at: linkCenter)?.absoluteString == "https://example.com/docs")

        let plainRange = (text as NSString).range(of: "Visit")
        let plainGlyphs = layout.glyphRange(forCharacterRange: plainRange, actualCharacterRange: nil)
        let plainRect = layout.boundingRect(forGlyphRange: plainGlyphs, in: container)
        #expect(textView.linkURL(at: CGPoint(x: plainRect.midX, y: plainRect.midY)) == nil)

        // Holding Command over a link lets the pin take the drag instead of opening the link.
        let inPin = view.convert(linkCenter, from: textView)
        #expect(view.takesTextPress(at: inPin, modifiers: []))
        #expect(!view.takesTextPress(at: inPin, modifiers: .command))
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

        // Locking sets ignoresMouseEvents on main window, keeps PinView.lockMark hidden (sole badge is lockBadgePanel),
        // and clicking the badge panel button unlocks this pin alone.
        pin.setLocked(true)
        #expect(pin.isLocked && pin.ignoresMouseEvents)
        #expect(view.lockMark.isHidden)
        let badgePanel = try #require(pin.lockBadgePanel)
        #expect(!badgePanel.ignoresMouseEvents)
        let badgeButton = try #require(badgePanel.contentView as? CardButton)
        badgeButton.sendAction(badgeButton.action, to: badgeButton.target)
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

    @Test func optionAndCommandSuppressTextPressForDragging() throws {
        let (view, _) = try card("Quick Access keeps every capture one click away.")
        let onText = CGPoint(x: PinText.padding.width + 30, y: view.bounds.midY)
        #expect(view.takesTextPress(at: onText, modifiers: []))
        #expect(!view.takesTextPress(at: onText, modifiers: .option))
        #expect(!view.takesTextPress(at: onText, modifiers: .command))
    }

    @Test func pinMenuIncludesShortcutsAndHintsAndSupportsInAppDrag() throws {
        let image = try #require(Self.picture(size: CGSize(width: 200, height: 120)) {})
        let content = PinController.Content.image(image, scale: 2)
        let size = PinWindow.baseSize(of: content)
        let actions = PinController.Actions(copy: { _ in }, save: { _ in }, saveAs: { _ in }, annotate: { _ in }, recognizeText: { _ in })
        let window = PinWindow(
            pin: PinController.Pin(id: UUID(), content: content, origin: .clipboard),
            frame: CGRect(origin: .zero, size: size), zoom: 1, appearance: Self.appearance, actions: actions
        )
        defer { window.tearDown() }
        let view = try #require(window.contentView as? PinView)
        let menu = view.makeMenu()
        #expect(menu.items.last?.title == "Close All Pins")
        #expect(menu.items.first { $0.title == "Annotate…" }?.keyEquivalent == "e")
        #expect(menu.items.first { $0.title == "Recognize Text…" }?.keyEquivalent == "t")
        #expect(menu.items.first { $0.title == "Lock" }?.keyEquivalent == "l")
        #expect(menu.items.first { $0.title == "Close All Pins" }?.keyEquivalentModifierMask == [.command, .option])

        // Dragging a picture pin writes a Retina-DPI file under ExportedFiles and cleans it up on tearDown.
        let dragURL = try #require(window.fileForDrag())
        #expect(FileManager.default.fileExists(atPath: dragURL.path(percentEncoded: false)))
        let source = try #require(CGImageSourceCreateWithURL(dragURL as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue == 144)

        // Updating image refreshes baseSize and removes stale drag file.
        let wider = try #require(Self.picture(size: CGSize(width: 400, height: 120)) {})
        window.updateImage(wider, scale: 2)
        #expect(window.baseSize == CGSize(width: CGFloat(wider.width) / 2, height: CGFloat(wider.height) / 2))
        #expect(!FileManager.default.fileExists(atPath: dragURL.path(percentEncoded: false)))

        // Locking and tearing down removes lockBadgePanel cleanly.
        window.setLocked(true)
        #expect(window.lockBadgePanel != nil)
        window.tearDown()
        #expect(window.lockBadgePanel == nil)
    }

    @Test func pinGeometryClampsCascadeAndRescuesDisconnectedPins() {
        let visible = CGRect(x: 0, y: 0, width: 300, height: 200)
        let first = CGRect(x: 240, y: 10, width: 50, height: 50)
        let second = PinGeometry.cascaded(first, avoiding: [first], in: visible)
        #expect(visible.contains(second))

        // Pin on a disconnected display is relocated onto the fallback visible frame.
        let offscreen = CGRect(x: 2500, y: 400, width: 120, height: 80)
        let rescued = PinGeometry.rescuedFrame(for: offscreen, screens: [visible], fallback: visible)
        #expect(rescued != nil)
        if let rescued { #expect(visible.contains(rescued)) }
        // Pin already intersecting a connected screen stays put.
        #expect(PinGeometry.rescuedFrame(for: first, screens: [visible], fallback: visible) == nil)
    }

    @Test func pinControllerRestoresUpToFiveRecentlyClosedPinsLIFOWithState() throws {
        let suite = "OMSUITests-PinUndo-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let actions = PinController.Actions(copy: { _ in }, save: { _ in }, saveAs: { _ in }, annotate: { _ in }, recognizeText: { _ in })
        let controller = PinController(settings: SettingsStore(defaults: defaults), actions: actions)
        defer { controller.closeAll() }

        #expect(!controller.canRestoreClosedPin)
        #expect(!controller.restoreLastClosedPin())

        // Open and close 6 pins; only the 5 most recently closed are retained.
        for index in 1...6 {
            let id = controller.pin(text: "Pin \(index)")
            let window = try #require(controller.window(for: id))
            window.setOpacity(CGFloat(index) * 0.1 + 0.3)
            if index == 6 {
                window.toggleShadow()
                window.toggleBorder()
            }
            #expect(controller.close(id: id))
        }
        #expect(controller.isEmpty)
        #expect(controller.canRestoreClosedPin)

        // First restore returns pin 6 with its opacity and shadow/border overrides preserved.
        #expect(controller.restoreLastClosedPin())
        let restored6 = try #require(controller.newestWindow)
        if case .text(let value) = restored6.pin.content {
            #expect(value == "Pin 6")
        } else {
            Issue.record("Expected text pin")
        }
        #expect(abs(restored6.opacity - 0.9) < 0.01)
        #expect(restored6.shadowOverride != nil)
        #expect(restored6.borderOverride != nil)

        // Remaining 4 restores return pins 5, 4, 3, 2 in LIFO order; pin 1 was evicted past the cap of 5.
        for expected in [5, 4, 3, 2] {
            #expect(controller.restoreLastClosedPin())
            let restored = try #require(controller.newestWindow)
            if case .text(let value) = restored.pin.content {
                #expect(value == "Pin \(expected)")
            } else {
                Issue.record("Expected text pin \(expected)")
            }
        }
        #expect(!controller.canRestoreClosedPin)
        #expect(!controller.restoreLastClosedPin())
    }

    @Test func imagePinTransformsShadowBorderOverridesTranslateAndColorCopyFormats() throws {
        let image = try #require(Self.picture(size: CGSize(width: 200, height: 120)) {})
        let content = PinController.Content.image(image, scale: 2)
        var translatedPins: [UUID] = []
        let actions = PinController.Actions(
            copy: { _ in }, save: { _ in }, saveAs: { _ in }, annotate: { _ in }, recognizeText: { _ in },
            translate: { translatedPins.append($0.id) }
        )
        let pin = PinController.Pin(id: UUID(), content: content, origin: .clipboard)
        let window = PinWindow(
            pin: pin, frame: CGRect(origin: .zero, size: PinWindow.baseSize(of: content)),
            zoom: 1, appearance: Self.appearance, actions: actions
        )
        defer { window.tearDown() }
        let view = try #require(window.contentView as? PinView)

        let menu = view.makeMenu()
        #expect(menu.items.contains { $0.title == "Translate…" })
        let transformSubmenu = try #require(menu.items.first { $0.title == "Transform" }?.submenu)
        #expect(transformSubmenu.items.compactMap { $0.isSeparatorItem ? nil : $0.title } == [
            "Rotate Right (90°)", "Rotate Left (90°)", "Flip Horizontal", "Flip Vertical",
        ])
        let shadowItem = try #require(menu.items.first { $0.title == "Shadow" })
        let borderItem = try #require(menu.items.first { $0.title == "Border" })
        #expect(shadowItem.state == .on && borderItem.state == .on)

        // Translate invokes action.
        window.translatePin()
        #expect(translatedPins == [pin.id])

        // Rotating 90° swaps width & height and marks transformed; flips toggle flags cleanly.
        let beforeSize = window.baseSize
        window.transformImage(.rotateRight)
        #expect(window.baseSize == CGSize(width: beforeSize.height, height: beforeSize.width))
        #expect(window.rotationSteps == 1 && window.isTransformed)
        window.transformImage(.flipHorizontal)
        window.transformImage(.flipVertical)
        #expect(window.flippedHorizontal && window.flippedVertical)

        // Per-pin Shadow and Border overrides survive global appearance updates.
        window.toggleShadow()
        window.toggleBorder()
        #expect(!window.showsShadow && !window.showsBorder)
        window.apply(PinAppearance(cornerRadius: 8, shadow: true, border: true))
        #expect(!window.showsShadow && !window.showsBorder)
        #expect(window.resolvedAppearance.cornerRadius == 8)

        // Color pin exposes Copy Format submenu with all ColorFormat options.
        let color = try #require(PinColor.parse("#3366FF"))
        let colorContent = PinController.Content.color(color)
        let colorWindow = PinWindow(
            pin: PinController.Pin(id: UUID(), content: colorContent, origin: .clipboard),
            frame: CGRect(origin: .zero, size: PinWindow.baseSize(of: colorContent)),
            zoom: 1, appearance: Self.appearance, actions: actions
        )
        defer { colorWindow.tearDown() }
        let colorView = try #require(colorWindow.contentView as? PinView)
        let copyFormatMenu = try #require(colorView.makeMenu().items.first { $0.title == "Copy Format" }?.submenu)
        #expect(copyFormatMenu.items.map(\.title) == ColorFormat.allCases.map(\.title))
    }
}
