import Foundation

/// How a screenshot is written where it leaves the app: the file format and how much of the picture is changed
/// on the way. The history keeps every capture as a lossless PNG as it was taken whatever this says, so editing,
/// reading text, and restoring are never affected.
public struct ScreenshotOutput: Equatable, Sendable {
    public var format: ImageExporter.Format
    /// JPEG's and HEIC's quality, 0.5 to 1; PNG is lossless.
    public var quality: Double
    /// A picture taken at 2× (or more) is scaled down to 1×: its size in points.
    public var retinaAtOneX: Bool
    /// The picture is converted to sRGB; a wide-gamut display captures in Display P3.
    public var convertsToSRGB: Bool
    /// A 1 px hairline is drawn around the picture, unless its edges are transparent.
    public var addsBorder: Bool

    /// PNG, as captured.
    public static let standard = ScreenshotOutput()

    /// The qualities Settings offers for JPEG and HEIC.
    public static let qualities: ClosedRange<Double> = 0.5...1
    public static let standardQuality = 0.9

    public init(
        format: ImageExporter.Format = .png, quality: Double = standardQuality,
        retinaAtOneX: Bool = false, convertsToSRGB: Bool = false, addsBorder: Bool = false
    ) {
        self.format = format
        self.quality = min(max(quality, Self.qualities.lowerBound), Self.qualities.upperBound)
        self.retinaAtOneX = retinaAtOneX
        self.convertsToSRGB = convertsToSRGB
        self.addsBorder = addsBorder
    }

    /// Whether a capture is written as it was kept: a PNG with nothing done to its picture. Its file is then
    /// copied rather than decoded and encoded again.
    public var isUnchanged: Bool {
        format == .png && !retinaAtOneX && !convertsToSRGB && !addsBorder
    }

    /// Whether the picture's pixels are to be changed (scaled, converted, or given a border), whatever the format.
    /// What the clipboard follows: its picture is PNG always.
    public var changesPicture: Bool {
        retinaAtOneX || convertsToSRGB || addsBorder
    }

    /// Whether the format forgets quality: JPEG and HEIC.
    public var isLossy: Bool {
        format != .png
    }

    /// The same, in another format: a file named `.jpg` in Save As.
    public func with(format: ImageExporter.Format) -> ScreenshotOutput {
        var copy = self
        copy.format = format
        return copy
    }

    /// Names a way of writing a picture, for the folder where converted copies are kept.
    var cacheKey: String {
        var key = format.rawValue
        if isLossy { key += "-\(Int((quality * 100).rounded()))" }
        if retinaAtOneX { key += "-1x" }
        if convertsToSRGB { key += "-srgb" }
        if addsBorder { key += "-border" }
        return key
    }
}

extension ImageExporter.Format {
    /// The format a file name's extension says, or nil for one that is none of these.
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpeg
        case "heic", "heif": self = .heic
        default: return nil
        }
    }

    /// What Settings calls the format.
    public var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }
}
