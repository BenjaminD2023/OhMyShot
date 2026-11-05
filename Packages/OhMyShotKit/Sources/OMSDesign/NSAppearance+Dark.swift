import AppKit

extension NSAppearance {
    /// Whether this appearance is Dark (its high-contrast and vibrant variants included): what every surface that
    /// draws its own colors asks before it chooses them.
    public var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
