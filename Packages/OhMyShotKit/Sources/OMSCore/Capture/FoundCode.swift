import CoreGraphics
import Foundation

/// A QR code or barcode found in a selection, for the chip over it: what it says, whether it is a square of modules
/// (a QR code) or a row of bars, and where it lies in the picture it was found in, in pixels from the top-left corner.
public struct FoundCode: Sendable, Equatable {
    public var payload: String
    public var isMatrix: Bool
    public var box: CGRect

    public init(payload: String, isMatrix: Bool, box: CGRect) {
        self.payload = payload
        self.isMatrix = isMatrix
        self.box = box
    }

    /// The web page the code points to, which is all a chip may open: a code can carry any URL scheme, and a picture
    /// is no reason to launch whatever app claims it. Nil for any other payload.
    public var webURL: URL? {
        guard let url = URL(string: payload), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}

/// What a selection needs to put chips over the codes in it: whether Settings want them, and a way to find them in a
/// picture. Finding them takes a decoder the capture and annotation modules do not have, so the app supplies it.
public struct CodeFinder: Sendable {
    /// Asked before each look: whether selections show the codes in them now.
    public var isOn: @MainActor @Sendable () -> Bool
    /// The codes in a picture (boxes in its pixels, origin at the top left). Called off the main actor.
    public var find: @Sendable (CGImage) async -> [FoundCode]

    public init(isOn: @escaping @MainActor @Sendable () -> Bool, find: @escaping @Sendable (CGImage) async -> [FoundCode]) {
        self.isOn = isOn
        self.find = find
    }
}

/// The words the chips over a selection's codes use, kept here so in-place annotation and All-In-One's frame say the
/// same.
public enum CodeChipWording {
    public static var qrCode: String { String(localized: "QR Code", bundle: .module) }
    public static var barcode: String { String(localized: "Barcode", bundle: .module) }
    public static func codes(_ count: Int) -> String { String(localized: "\(count) Codes", bundle: .module) }
    public static var copy: String { String(localized: "Copy", bundle: .module) }
    public static var openLink: String { String(localized: "Open Link", bundle: .module) }
    public static var copied: String { String(localized: "Copied", bundle: .module) }
    /// What VoiceOver hears when the codes in a selection have been found.
    public static func found(_ count: Int) -> String {
        count == 1
            ? String(localized: "Found a code in the selection. Press Q to see what it says.", bundle: .module)
            : String(localized: "Found \(count) codes in the selection. Press Q to go through them.", bundle: .module)
    }
}
