import AppKit

extension NSMenu {
    /// Opens the menu to the side of `container`, level with `button`, the way a submenu opens beside its
    /// item: on whichever side has room for it, toward the middle of the screen when both do. Cards and
    /// pins often sit near the bottom of the screen, where a menu opened downward is cut short and has to
    /// be scrolled to reach most of its items; beside them, it covers neither the picture nor the button.
    func popUp(beside button: NSView, outside container: NSView) {
        let gap: CGFloat = 6
        guard let window = button.window, let screen = window.screen ?? NSScreen.main else {
            popUp(positioning: nil, at: CGPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + gap : -gap), in: button)
            return
        }
        func onScreen(_ view: NSView) -> CGRect { window.convertToScreen(view.convert(view.bounds, to: nil)) }
        let buttonFrame = onScreen(button)
        let outside = onScreen(container)
        let visible = screen.visibleFrame
        let size = size

        let roomRight = visible.maxX - outside.maxX - gap
        let roomLeft = outside.minX - gap - visible.minX
        let opensRight: Bool
        if size.width <= roomRight, size.width <= roomLeft {
            opensRight = outside.midX < visible.midX
        } else {
            opensRight = size.width <= roomRight || roomRight >= roomLeft
        }
        var left = opensRight ? outside.maxX + gap : outside.minX - gap - size.width
        left = min(max(left, visible.minX), visible.maxX - size.width)

        // Screen coordinates: the point is the menu's top-left corner. Level with the button's top, moved
        // up or down only as far as it takes to keep all of it on the screen.
        let top = min(max(buttonFrame.maxY, visible.minY + size.height), visible.maxY)
        popUp(positioning: nil, at: CGPoint(x: left, y: top), in: nil)
    }
}
