import AppKit
import OMSCore

/// Asks what to call a file before it is saved: a small alert with a field holding the name the file name pattern
/// gives, selected. Return saves under the name; Escape cancels, and nothing is saved.
public enum FileNamePrompt {
    /// The name to save under (without its extension), or nil when the person cancelled.
    /// - Parameters:
    ///   - name: the name the pattern gives, which an empty field also falls back to.
    ///   - fileExtension: the format's, which saving adds.
    ///   - folder: where the file goes, by its Finder name.
    public static func ask(offering name: String, fileExtension: String, folder: String) async -> String? {
        await withCheckedContinuation { continuation in
            // From the run loop, as an event's action would run it: inside a task a modal alert would hold every
            // other task on the main actor until it closed.
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    continuation.resume(returning: run(offering: name, fileExtension: fileExtension, folder: folder))
                }
            }
        }
    }

    private static func run(offering name: String, fileExtension: String, folder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Name the file", bundle: .module)
        alert.informativeText = String(localized: "It is saved in “\(folder)” as a .\(fileExtension) file.", bundle: .module)
        alert.addButton(withTitle: String(localized: "Save", bundle: .module))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .module))
        let field = NSTextField(string: name)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.lineBreakMode = .byTruncatingMiddle
        field.setAccessibilityLabel(String(localized: "File name", bundle: .module))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return FilenameTemplate.typedName(field.stringValue, fallback: name)
    }
}
