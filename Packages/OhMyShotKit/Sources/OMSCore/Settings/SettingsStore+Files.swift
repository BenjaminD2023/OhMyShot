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
    /// taken until a file is saved under it (`reserveFileName`). For a capture's name in the history and a preview in
    /// Settings.
    public func nextFileName(date: Date, appName: String?, windowTitle: String?) -> String {
        fileNameTemplate.name(date: date, appName: appName, windowTitle: windowTitle, counter: nextFileNumber)
    }

    /// A name made from the pattern for a file that is about to be saved, and the number it took.
    public struct ReservedFileName: Equatable, Sendable {
        public let name: String
        /// The `{counter}` value the name holds; nil when the pattern has none, and then no number was taken.
        public let number: Int?
    }

    /// Makes the name the next file saved from the pattern takes and takes its number now, so a file that is named
    /// while another still waits (a name asked for, a Save As panel up) never gets the same one. The number is taken
    /// only when the pattern has `{counter}`. Whoever reserved it saves the file under `name`, or gives the number
    /// back with `release`.
    public func reserveFileName(date: Date, appName: String?, windowTitle: String?) -> ReservedFileName {
        let template = fileNameTemplate
        let name = template.name(date: date, appName: appName, windowTitle: windowTitle, counter: nextFileNumber)
        guard template.usesCounter else { return ReservedFileName(name: name, number: nil) }
        let number = nextFileNumber
        nextFileNumber += 1
        return ReservedFileName(name: name, number: number)
    }

    /// Gives a reserved number back: no file was saved under the name (the person cancelled, or typed a name of their
    /// own). Only the latest number can be taken back; when another file has reserved one since, the gap stays, since
    /// that file's number is not to change.
    public func release(_ reservation: ReservedFileName) {
        guard let number = reservation.number, nextFileNumber == number + 1 else { return }
        nextFileNumber = number
    }
}
