import AppKit

extension NSImage {
    /// The menu bar mark: the loupe from the app's asset catalog as a template image, or the system
    /// viewfinder symbol where the catalog is absent (tests, previews).
    static func statusItemIcon(accessibilityDescription: String?) -> NSImage? {
        let image = (NSImage(named: "MenuBarIcon")?.copy() as? NSImage)
            ?? NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: accessibilityDescription)
        image?.accessibilityDescription = accessibilityDescription
        image?.isTemplate = true
        return image
    }
}
