import Foundation

/// Auto-scroll's watch on the capture: told four times a second how far Auto-scroll has pushed and how far the
/// capture got, it tells when the content came no further. Since it last pushed four tenths of the area's length
/// (however slowly, and at least three quarters of a second ago), the capture got little of that.
///
/// Two things look the same on those numbers and are no end: the capture falling behind the page (views taking a
/// long while, the stream dropping the frames between, the picture growing later), and a blank stretch taller than
/// the view going by (the stream sends nothing while the view stays blank, and the picture grows only once what
/// follows comes in). A stretch is waited out over three of the area's lengths pushed; a capture behind, over three
/// such looks in a row. And an app may stand still a moment (a page busy drawing, live: 1.1 s, then on at once): the
/// first look that saw little is only quiet, and the watch looks once more afresh; the content came no further when
/// the next sees little too. The content pulled past its end ends it at once.
///
/// The numbers are first guesses: the slow capture was seen only in a Debug build, the blank stretch and the app
/// standing still once each.
nonisolated public struct AutoScrollWatch: Sendable {
    /// How things stood at one look.
    public struct Sample: Sendable {
        /// Since the watch began.
        public var time: Duration
        /// How far Auto-scroll has pushed, in pixels.
        public var pushed: Double
        /// How far the capture got: the picture's length but for an overscroll, in pixels.
        public var settled: Int
        /// The views the capture took in, and how long that took.
        public var views: Int
        public var busy: Duration
        /// How long the view being taken in now has been.
        public var taking: Duration
        public var isInBlank: Bool
        public var isPulled: Bool

        public init(
            time: Duration, pushed: Double, settled: Int, views: Int, busy: Duration, taking: Duration = .zero, isInBlank: Bool = false,
            isPulled: Bool = false
        ) {
            self.time = time
            self.pushed = pushed
            self.settled = settled
            self.views = views
            self.busy = busy
            self.taking = taking
            self.isInBlank = isInBlank
            self.isPulled = isPulled
        }
    }

    public enum Verdict: Sendable, Equatable {
        /// The capture keeps up, or there is too little to tell yet.
        case going
        /// The capture got little, but it is behind the page: not counted.
        case behind
        /// The capture got little of what was pushed, a first time: what took the gesture may have stopped, or the app
        /// stood still a moment. The watch looks once more afresh.
        case quiet(pushed: Int, got: Int)
        /// The content came no further: pushed so many pixels, the capture got so many.
        case stopped(pushed: Int, got: Int)
    }

    /// Of the area's length, what Auto-scroll pushes before the watch looks; and the least time that takes.
    static let reach = 0.4
    static let least: Duration = .milliseconds(750)
    /// Of what was pushed, less than this got is the content stopping.
    static let little = 0.15
    /// Looks further back than this are forgotten.
    static let memory: Duration = .seconds(10)
    /// Of the area's length, how far a blank stretch is pushed through before it is taken for the content's end.
    static let blankPatience = 3.0
    /// Views taking this long on average, or one this long so far, and the capture is behind; and how many looks in a
    /// row it is let off for that.
    static let slowView: Duration = .milliseconds(50)
    static let stuckView: Duration = .milliseconds(150)
    static let behindLooks = 3

    /// The area's length along the axis, in pixels.
    public var extent: Double
    private var samples: [Sample] = []
    /// How far Auto-scroll had pushed when the capture was first seen in a blank stretch.
    private var blankFrom: Double?
    private var behindInARow = 0
    /// The last look that counted saw little.
    private var wasQuiet = false

    public init(extent: Double) {
        self.extent = extent
    }

    /// Takes in how things stand now and tells what to make of it.
    public mutating func look(_ sample: Sample) -> Verdict {
        samples.append(sample)
        samples.removeAll { sample.time - $0.time > Self.memory }
        blankFrom = sample.isInBlank ? blankFrom ?? sample.pushed : nil
        guard let since = samples.last(where: { sample.pushed - $0.pushed >= extent * Self.reach }), sample.time - since.time >= Self.least else {
            return .going
        }
        let pushed = sample.pushed - since.pushed
        let got = Double(abs(sample.settled - since.settled))
        guard got < pushed * Self.little else {
            behindInARow = 0
            wasQuiet = false
            return .going
        }
        // A blank stretch going by: nothing to see grow until what follows comes in. Pulled past its end, the
        // content came to it however blank.
        if let blankFrom, !sample.isPulled, sample.pushed - blankFrom < extent * Self.blankPatience {
            return .going
        }
        let views = sample.views - since.views
        let behind = views > 0 && (sample.busy - since.busy) / views >= Self.slowView || sample.taking >= Self.stuckView
        if behind, !sample.isPulled, behindInARow < Self.behindLooks {
            behindInARow += 1
            samples.removeAll()
            return .behind
        }
        guard sample.isPulled || wasQuiet else {
            wasQuiet = true
            samples.removeAll()
            return .quiet(pushed: Int(pushed), got: Int(got))
        }
        return .stopped(pushed: Int(pushed), got: Int(got))
    }

    /// Forgets what it saw: the gesture moved, and the content may go on from here.
    public mutating func restart() {
        samples.removeAll()
        behindInARow = 0
        wasQuiet = false
    }
}
