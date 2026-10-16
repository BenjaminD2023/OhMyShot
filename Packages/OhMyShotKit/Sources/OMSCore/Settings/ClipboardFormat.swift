import Foundation

/// What a screenshot puts on the clipboard.
public enum ClipboardFormat: String, CaseIterable, Sendable {
    /// The picture alone, as PNG (and TIFF for older apps). An app that takes both a file and a picture
    /// pastes the picture.
    case pictureOnly
    /// The picture, and the file in the chosen format beside it, so Finder, mail, and chat apps paste the file
    /// while image editors still paste the picture. Some apps paste the file where the picture was wanted.
    case fileAndPicture
}
