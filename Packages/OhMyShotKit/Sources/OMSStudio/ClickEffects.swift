import Foundation

/// What each click effect looks like over time, apart from how it is drawn: the movie's clicks are drawn from
/// this, and the numbers are all here.
///
/// The ring is the one shown while recording with accent rings: 54 points across, a 3-point line over a wash
/// of the color, widening from a third of its size as it fades over 0.4 s, easing out. The ripple is thinner
/// and spreads further: two lines of 2 points, the second 0.14 s behind the first, each widening from a fifth
/// of 72 points over 0.55 s as it fades, with no wash.
nonisolated extension StudioProject.ClickEffect {
    /// One piece of an effect at a moment: how wide it is against `diameter`, and how visible.
    struct Piece: Equatable {
        var size: Double
        var opacity: Double
    }

    /// How wide the effect's picture is when it is fully spread, in the recording's points.
    var diameter: Double {
        switch self {
        case .ring: 54
        case .ripple: 72
        }
    }

    /// How long the effect lasts, from the click to its last piece fading out.
    var lifetime: Double {
        switch self {
        case .ring: Self.ringLifetime
        case .ripple: Self.rippleDelay * Double(Self.rippleCount - 1) + Self.rippleLifetime
        }
    }

    static let ringLifetime = 0.4
    /// The ring starts at 18 of its 54 points.
    static let ringStart = 18.0 / 54
    static let rippleLifetime = 0.55
    static let rippleDelay = 0.14
    static let rippleCount = 2
    /// A ripple starts at 14.4 of its 72 points.
    static let rippleStart = 0.2

    /// What shows `age` seconds after a click: nothing before it and after `lifetime`.
    func pieces(age: Double) -> [Piece] {
        switch self {
        case .ring:
            guard let piece = Self.spreading(age: age, lifetime: Self.ringLifetime, start: Self.ringStart) else { return [] }
            return [piece]
        case .ripple:
            return (0..<Self.rippleCount).compactMap { index in
                Self.spreading(age: age - Self.rippleDelay * Double(index), lifetime: Self.rippleLifetime, start: Self.rippleStart)
            }
        }
    }

    /// A piece widening from `start` of its full size to all of it, easing out as it fades: the same curve
    /// as the rings shown while recording.
    private static func spreading(age: Double, lifetime: Double, start: Double) -> Piece? {
        guard age >= 0, age < lifetime else { return nil }
        let progress = age / lifetime
        let eased = 1 - (1 - progress) * (1 - progress)
        return Piece(size: start + (1 - start) * eased, opacity: 1 - eased)
    }
}
