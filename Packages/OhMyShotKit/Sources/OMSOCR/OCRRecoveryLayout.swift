import CoreGraphics

/// The older recovery model is suitable only for short horizontal text. Image orientation alone
/// cannot establish that: several vertical columns can sit inside a wide screenshot.
public enum OCRRecoveryLayout {
    public static func allows(size: CGSize, textRegions: [CGRect]) -> Bool {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.height <= 1024, size.width >= size.height, !textRegions.isEmpty else { return false }
        // Vertical text can be detected as disconnected square glyphs. A horizontal caption must
        // not make those eligible: every region must establish a horizontal line on its own.
        return textRegions.allSatisfy {
            $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 && $0.width > $0.height * 2
        }
    }
}
