import Foundation

/// The colors a person has kept to mark with again, shown beside the preset inks. Kept in the user
/// defaults, at most `limit`, each once, whatever tool saved it.
@MainActor
public final class SavedColors {
    public static let shared = SavedColors()

    /// How many colors can be kept.
    public static let limit = 8

    /// Posted after any change, by whichever store changed: every editor shows the same colors.
    public static let didChange = Notification.Name("OhMyShot.SavedColorsDidChange")

    /// In the order they were saved.
    public private(set) var colors: [RGBA]

    private let defaults: UserDefaults
    private static let key = "annotation.savedColors"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([RGBA].self, from: $0) } ?? []
        var colors: [RGBA] = []
        for color in stored.map(Self.stored) where !colors.contains(color) && colors.count < Self.limit {
            colors.append(color)
        }
        self.colors = colors
    }

    /// Whether the store is full: a color can be saved again only after one is removed.
    public var isFull: Bool { colors.count >= Self.limit }

    public func contains(_ color: RGBA) -> Bool {
        colors.contains(Self.stored(color))
    }

    /// Keeps `color`, without its transparency; false when it is kept already or the store is full.
    @discardableResult
    public func add(_ color: RGBA) -> Bool {
        let color = Self.stored(color)
        guard !colors.contains(color), !isFull else { return false }
        colors.append(color)
        save()
        return true
    }

    public func remove(_ color: RGBA) {
        let color = Self.stored(color)
        guard colors.contains(color) else { return }
        colors.removeAll { $0 == color }
        save()
    }

    /// A color as it is kept: opaque, and on the 8-bit steps a color panel and a screen work in, so the
    /// same color picked twice is one color.
    static func stored(_ color: RGBA) -> RGBA {
        func step(_ value: Double) -> Double { (min(max(value, 0), 1) * 255).rounded() / 255 }
        return RGBA(red: step(color.red), green: step(color.green), blue: step(color.blue))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(colors) {
            defaults.set(data, forKey: Self.key)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
