import AppKit

extension NSMenu {
    /// Opens the menu under `view`, or over it when there is more room above, the way a pop-up button
    /// does. Cards and pins often sit near the bottom of the screen, where a menu opened downward is
    /// cut short and has to be scrolled to reach most of its items.
    func popUp(beside view: NSView) {
        let gap: CGFloat = 4
        guard let window = view.window, let screen = window.screen ?? NSScreen.main else {
            popUp(positioning: nil, at: CGPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + gap : -gap), in: view)
            return
        }
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        let visible = screen.visibleFrame
        let height = size.height
        let roomBelow = frame.minY - gap - visible.minY
        let roomAbove = visible.maxY - frame.maxY - gap
        // Screen coordinates: the point is the menu's top-left corner.
        var top = height <= roomBelow || roomBelow >= roomAbove ? frame.minY - gap : frame.maxY + gap + height
        // Keep all of it on the screen when it fits there at all, even if it then covers the button.
        top = min(max(top, visible.minY + height), visible.maxY)
        popUp(positioning: nil, at: CGPoint(x: frame.minX, y: top), in: nil)
    }
}
