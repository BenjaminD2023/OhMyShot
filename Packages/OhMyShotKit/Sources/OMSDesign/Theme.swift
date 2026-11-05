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

    /// The checkerboard that shows transparent room on screen, never in an export: under a clear background in the
    /// editor, and under a translucent color's pin.
    public enum Checkerboard {
        /// A square's side, in points on screen at any zoom.
        public static let square: CGFloat = 8

        /// The two squares' grays: quiet in either appearance, a little firmer with Increase Contrast.
        public static func colors(dark: Bool, increasedContrast: Bool) -> (light: CGColor, dark: CGColor) {
            dark
                ? (CGColor(gray: 0.20, alpha: 1), CGColor(gray: increasedContrast ? 0.30 : 0.25, alpha: 1))
                : (CGColor(gray: 1, alpha: 1), CGColor(gray: increasedContrast ? 0.84 : 0.91, alpha: 1))
        }
    }

    /// The surfaces of what floats over the screen: a card (the text result card, a color's card, a text pin, the
    /// camera bubble before its first frame) and the smaller capsule (the reading capsule, hover tags, a card's badges,
    /// the keys shown while recording). White, a dark gray in Dark, nearly opaque, with a hairline edge that is 1 pt
    /// and firmer under Increase Contrast.
    public enum Material {
        public static func cardFill(dark: Bool) -> CGColor {
            dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 0.96) : CGColor(gray: 1, alpha: 0.97)
        }

        /// A touch more see-through than a card.
        public static func capsuleFill(dark: Bool) -> CGColor {
            dark ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 0.94) : CGColor(gray: 1, alpha: 0.96)
        }

        /// The hairline of a card or a capsule.
        public static func edge(dark: Bool, contrast: Bool) -> CGColor {
            dark ? CGColor(gray: 1, alpha: contrast ? 0.5 : 0.12) : CGColor(gray: 0, alpha: contrast ? 0.35 : 0.08)
        }

        public static func edgeWidth(contrast: Bool) -> CGFloat {
            contrast ? 1 : 0.5
        }
    }

    /// The fill a chip or a row takes under the pointer, and a chip that is on, as the alpha of white in Dark and of
    /// black in Light (DESIGN.md's chip-hover and chip-selected): every bar, rail, capsule, and card button fills its
    /// chips alike. About twice as strong under Increase Contrast where the control follows it.
    public enum ChipFill {
        public static func hover(dark: Bool, contrast: Bool = false) -> CGFloat {
            dark ? (contrast ? 0.16 : 0.09) : (contrast ? 0.09 : 0.045)
        }

        public static func selected(dark: Bool, contrast: Bool = false) -> CGFloat {
            dark ? (contrast ? 0.28 : 0.16) : (contrast ? 0.16 : 0.08)
        }

        /// The hover fill as a layer's color.
        public static func hoverColor(dark: Bool, contrast: Bool) -> CGColor {
            CGColor(gray: dark ? 1 : 0, alpha: hover(dark: dark, contrast: contrast))
        }

        /// The fill of a chip that is on, as a layer's color.
        public static func selectedColor(dark: Bool, contrast: Bool) -> CGColor {
            CGColor(gray: dark ? 1 : 0, alpha: selected(dark: dark, contrast: contrast))
        }
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

    /// An SF Symbol VoiceOver reads as `description`. A toolbar's split button hands its picture to a segment VoiceOver
    /// names by the picture alone, and a symbol given by name is read by its English name ("download").
    public static func symbol(_ name: String, described description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }
}
