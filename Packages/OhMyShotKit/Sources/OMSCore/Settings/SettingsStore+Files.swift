import Foundation

/// What the file settings make of the app's own files: how a screenshot is written and what a saved file is called.
extension SettingsStore {
    /// How screenshots are written where they leave the app.
    public var screenshotOutput: ScreenshotOutput {
        ScreenshotOutput(
            format: screenshotFormat, quality: screenshotQuality,
            retinaAtOneX: savesRetinaAtOneX, convertsToSRGB: convertsToSRGB, addsBorder: addsBorder
        )
    }

    public var fileNameTemplate: FilenameTemplate {
        FilenameTemplate(pattern: fileNamePattern)
    }

    /// The name the next capture or saved file would take: the pattern with the number it would take, which is not
    /// taken until a file is saved under it. For a capture's name in the history and a preview in Settings.
    public func nextFileName(date: Date, appName: String?, windowTitle: String?) -> String {
        fileNameTemplate.name(date: date, appName: appName, windowTitle: windowTitle, counter: nextFileNumber)
    }

    /// Counts a file saved under a name from `nextFileName`: the next one takes the next number. Nothing happens
    /// when the pattern has no `{counter}`, or the file was named by the person.
    public func didSaveFile(named name: String, offered offeredName: String) {
        guard fileNameTemplate.usesCounter, name == offeredName else { return }
        nextFileNumber += 1
    }
}
