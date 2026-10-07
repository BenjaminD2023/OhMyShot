import AppKit
import CoreText

/// OhMyShot's look: native macOS, light and soft, at CleanShot X's level of craft.
///
/// System colors and materials carry the appearance, so light and dark follow the system and the
/// user's accent color. The app adds soft corner radii, gentle shadows, and the rounded system face
/// for readings. Glass appears only on small controls, never over a full-screen frame.
public enum Theme {
    public enum Radius {
        /// Capture cards and their pictures. Floating controls are full capsules (radius = height / 2).
        public static let card: CGFloat = 12
    }

    /// A soft drop shadow: offset downward, widely blurred, never a hard edge or a halo.
    public enum Shadow {
        public static let opacity: Float = 0.22
        public static let radius: CGFloat = 14
        /// How far the shadow falls below the card, in points.
        public static let drop: CGFloat = 6
    }

    /// The capture overlay.
    public enum Overlay {
        /// How much the screen dims around the selection. Light, so the screen stays readable.
        public static let dimming: CGFloat = 0.26
        /// Used when Increase Contrast is on.
        public static let dimmingIncreasedContrast: CGFloat = 0.45
        public static let borderWidth: CGFloat = 1.5
        /// The soft dark line under the white border, so it reads on light content.
        public static let outlineOpacity: CGFloat = 0.32
        public static let outlineOpacityIncreasedContrast: CGFloat = 0.7
    }

    public enum Loupe {
        /// Diameter in points: a whole number of points per pixel cell, so the grid sits on device pixels.
        public static let diameter: CGFloat = 120
        /// Captured pixels across the lens (8 points per pixel).
        public static let pixelsAcross = 15
        public static let offset: CGFloat = 22
        public static let rimWidth: CGFloat = 3
    }

    /// Short, eased, and skipped entirely with Reduce Motion; nothing trails the pointer.
    public enum Motion {
        /// Cards sliding in, out, and into their new places.
        public static let slide: TimeInterval = 0.22
        /// Hover states fading in and out.
        public static let fade: TimeInterval = 0.12
    }

    public enum Typeface {
        /// Readings such as "1200 × 720": the rounded system face with fixed-width figures, so numbers
        /// stay put as they change.
        public static func reading(size: CGFloat = 12, weight: NSFont.Weight = .semibold) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
            let descriptor = rounded.addingAttributes([
                .featureSettings: [[
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]],
            ])
            return NSFont(descriptor: descriptor, size: size) ?? base
        }

        /// Labels on floating controls.
        public static func label(size: CGFloat = 12, weight: NSFont.Weight = .medium) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
        }
    }

    /// Resolves a dynamic system color for layers, which do not follow appearance changes on their own.
    @MainActor
    public static func cgColor(_ color: NSColor, for appearance: NSAppearance) -> CGColor {
        var result = color.cgColor
        appearance.performAsCurrentDrawingAppearance {
            result = color.cgColor
        }
        return result
    }
}
