import AppKit

extension NSMenu {
    /// Opens the menu under `button`, over the overlay: menus float at the pop-up menu level, under the overlay's
    /// panel, which steps just below them while the menu is open.
    func popUp(under button: NSButton) {
        let window = button.window
        let level = window?.level
        if let window, window.level >= .popUpMenu {
            window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        }
        popUp(positioning: nil, at: CGPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 6 : -6), in: button)
        if let window, let level { window.level = level }
    }
}
