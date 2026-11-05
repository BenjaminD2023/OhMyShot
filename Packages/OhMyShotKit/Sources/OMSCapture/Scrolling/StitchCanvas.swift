import Accelerate
import Foundation
import OMSCore
import zlib

/// The content's lines by where they are, in chunks of pages that come and go with it.
///
/// Between the ends, each line is held in segments of 8 pixels, each with how much the views back what it
/// holds. A view backs a segment by about as far as the content moved when the segment moved with the content
/// into where the view shows it: the page outweighs what is over it only while the page passes, and what stays
/// where it is on screen while the content moves backs nothing. A view that shows a segment otherwise than it
/// is held takes back that much, and replaces it when the segment holds no more than that.
///
/// Columns without consistent scrolling motion, staying put over a good part of the view's height (a
/// sidebar, a timeline), are left out of all of it: below the first view's lines they keep the ground, however
/// their pattern repeats. Something stuck over a small part of a column (an avatar while its post scrolls) is
/// weighed with the rest.
nonisolated final class Canvas {
    private static let chunkLines = 256
    /// Different ends a line keeps count of.
    private static let variants = 4
    /// A line's columns are looked at in segments of 8 pixels, a block of them at a time first.
    private static let segmentBytes = 32
    private static let blockSegments = 16
    /// How much the first view backs its lines: as a few views would.
    private static let firstSupport: UInt8 = 32
    /// The most one view backs a segment by.
    private static let largestStep = 16
    /// What a segment one view showed, and none backed since, holds.
    private static let seenOnce: UInt8 = 1
    /// A segment the views saw change where it is this many times keeps changing (an animation, a video), until this
    /// many views in a row see it as the view before did (an animation done, a video paused). Where what keeps
    /// changing is a block of the page (a video, an advertisement, a carousel), the first view that shows all of it at
    /// once takes it (`writeRestless`), and from then on no line by line rule writes it (`video`); what keeps changing
    /// otherwise (a heading's letters sliding in, a shape turning) is left to the line by line rules. `Chunk.changes`
    /// holds the count in its low bits, and `restless`, `still` (all of it was taken from a view where nothing in it
    /// changed) and `video` in its top three.
    private static let restlessChanges: UInt8 = 3
    private static let calmViews: UInt8 = 8
    private static let restless: UInt8 = 0x80
    private static let still: UInt8 = 0x40
    private static let video: UInt8 = 0x20
    private static let counted: UInt8 = 0x0F
    /// Of what `noteChanges` keeps of the view being taken in, per row and segment: it changed where it is in this
    /// view; it keeps changing.
    private static let changedNow: UInt8 = 1
    private static let keepsChanging: UInt8 = 2

    private final class Chunk {
        let pixels: PageBuffer
        /// Per line: 0 never written, 1 seen, 2 among the lines that surely agreed between two views.
        var states = [UInt8](repeating: 0, count: Canvas.chunkLines)
        /// Per line, its hash in each band and whether that part is plain, as views have them.
        var hashes: [UInt32]
        var plain: [Bool]
        /// Per line, the ends it was seen with, by hash, and how often each; and which one it holds.
        var endHashes = [UInt32](repeating: 0, count: Canvas.chunkLines * Canvas.variants)
        var endCounts = [UInt16](repeating: 0, count: Canvas.chunkLines * Canvas.variants)
        var shown = [UInt8](repeating: 0, count: Canvas.chunkLines)
        /// Per line, views in a row whose line, where it showed something else than the line holds, showed what the
        /// view before did there: nothing on it changing; and views whose line showed it changing.
        var calm = [UInt8](repeating: 0, count: Canvas.chunkLines)
        var restless = [UInt8](repeating: 0, count: Canvas.chunkLines)
        /// An in-place update spanning a substantial part of the scrolling content, rather than a
        /// displaced avatar or an isolated caret. Its stable new state may supersede old sharpness.
        var coherentChanges = [Bool](repeating: false, count: Canvas.chunkLines)
        /// Per line and segment, how much the views back what it holds.
        let support: UnsafeMutablePointer<UInt8>
        /// Distance from an occluding edge of the clearest observation at a verified page position.
        let quality: UnsafeMutablePointer<UInt8>
        /// Per line and segment, 1 where what it holds is loose: the ground, or what a view showed that saw the
        /// column not move with the content. What such a view shows may take the place of what is loose only, never
        /// of what a view showed that saw the column move with it.
        let loose: UnsafeMutablePointer<UInt8>
        /// Per line and segment, how often a view showed it otherwise than the view before did, though the line was
        /// where the content had it in both: changing where it is, not moving; and what follows (`Canvas.restless`).
        let changes: UnsafeMutablePointer<UInt8>

        init?(lineBytes: Int, bands: Int, segments: Int) {
            guard let pixels = PageBuffer(byteCount: Canvas.chunkLines * lineBytes) else { return nil }
            self.pixels = pixels
            hashes = [UInt32](repeating: 0, count: Canvas.chunkLines * bands)
            plain = [Bool](repeating: true, count: Canvas.chunkLines * bands)
            support = .allocate(capacity: Canvas.chunkLines * segments)
            support.initialize(repeating: 0, count: Canvas.chunkLines * segments)
            quality = .allocate(capacity: Canvas.chunkLines * segments)
            quality.initialize(repeating: 0, count: Canvas.chunkLines * segments)
            loose = .allocate(capacity: Canvas.chunkLines * segments)
            loose.initialize(repeating: 0, count: Canvas.chunkLines * segments)
            changes = .allocate(capacity: Canvas.chunkLines * segments)
            changes.initialize(repeating: 0, count: Canvas.chunkLines * segments)
        }

        deinit {
            support.deallocate()
            quality.deallocate()
            loose.deallocate()
            changes.deallocate()
        }
    }

    /// How a line is written in.
    enum Writing {
        /// The first view's own line: all of it, as the first view showed it, backed more than any one view backs.
        case first
        /// A line the last view showed too, as `previous`. `sameRow`, the last view's line at the same place on
        /// screen, and `formerRow`, this view's line where the line was in the last view, tell what stayed where
        /// it was on screen. `confirmed`: among the lines that surely agree. `atEdge`: next to a bar; `belowStart`:
        /// within reach of the bar at the start, where what sticks while the content scrolls sticks and is pushed out.
        case agreeing(previous: UnsafeRawPointer, sameRow: UnsafeRawPointer, formerRow: UnsafeRawPointer, confirmed: Bool, atEdge: Bool, belowStart: Bool)
        /// A line just come into view. `sameRow`: the last view's line at the same place on screen; `inward`: this
        /// view's line as many lines further in as the content moved, when there is one.
        case arrived(sameRow: UnsafeRawPointer, inward: UnsafeRawPointer?)
        /// A line only an earlier view showed, kept where nothing else was written: never over a line there.
        case recovered
    }

    let lineBytes: Int
    /// The bytes at each end of a line that are not compared, only counted.
    let endBytes: Int
    /// The parts of a line hashed apart, as views hash them.
    let bands: [Range<Int>]
    private let segments: Int
    private var chunks: [Chunk?] = []
    /// Per segment, how often the views showed it where it was the view before (still) and how often moved
    /// with the content, among the lines that agree and say something there.
    private var stillSeen: [Int]
    private var movingSeen: [Int]
    /// Per segment, the first and last line of a view where it was seen still.
    private var stillFrom: [Int]
    private var stillTo: [Int]
    /// Per segment, the content's lines in views that saw it move with the content: what it showed there it showed
    /// as the page has it, even once it stays put (a sidebar that scrolled, then stuck).
    private var movedOver: [Range<Int>?]
    /// Per segment, views in a row seen still and not moving: it stuck, rather than showing something fixed
    /// between what moves past now and then (a page's fixed background between paragraphs).
    private var stuckFor: [Int]
    /// Per segment, views in a row not seen moving, still or not.
    private var idleFor: [Int]
    /// Per segment, whether the last view saw it move with the content.
    private var movingNow: [Bool]
    /// Per segment, whether a view saw it mostly not move with the content, it stayed put or moved otherwise (a
    /// sidebar held by its foot that stopped partway through the scroll), and none saw it mostly move since.
    private var adrift: [Bool]
    /// Lines that took what came in under columns that stay put, and in which of them, until the next view tells
    /// whether it moved with the content.
    private var tentative: [(index: Int, segments: [Int])] = []
    /// How far on the view before showed what the view being taken in shows moved part of the way the content did (a
    /// sidebar held by its foot, stopping partway through the scroll): the distances `noteColumns` found.
    private var partwayShifts: [Int] = []
    /// Per row and segment of the view being taken in, whether it shows what moved part of the way (`noteDrifted`), and
    /// whether any does.
    private var driftedRows: [Bool] = []
    private var anyDrifted = false
    /// The row of `driftedRows` of the line being weighed, when any of it moved part of the way.
    private var driftedLine: Int?
    /// Per segment of a run of columns adrift, the last line any view saw one of them move over with the content (its
    /// reach): past it, below a sidebar held by its foot, what the run shows stuck there is never the line's. And the
    /// line being weighed.
    private var driftReach: [Int] = []
    private var weighedIndex = 0
    /// Per segment of the line being taken in: grounded as over the content (1), or one color where it was on screen (2).
    private var overlay: [UInt8] = []
    /// Pixel ranges belonging to a compact screen-fixed foreground component, including its enclosed
    /// background-colored marks. These are excluded from evidence even when an individual 8-pixel cell
    /// is indistinguishable from the page's background.
    private var fixedRows: [[Range<Int>]] = []
    private var fixedVisited: [UInt8] = []
    private var fixedIsCurrent = false
    private struct FixedBounds: Hashable {
        let top: Int
        let bottom: Int
        let left: Int
        let right: Int
    }
    private var fixedShapes: [FixedBounds: [(row: Int, bytes: Range<Int>)]] = [:]

    func beginFrame() { fixedIsCurrent = false }
    /// The rows of the view being taken in whose lines `noteChanges` looked at, which of them show something that
    /// keeps changing, and per row and segment what it saw there (`changedNow`, `keepsChanging`).
    private var noted: [Bool] = []
    private var noisy: [Bool] = []
    private var seen: [UInt8] = []
    /// The rows of `seen` that hold something, to clear for the next view.
    private var written: [Int] = []
    /// Per row and segment of the view being taken in, the search for what keeps changing that last went there: one
    /// number a search, so nothing is cleared between views.
    private var visits: [UInt32] = []
    private var search: UInt32 = 0
    /// The view before the one being taken in, as `noteChanges` had it, and how many rows on it showed what the view
    /// being taken in shows.
    private var lastView: Lines?
    private var lastOffset = 0
    /// The blocks that keep changing the last view showed, the page's lines and segments of each.
    private var lastBlocks: [(lines: ClosedRange<Int>, segments: ClosedRange<Int>)] = []
    /// The segments that stay put while the content scrolls (a sidebar, a timeline).
    private(set) var stays: [Bool]
    /// The bytes between the ends, and of the ends, not in segments that stay put: what is weighed, and what
    /// is counted and kept of a line's ends.
    private var scrollingMiddle: [Range<Int>]
    private var scrollingEnds: [Range<Int>]
    /// The bytes between the ends in segments that stay put, and the runs of segments that stay put.
    private var stayingMiddle: [Range<Int>] = []
    private var stayingSegments: [Range<Int>] = []
    /// Views taken in so far: the first is looked at whole for what stays put, so it is known before anything
    /// comes into view.
    private var views = 0
    /// The lines the first view gave, whose columns that stay put are as it showed them.
    private var firstLines: Range<Int>?
    /// The segments of the line being weighed where the first view's out-of-date picture is to give way, and those of
    /// the lines of the view being taken in, each with the view's line and how clear it was there: taken over when the
    /// view is all in, where enough lines in a row have them.
    private var stale: [Int] = []
    private var pendingStale: [(index: Int, source: UnsafeRawPointer, quality: UInt8, starts: [Int])] = []
    /// Restore fixed columns from a coherent first view without freezing the scrolling content forever.
    private var firstSnapshot: PageBuffer?
    private var currentView: Lines?
    /// A line in the ground of each column as the first view showed it, which lines show where what was on
    /// screen stayed put.
    private var ground: PageBuffer?
    /// A line in the color past what stays put in each column: the ground, but under a sidebar held by its foot,
    /// taller than the first view, the page's background below its foot rather than its cards' color.
    private var past: PageBuffer?
    /// How much the view being taken in backs a segment by: about an eighth of how far the content moved.
    private var step: UInt8 = 1
    /// The lines by hash, band by band, for finding a view in the picture: made when first asked for and
    /// kept until a line changes.
    private var located: (range: Range<Int>, indexes: [LineIndex], hashes: [UInt32], plain: [Bool])?
    /// The chunk number of `chunks[0]`.
    private var base = 0
    /// The lines written so far.
    private(set) var range: Range<Int>?

    init(lineBytes: Int, endBytes: Int, bands: [Range<Int>]) {
        self.lineBytes = lineBytes
        self.endBytes = min(endBytes, lineBytes / 4)
        self.bands = bands
        segments = (lineBytes + Self.segmentBytes - 1) / Self.segmentBytes
        stillSeen = [Int](repeating: 0, count: segments)
        movingSeen = [Int](repeating: 0, count: segments)
        stillFrom = [Int](repeating: .max, count: segments)
        stillTo = [Int](repeating: -1, count: segments)
        movedOver = [Range<Int>?](repeating: nil, count: segments)
        stuckFor = [Int](repeating: 0, count: segments)
        idleFor = [Int](repeating: 0, count: segments)
        movingNow = [Bool](repeating: false, count: segments)
        adrift = [Bool](repeating: false, count: segments)
        stays = [Bool](repeating: false, count: segments)
        scrollingMiddle = [self.endBytes ..< lineBytes - self.endBytes]
        scrollingEnds = self.endBytes > 0 ? [0 ..< self.endBytes, lineBytes - self.endBytes ..< lineBytes] : []
    }

    // MARK: What stays put

    /// Takes each column's ground from the first view's `lines`: the color its segment shows most often
    /// where it is one color throughout, else its first pixel.
    func takeGround(from view: Lines, lines: Range<Int>) {
        guard !lines.isEmpty, let ground = PageBuffer(byteCount: lineBytes) else { return }
        if let snapshot = PageBuffer(byteCount: lines.count * lineBytes) {
            memcpy(snapshot.baseAddress, view.line(lines.lowerBound), lines.count * lineBytes)
            firstSnapshot = snapshot
        }
        let samples = Self.samples(of: lines, count: 64)
        for segment in 0..<segments {
            let start = segment * Self.segmentBytes, bytes = min(Self.segmentBytes, lineBytes - start)
            var plain: [UInt32] = []
            for line in samples {
                let pixels = view.line(line) + start
                if Lines.isPlain(pixels, bytes) { plain.append(pixels.load(as: UInt32.self)) }
            }
            let color = Self.mostSeen(plain)?.color ?? (view.line(lines.lowerBound) + start).load(as: UInt32.self)
            let target = (ground.baseAddress + start).bindMemory(to: UInt32.self, capacity: bytes / 4)
            for pixel in 0..<bytes / 4 { target[pixel] = color }
        }
        self.ground = ground
        if let past = PageBuffer(byteCount: lineBytes) {
            memcpy(past.baseAddress, ground.baseAddress, lineBytes)
            self.past = past
        }
    }

    /// Weighs which columns stay put, from lines of `new` that agree with `old` at `offset`: a segment the new
    /// view shows where the old one showed it, and not where the content moved, was still; one shown where the
    /// content moved, and not where it was, moved, unless this view shows it as far on too (a bar alike top to
    /// bottom, such as a timeline's handle creeping down by itself, matches there whether it moves or not). Plain
    /// backgrounds, and segments alike both ways (a pattern repeating at the scroll's distance), say nothing. Thin
    /// colored rules count as features; large flat images do not. A column stays put once seen still a few times, over at
    /// least a sixth of the view's height, without consistent movement: a sidebar, a timeline, but not an avatar stuck
    /// while its post scrolls. The first view is looked at line by line, the rest at some lines.
    func noteColumns(new: Lines, old: Lines, offset: Int, lines: Range<Int>, at position: Int) {
        currentView = new
        views += 1
        var seenStill = [Bool](repeating: false, count: segments)
        var seenMoving = [Bool](repeating: false, count: segments)
        // The lines that showed each segment still, moving with the content, and moved otherwise: part of the way (a
        // sidebar held by its foot stopping partway through the scroll), not changed (a video playing, a picture
        // coming in); and the first and the last that showed it still.
        var still = [Int](repeating: 0, count: segments), moving = still, drifted = still
        var firstStill = [Int](repeating: .max, count: segments), lastStill = [Int](repeating: -1, count: segments)
        var firstAdrift = firstStill, lastAdrift = lastStill
        var informative = [Bool](repeating: false, count: segments)
        // Whether the `length` bytes at `start` of `shown`, line `line`, are where the view before showed them part of
        // the way the content moved: further along than had they stayed put, not as far as had they moved with it.
        // What moves part of the way moves as one (a sidebar), so the distances found are tried first; others are
        // tried a few thousand times a view at most, so a carousel or a video changing in place costs little.
        var partway: [Int] = [], budget = 16_384
        func movedPartway(_ shown: UnsafeRawPointer, _ start: Int, _ length: Int, line: Int) -> Bool {
            guard abs(offset) >= 2 else { return false }
            for shift in partway where line + shift >= 0 && line + shift < old.count {
                if memcmp(shown + start, old.line(line + shift) + start, length) == 0 { return true }
            }
            var shift = offset.signum()
            while shift != offset, budget > 0 {
                defer { shift += offset.signum() }
                guard line + shift >= 0, line + shift < old.count, !partway.contains(shift) else { continue }
                budget -= 1
                if memcmp(shown + start, old.line(line + shift) + start, length) == 0 {
                    partway.append(shift)
                    return true
                }
            }
            return false
        }
        for line in views == 1 ? Array(lines) : Self.samples(of: lines, count: 32, turn: views) where line + offset >= 0 && line + offset < old.count {
            let shown = new.line(line), before = old.line(line), moved = old.line(line + offset)
            let further = line + offset < new.count ? new.line(line + offset) : nil
            for segment in 0..<segments {
                let start = segment * Self.segmentBytes, bytes = min(Self.segmentBytes, lineBytes - start)
                // A flat card border is informative too when it differs from the column's background.
                // Ignoring all single-color runs leaves thin fixed rules repeated down dark timelines.
                guard !Lines.isPlain(shown + start, bytes) || ground.map({ memcmp(shown + start, $0.baseAddress + start, bytes) != 0 }) == true else { continue }
                informative[segment] = true
                let kept = memcmp(shown + start, before + start, bytes) == 0
                let carried = memcmp(shown + start, moved + start, bytes) == 0
                if kept, !carried, isFixedFeature(shown, start, bytes) {
                    stillSeen[segment] += 1
                    seenStill[segment] = true
                    still[segment] += 1
                    firstStill[segment] = min(firstStill[segment], line)
                    lastStill[segment] = max(lastStill[segment], line)
                    firstAdrift[segment] = min(firstAdrift[segment], line)
                    lastAdrift[segment] = max(lastAdrift[segment], line)
                    stillFrom[segment] = min(stillFrom[segment], line)
                    stillTo[segment] = max(stillTo[segment], line)
                }
                if carried, !kept, further.map({ memcmp(shown + start, $0 + start, bytes) != 0 }) ?? true {
                    movingSeen[segment] += 1
                    seenMoving[segment] = true
                    moving[segment] += 1
                }
                if !kept, !carried, movedPartway(shown, start, bytes, line: line) {
                    drifted[segment] += 1
                    firstAdrift[segment] = min(firstAdrift[segment], line)
                    lastAdrift[segment] = max(lastAdrift[segment], line)
                }
            }
        }
        partwayShifts = partway
        // A moving handle can supply a few accidental matches along an otherwise fixed track. Require
        // consistent movement, not a single matching edge, before treating the whole column as content.
        let moves = (0..<segments).map { movingSeen[$0] > 0 && movingSeen[$0] * 16 > stillSeen[$0] }
        movingNow = seenMoving
        // A segment the lines looked at showed mostly not move with the content, staying put or moving part of the way,
        // two of them at least, is adrift: what the view shows there is over the lines, not of them.
        var adriftNow = (0..<segments).map { still[$0] + drifted[$0] >= 2 && still[$0] + drifted[$0] > moving[$0] * 2 }
        // And so are gaps between such segments that the view did not see mostly move: a flat avatar's middle, one
        // color all down the lines the view looked at there, says nothing either way, nor does a sidebar's small
        // print, a line or two of it moving with the content by chance.
        var gap = 0
        while gap < segments {
            guard !adriftNow[gap] else { gap += 1; continue }
            var end = gap
            while end < segments, !adriftNow[end] { end += 1 }
            if gap > 0, end < segments, (gap..<end).allSatisfy({ moving[$0] <= still[$0] + drifted[$0] }) {
                for segment in gap..<end { adriftNow[segment] = true }
            }
            gap = end
        }
        // And so are those beside them that the view saw not move at all as often as move: the ragged edge of a
        // sidebar's names, a line or two of them looked at.
        for segment in 0..<segments where adriftNow[segment] {
            for direction in [-1, 1] {
                var next = segment + direction
                while next >= 0, next < segments, !adriftNow[next], still[next] + drifted[next] >= 1, moving[next] <= still[next] + drifted[next] {
                    adriftNow[next] = true
                    next += direction
                }
            }
        }
        // A view that sees little of a column (a sidebar's blank foot, a line or two of small print) says nothing
        // against what the views before it saw.
        for segment in 0..<segments {
            adrift[segment] = adriftNow[segment] || adrift[segment] && moving[segment] <= still[segment] + drifted[segment]
        }
        // The first view's lines where the next showed something stay put on screen hold it over the line, loose for
        // any view to show what is there, and so do a few lines around it, its soft edge, its shadow: where what did
        // not move with the content (stayed put or moved part of the way) lies within less than half the view (a
        // floating button at the view's foot, an avatar stuck below a header). What does not move down most of the
        // view is a column of its own (a site's navigation, a sidebar stopping partway), which the picture shows as
        // the first view did: taken together across what it shows between (a button's flat middle), not across columns
        // of nothing but the ground (the page's dark margin between a sidebar and a floating button).
        if views == 1, let firstLines {
            let together = (0..<segments).map { adriftNow[$0] && (lastStill[$0] >= 0 || informative[$0]) }
            var run = 0
            while run < segments {
                guard together[run] else { run += 1; continue }
                var end = run
                while end < segments, together[end] { end += 1 }
                defer { run = end }
                let reach = ((run..<end).map { lastAdrift[$0] }.max() ?? -1) - ((run..<end).map { firstAdrift[$0] }.min() ?? .max)
                let top = (run..<end).map { firstStill[$0] }.min() ?? .max, bottom = (run..<end).map { lastStill[$0] }.max() ?? -1
                guard bottom >= top, (reach + 1) * 2 < new.count else { continue }
                for segment in run..<end {
                    for index in max(firstLines.lowerBound, top - 16) ..< min(firstLines.upperBound, bottom + 17) { loosen(index, segment: segment) }
                }
            }
        }
        // What a view showed of a column it saw mostly not move is not as the page has it, a line or two that moved
        // with the content by chance aside. Short gaps between columns it saw move, where it saw nothing at all (the
        // space between two letters of small print, on the lines looked at), moved with them.
        var carriedOver = (0..<segments).map { seenMoving[$0] && moves[$0] && !adrift[$0] }
        var quiet = 0
        while quiet < segments {
            guard !carriedOver[quiet] else { quiet += 1; continue }
            var end = quiet
            while end < segments, !carriedOver[end] { end += 1 }
            if quiet > 0, end < segments, end - quiet <= 3, (quiet..<end).allSatisfy({ still[$0] + moving[$0] + drifted[$0] == 0 }) {
                for segment in quiet..<end { carriedOver[segment] = true }
            }
            quiet = end
        }
        let shown = position ..< position + new.count
        for segment in 0..<segments where carriedOver[segment] {
            movedOver[segment] = movedOver[segment].map { min($0.lowerBound, shown.lowerBound) ..< max($0.upperBound, shown.upperBound) } ?? shown
        }
        driftReach = [Int](repeating: .max, count: segments)
        var adriftRun = 0
        while adriftRun < segments {
            guard adrift[adriftRun] else { adriftRun += 1; continue }
            var end = adriftRun
            while end < segments, adrift[end] { end += 1 }
            // Only a run nothing in moves with the content any more (not text moving over a background that stays put).
            if !(adriftRun..<end).contains(where: { seenMoving[$0] }), let reach = (adriftRun..<end).compactMap({ movedOver[$0]?.upperBound }).max() {
                for segment in adriftRun..<end { driftReach[segment] = reach }
            }
            adriftRun = end
        }
        // What a column did lately counts most: one that scrolled with the page at first and then stuck (a sidebar
        // under a banner, a table of contents, one held by its foot at the view's) stays put once it has stayed put a
        // while. The counts fade an eighth each view; what a column moved fades away altogether once it was seen
        // still and not moving four views in a row (an eighth of fewer than eight is none, and what was left
        // outweighed for good the few still parts of it a view sees: an avatar's edge, a name). Not at the line's
        // ends, which keep counting what comes and goes there (an overlay knob, a window's rounded corner).
        for segment in 0..<segments {
            if seenMoving[segment] { stuckFor[segment] = 0 } else if seenStill[segment] { stuckFor[segment] += 1 }
            idleFor[segment] = seenMoving[segment] ? 0 : idleFor[segment] + 1
            let stuck = stuckFor[segment] >= 4 && isBetweenEnds(segment)
            movingSeen[segment] -= stuck ? (movingSeen[segment] + 7) / 8 : movingSeen[segment] / 8
            stillSeen[segment] -= stillSeen[segment] / 8
        }
        var stays = (0..<segments).map { stillSeen[$0] >= 4 && !moves[$0] && (stillTo[$0] - stillFrom[$0] + 1) * 6 >= new.count }
        // Short gaps between segments that stay put, which never moved, stay put too: a sidebar's blank stretch;
        // and so do short ones between them and the line's end: its margin by the edge of the view, and plain icons in
        // it, which no view tells stay put. A wider gap between them stays put too where views told it stayed put
        // far more than moved, or told nothing at all, or nothing of moving for some views: a sticky card's blank
        // inside, one color like the page around it; a flat avatar's or button's middle in a sidebar that stuck,
        // which says nothing either way once it no longer moves.
        var segment = 0
        while segment < segments {
            guard !stays[segment] else { segment += 1; continue }
            var end = segment
            while end < segments, !stays[end] { end += 1 }
            let enclosed = segment > 0 && end < segments
            let between = enclosed && end - segment <= 3
            let byTheEdge = (segment == 0) != (end == segments) && end - segment <= 8
            let quiet = enclosed && (segment..<end).allSatisfy { stillSeen[$0] >= movingSeen[$0] * 4 || idleFor[$0] >= 8 }
            // On to the line's end, past a column that stays put, where no view saw anything move and views saw it stay
            // put, taken together, over a good part of the view's height: a sticky table of contents' short lines, and
            // the blank by the view's edge after them. Not a button fixed by the edge, seen still only where it is.
            let seenStill = (segment..<end).filter { stillSeen[$0] >= 4 }
            let stillOver = seenStill.map { stillTo[$0] }.max().flatMap { last in seenStill.map { stillFrom[$0] }.min().map { last - $0 + 1 } } ?? 0
            let stillToTheEdge = (segment == 0) != (end == segments) && (segment..<end).allSatisfy { movingSeen[$0] == 0 } && stillOver * 6 >= new.count
            if quiet || stillToTheEdge || (between || byTheEdge) && (segment..<end).allSatisfy({ !moves[$0] }) {
                for gap in segment..<end { stays[gap] = true }
            }
            segment = end
        }
        guard stays != self.stays else { return }
        let newly = (0..<segments).filter { stays[$0] && !self.stays[$0] }
        self.stays = stays
        scrollingMiddle = runs(within: endBytes ..< lineBytes - endBytes)
        scrollingEnds = endBytes > 0 ? runs(within: 0 ..< endBytes) + runs(within: lineBytes - endBytes ..< lineBytes) : []
        var staying: [Range<Int>] = []
        var from = endBytes
        for run in scrollingMiddle + [lineBytes - endBytes ..< lineBytes - endBytes] {
            if run.lowerBound > from { staying.append(from ..< run.lowerBound) }
            from = run.upperBound
        }
        stayingMiddle = staying
        var runs: [Range<Int>] = []
        var start: Int?
        for segment in 0...segments {
            if segment < segments, stays[segment] {
                if start == nil { start = segment }
            } else if let open = start {
                runs.append(open ..< segment)
                start = nil
            }
        }
        stayingSegments = runs
        groundOutsideStill(newly)
        groundNewlyStaying(newly)
    }

    /// Find compact foreground components that agree in screen coordinates but disagree at the verified
    /// page offset. Grow through screen-stationary foreground, then include enclosed marks row by row.
    /// Pure page content agrees at its page offset and cannot seed a component; full-height sidebars remain
    /// the responsibility of the column model. Pixels never observed unobscured keep the known ground.
    func noteFixedOverlays(_ view: Lines, old: Lines, offset: Int, rows: Range<Int>) {
        let previousShapes = fixedShapes
        fixedShapes = [:]
        fixedRows = Array(repeating: [], count: view.count)
        fixedIsCurrent = true
        guard let ground, offset != 0 else { return }
        let width = lineBytes / 4, count = view.count * width
        let source = UnsafeRawPointer(view.pixels.baseAddress).assumingMemoryBound(to: UInt32.self)
        let stationary = UnsafeRawPointer(old.pixels.baseAddress).assumingMemoryBound(to: UInt32.self)
        let floor = UnsafeRawPointer(ground.baseAddress).assumingMemoryBound(to: UInt32.self)
        var stack: [Int] = []
        var visitsReady = false
        for row in rows {
            guard row + offset >= 0, row + offset < old.count else { continue }
            for (band, part) in view.bands.enumerated()
                where view.hashes[band * view.count + row] != old.hashes[band * old.count + row + offset] {
                // Whole cells already explained by the page or the stationary-column model need
                // no pixel search. Most frames consequently never allocate or clear the flood bitmap.
                for column in part.lowerBound * 4 / Self.segmentBytes...(part.upperBound * 4 - 1) / Self.segmentBytes
                    where !stays[column] && !adrift[column] {
                    let left = max(column * Self.segmentBytes, part.lowerBound * 4)
                    let right = min((column + 1) * Self.segmentBytes, part.upperBound * 4)
                    guard memcmp(view.line(row) + left, ground.baseAddress + left, right - left) != 0,
                          !Self.nearlyAlike(view.line(row) + left, old.line(row + offset) + left, right - left) else { continue }
                    for x in left / 4..<right / 4 {
                        let seed = row * width + x
                        guard (!visitsReady || fixedVisited[seed] == 0), source[seed] != floor[x], source[seed] == stationary[seed],
                              !Self.nearlyAlike(view.line(row) + x * 4, old.line(row + offset) + x * 4, 4) else { continue }
                        if !visitsReady {
                            if fixedVisited.count != count { fixedVisited = [UInt8](repeating: 0, count: count) }
                            else { fixedVisited.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
                            visitsReady = true
                        }
                        stack.removeAll(keepingCapacity: true)
                        stack.append(seed)
                        fixedVisited[seed] = 1
                        let foreground = source[seed]
                        var bounds: [Int: (left: Int, right: Int)] = [:]
                        var first = row, last = row, area = 0
                        var changingContour = false
                        while let pixel = stack.popLast() {
                            let y = pixel / width, column = pixel % width
                            first = min(first, y); last = max(last, y); area += 1
                            if let held = bounds[y] { bounds[y] = (min(held.left, column), max(held.right, column)) }
                            else { bounds[y] = (column, column) }
                            for next in [column > 0 ? pixel - 1 : -1, column + 1 < width ? pixel + 1 : -1,
                                         y > 0 ? pixel - width : -1, y + 1 < view.count ? pixel + width : -1] {
                                if next >= 0, (source[next] == foreground) != (stationary[next] == foreground) { changingContour = true }
                                guard next >= 0, fixedVisited[next] == 0, source[next] == foreground,
                                      source[next] == stationary[next], source[next] != floor[next % width] else { continue }
                                fixedVisited[next] = 1
                                stack.append(next)
                            }
                        }
                        // Isolated matching glyph pixels are not a fixed control, nor is a sidebar or a large
                        // stationary background. The component needs two-dimensional extent and substantial area.
                        guard !changingContour, area >= 12, last > first, first > 0, last + 1 < view.count,
                              (last - first + 1) * 2 < view.count, area * 4 < count else { continue }
                        var shape: [(row: Int, bytes: Range<Int>)] = []
                        for (y, extent) in bounds {
                            var begin: Int?
                            for column in extent.left...extent.right + 1 {
                                let same = column <= extent.right && source[y * width + column] == stationary[y * width + column]
                                if same { if begin == nil { begin = column } }
                                else if let start = begin {
                                    fixedRows[y].append(start * 4 ..< column * 4)
                                    shape.append((y, start * 4..<column * 4))
                                    begin = nil
                                }
                            }
                        }
                        let outline = FixedBounds(top: first, bottom: last, left: bounds.values.map(\.left).min()!, right: bounds.values.map(\.right).max()!)
                        fixedShapes[outline] = shape
                    }
                }
            }
        }
        // Previously verified silhouettes remain useful when a large step puts a button entirely
        // in the arriving strip, or when it touches moving content of the same color. Carry a row
        // only while its entire recorded silhouette still matches, including any interior mark.
        for (outline, shape) in previousShapes where fixedShapes[outline] == nil {
            guard shape.allSatisfy({ row, range in
                row < view.count && memcmp(view.line(row) + range.lowerBound, old.line(row) + range.lowerBound, range.count) == 0
            }) else { continue }
            let overlapping = shape.filter { $0.row + offset >= 0 && $0.row + offset < old.count }
            guard overlapping.isEmpty || overlapping.contains(where: { row, range in
                !Self.nearlyAlike(view.line(row) + range.lowerBound, old.line(row + offset) + range.lowerBound, range.count)
            }) else { continue }
            fixedShapes[outline] = shape
            for (row, range) in shape { fixedRows[row].append(range) }
        }
        for row in fixedRows.indices where fixedRows[row].count > 1 {
            var joined: [Range<Int>] = []
            for range in fixedRows[row].sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = joined.last, range.lowerBound <= last.upperBound {
                    joined[joined.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else { joined.append(range) }
            }
            fixedRows[row] = joined
        }
    }

    private func fixedRanges(of source: UnsafeRawPointer) -> [Range<Int>] {
        guard fixedIsCurrent, let currentView else { return [] }
        let offset = UnsafeRawPointer(currentView.pixels.baseAddress).distance(to: source)
        guard offset >= 0, offset.isMultiple(of: lineBytes), offset / lineBytes < fixedRows.count else { return [] }
        return fixedRows[offset / lineBytes]
    }

    /// A column that stays put takes as its ground the plain color the first view showed in it past what was seen
    /// still there, when it showed one: the page's background under a sticky card shorter than the view, which
    /// the card's own color outnumbered in the first view. Not what it showed before it: that scrolled away (a site's
    /// header above a sticky file tree) and is no background of the column's. When the first view showed nothing past
    /// it (a sidebar held by its foot, taller than the view), what comes in past it (`past`) takes the color the view it
    /// came to stay put in shows there instead, its ground still filling what of it was not seen moving.
    private func groundOutsideStill(_ segments: [Int]) {
        guard let ground, let firstSnapshot, let firstLines else { return }
        // The whole of what stays put, run by run of columns: its labels end at different lines, its card at one.
        // Only lines one color across nearly all of the run count, and that color is the line's: the page's
        // background past the card (a pixel a shade off at the view's edge aside), not more of what stays put
        // (a sidebar's next avatar beside the page's white, which would be the avatar's column's color).
        for run in stayingSegments where segments.contains(where: run.contains) {
            let from = run.map { stillFrom[$0] }.min() ?? 0, to = run.map { stillTo[$0] }.max() ?? 0
            guard from <= to else { continue }
            // The one color a line shows across nearly all of the run, if it does.
            func across(_ row: UnsafeRawPointer) -> UInt32? {
                let plain = run.compactMap { segment -> UInt32? in
                    let start = segment * Self.segmentBytes, bytes = min(Self.segmentBytes, lineBytes - start)
                    return Lines.isPlain(row + start, bytes) ? (row + start).load(as: UInt32.self) : nil
                }
                guard let (color, seen) = Self.mostSeen(plain), seen * 10 >= run.count * 9 || seen + 1 >= run.count else { return nil }
                return color
            }
            func first(_ line: Int) -> UnsafeRawPointer { UnsafeRawPointer(firstSnapshot.baseAddress + (line - firstLines.lowerBound) * lineBytes) }
            let start = run.lowerBound * Self.segmentBytes, bytes = min(run.count * Self.segmentBytes, lineBytes - start)
            func fill(_ buffer: PageBuffer?, with color: UInt32) {
                guard let buffer else { return }
                let target = (buffer.baseAddress + start).bindMemory(to: UInt32.self, capacity: bytes / 4)
                for pixel in 0..<bytes / 4 { target[pixel] = color }
            }
            if let (color, seen) = Self.mostSeen(Self.samples(of: firstLines, count: 96).filter { $0 > to }.compactMap { across(first($0)) }), seen >= 8 {
                fill(ground, with: color)
                fill(past, with: color)
                continue
            }
            // What came to stay put after the first view, taller than it (a sidebar held by its foot), shows what is past
            // its foot in the view it came to stay put in: the page's background there, when the first view showed it
            // across the run too (between the sidebar's cards), not something else at the view's foot (a banner).
            guard let view = currentView, to + 1 < view.count,
                  let (color, seen) = Self.mostSeen((to + 1 ..< view.count).compactMap { across(view.line($0)) }), seen >= 8,
                  Self.samples(of: firstLines, count: 96).contains(where: { $0 >= from && $0 <= to && across(first($0)) == color }) else { continue }
            fill(past, with: color)
        }
    }

    /// The color seen most among `colors`, and how often: of two seen as often, the one that got there first, so a
    /// tie never goes either way by chance.
    private static func mostSeen(_ colors: [UInt32]) -> (color: UInt32, seen: Int)? {
        var counts: [UInt32: Int] = [:]
        var most: (color: UInt32, seen: Int)?
        for color in colors {
            let seen = counts[color, default: 0] + 1
            counts[color] = seen
            if seen > most?.seen ?? 0 { most = (color, seen) }
        }
        return most
    }

    /// Lines that came into view before their columns were seen to stay put took those columns as they came, when
    /// they looked like content (a pattern repeating at the scroll's distance does). Nothing moved there, so they
    /// take the ground now, all but the first view's and those of views that saw the column move with the content.
    /// The first view's take what it showed there again, unless the columns were long in coming to stay put: many
    /// views have seen its lines since and left out what stayed on screen over them (a floating button at the first
    /// view's foot), and what they hold stands; but at the line's ends, which are counted rather than weighed, and
    /// can hold what came and went on screen there (an overlay scroll bar's knob).
    private func groundNewlyStaying(_ segments: [Int]) {
        guard !segments.isEmpty, let ground, let range else { return }
        // The last line views saw the run of each segment move over (its reach): past it, what stays put held by its
        // foot shows the page's background below it (`past`), not the color of its cards, which fills what of it was
        // not seen moving.
        var reach = [Int](repeating: .max, count: self.segments)
        for run in stayingSegments where segments.contains(where: run.contains) {
            let end = run.compactMap { movedOver[$0]?.upperBound }.max() ?? .max
            for segment in run { reach[segment] = end }
        }
        let past = past ?? ground
        for index in range {
            let number = Self.chunkNumber(of: index)
            guard number >= base, number - base < chunks.count, let chunk = chunks[number - base] else { continue }
            let slot = index - number * Self.chunkLines
            guard chunk.states[slot] > 0 else { continue }
            let target = chunk.pixels.baseAddress + slot * lineBytes
            let original: UnsafeRawPointer?
            if let firstLines, firstLines.contains(index) {
                guard let firstSnapshot else { continue }
                original = UnsafeRawPointer(firstSnapshot.baseAddress + (index - firstLines.lowerBound) * lineBytes)
            } else { original = nil }
            for segment in segments {
                let start = segment * Self.segmentBytes
                if original == nil, movedOver[segment]?.contains(index) == true { continue }
                if original != nil, views > 8, isBetweenEnds(segment) { continue }
                memcpy(target + start, (original ?? UnsafeRawPointer((index >= reach[segment] ? past : ground).baseAddress)) + start, min(Self.segmentBytes, lineBytes - start))
                chunk.support[slot * self.segments + segment] = 0
                chunk.quality[slot * self.segments + segment] = 0
                chunk.loose[slot * self.segments + segment] = original == nil ? 1 : 0
            }
            rehash(target, chunk: chunk, slot: slot)
        }
    }

    /// The byte ranges within `bounds` not in segments that stay put.
    private func runs(within bounds: Range<Int>) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        var byte = bounds.lowerBound
        while byte < bounds.upperBound {
            let segment = byte / Self.segmentBytes
            let end = min((segment + 1) * Self.segmentBytes, bounds.upperBound)
            if stays[segment] {
                if let open = start { runs.append(open ..< byte) }
                start = nil
            } else if start == nil {
                start = byte
            }
            byte = end
        }
        if let open = start { runs.append(open ..< bounds.upperBound) }
        return runs
    }

    /// Up to `count` lines spread over `lines` unevenly, each a golden ratio of the range on from the last, so
    /// they never fall in step with what repeats down the view (a sidebar's items, a dithered fill); `turn` starts
    /// them elsewhere each time.
    private static func samples(of lines: Range<Int>, count: Int, turn: Int = 0) -> [Int] {
        guard lines.count > count else { return Array(lines) }
        return (0..<count).map { index in
            let fraction = (Double(index + turn * count) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
            return lines.lowerBound + Int(fraction * Double(lines.count))
        }
    }

    /// Whether `length` bytes of `a` and `b` are the same but for the display's dither: no channel more than 3 levels
    /// apart. The dither belongs to the screen, not the page, so a shade alike top to bottom (a gradient left to
    /// right) is the same at the same place on screen view after view, and only nearly the same where it moved to.
    private static func nearlyAlike(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, _ length: Int) -> Bool {
        if memcmp(a, b, length) == 0 { return true }
        let x = a.assumingMemoryBound(to: UInt8.self), y = b.assumingMemoryBound(to: UInt8.self)
        for index in 0..<length where abs(Int(x[index]) - Int(y[index])) > 3 { return false }
        return true
    }

    // MARK: Taking views in

    /// Lines within the range never written.
    var gaps: Int {
        guard let range else { return 0 }
        return range.filter { line($0) == nil }.count
    }

    /// Ends seen in a still view count for this many seen while scrolling, at least.
    private static let stillCount: UInt16 = 8

    /// Whether `segment` lies between the line's ends, which are counted rather than weighed.
    private func isBetweenEnds(_ segment: Int) -> Bool {
        let start = segment * Self.segmentBytes
        return start >= endBytes && start + Self.segmentBytes <= lineBytes - endBytes
    }

    /// Lets what line `index` holds in `segment` give way to what any view shows there, if the line is there.
    private func loosen(_ index: Int, segment: Int) {
        let number = Self.chunkNumber(of: index)
        guard number >= base, number - base < chunks.count, let chunk = chunks[number - base] else { return }
        chunk.loose[(index - number * Self.chunkLines) * segments + segment] = 1
    }

    /// Settles the lines taken in under columns that stay put, now that `view` shows the content from `position`
    /// on: what moved with it stands; what it no longer shows where it went takes the ground.
    func settleTentative(_ view: Lines, at position: Int) {
        guard let ground, !tentative.isEmpty else { return }
        defer { tentative.removeAll() }
        for (index, segments) in tentative {
            let row = index - position
            let number = Self.chunkNumber(of: index)
            guard row >= 0, row < view.count, number >= base, number - base < chunks.count, let chunk = chunks[number - base] else { continue }
            let slot = index - number * Self.chunkLines
            let target = chunk.pixels.baseAddress + slot * lineBytes
            var changed = false
            for segment in segments {
                let start = segment * Self.segmentBytes, bytes = min(Self.segmentBytes, lineBytes - start)
                guard memcmp(target + start, view.line(row) + start, bytes) != 0 else { continue }
                memcpy(target + start, (past ?? ground).baseAddress + start, bytes)
                chunk.support[slot * self.segments + segment] = 0
                chunk.loose[slot * self.segments + segment] = 1
                changed = true
            }
            if changed { rehash(target, chunk: chunk, slot: slot) }
        }
    }

    /// Starts taking in a view the content moved `travel` pixels for, whose lines `lines` it showed before too:
    /// each of their segments the canvas holds is backed by this view, as far as the content moved; writing a
    /// line takes that back where the view shows something else.
    func beginView(travel: Int, lines: Range<Int>) {
        step = UInt8(min(Self.largestStep, max(1, travel / 8)))
        var table = [UInt8](repeating: 0, count: 256)
        for value in 0..<256 { table[value] = UInt8(min(255, value + Int(step))) }
        var line = lines.lowerBound
        while line < lines.upperBound {
            let number = Self.chunkNumber(of: line)
            let start = number * Self.chunkLines
            let end = min(lines.upperBound, start + Self.chunkLines)
            defer { line = end }
            guard number >= base, number - base < chunks.count, let chunk = chunks[number - base] else { continue }
            var from = vImage_Buffer(
                data: chunk.support + (line - start) * segments, height: vImagePixelCount(end - line), width: vImagePixelCount(segments), rowBytes: segments
            )
            var to = from
            vImageTableLookUp_Planar8(&from, &to, table, vImage_Flags(kvImageDoNotTile))
        }
    }

    /// The view being taken in is all in: where at least `fewestLines` lines in a row hold the first view's out-of-date
    /// picture (`weigh`), what the view shows takes its place, backed as the first view's was, and the first view's
    /// ends there count as one view's.
    func endView(fewestLines: Int) {
        defer { pendingStale.removeAll(keepingCapacity: true) }
        guard !pendingStale.isEmpty else { return }
        pendingStale.sort { $0.index < $1.index }
        var runStart = 0
        for end in 1...pendingStale.count where end == pendingStale.count || pendingStale[end].index != pendingStale[end - 1].index + 1 {
            defer { runStart = end }
            guard end - runStart >= fewestLines else { continue }
            for item in pendingStale[runStart..<end] {
                let number = Self.chunkNumber(of: item.index)
                guard number >= base, number - base < chunks.count, let chunk = chunks[number - base] else { continue }
                let slot = item.index - number * Self.chunkLines
                let target = chunk.pixels.baseAddress + slot * lineBytes
                for start in item.starts {
                    let segment = start / Self.segmentBytes, length = min(Self.segmentBytes * (segment + 1), lineBytes) - start
                    memcpy(target + start, item.source + start, length)
                    chunk.support[slot * segments + segment] = Self.firstSupport
                    chunk.quality[slot * segments + segment] = item.quality
                    chunk.loose[slot * segments + segment] = adrift[segment] ? 1 : 0
                }
                rehash(target, chunk: chunk, slot: slot)
                let shown = slot * Self.variants + Int(chunk.shown[slot])
                chunk.endCounts[shown] = min(chunk.endCounts[shown], 1)
            }
        }
    }

    /// Writes `source` as line `index`, as `writing` says. A line not there yet takes `source`, but the ground
    /// where what is on screen stayed put; one there is weighed segment by segment. The ends are counted, and the
    /// ends seen most are the ones kept. `still`: seen while nothing scrolled. A line there is no memory for is
    /// left out, a gap in the picture.
    func write(_ source: UnsafeRawPointer, at index: Int, as writing: Writing, still: Bool = false, quality: UInt8 = 0) {
        let grown = range.map { min($0.lowerBound, index) ..< max($0.upperBound, index + 1) } ?? index ..< index + 1
        let number = Self.chunkNumber(of: index)
        if chunks.isEmpty {
            base = number
        }
        if number < base {
            chunks.insert(contentsOf: [Chunk?](repeating: nil, count: base - number), at: 0)
            base = number
        }
        while number - base >= chunks.count { chunks.append(nil) }
        if chunks[number - base] == nil { chunks[number - base] = Chunk(lineBytes: lineBytes, bands: bands.count, segments: segments) }
        guard let chunk = chunks[number - base] else { return }
        let slot = index - number * Self.chunkLines
        let target = chunk.pixels.baseAddress + slot * lineBytes
        let support = chunk.support + slot * segments
        let loose = chunk.loose + slot * segments
        let changes = chunk.changes + slot * segments
        let state = chunk.states[slot]
        let masked = fixedRanges(of: source)
        let saved = state == 0 ? [] : masked.map { Data(bytes: target + $0.lowerBound, count: $0.count) }
        let covered = Set(masked.flatMap { $0.lowerBound / Self.segmentBytes ... ($0.upperBound - 1) / Self.segmentBytes })
        let qualities = chunk.quality + slot * segments
        let evidence = covered.map { (segment: $0, support: support[$0], quality: qualities[$0], loose: loose[$0]) }
        defer {
            if !masked.isEmpty, let ground {
                for (part, range) in masked.enumerated() {
                    if state == 0 { memcpy(target + range.lowerBound, ground.baseAddress + range.lowerBound, range.count) }
                    else { saved[part].withUnsafeBytes { bytes in _ = memcpy(target + range.lowerBound, bytes.baseAddress!, range.count) } }
                }
                for entry in evidence {
                    support[entry.segment] = state == 0 ? 0 : entry.support
                    qualities[entry.segment] = state == 0 ? 0 : entry.quality
                    loose[entry.segment] = state == 0 ? 1 : entry.loose
                }
                rehash(target, chunk: chunk, slot: slot)
            }
        }
        if state == 0 {
            memcpy(target, source, lineBytes)
            loose.update(repeating: 0, count: segments)
            changes.update(repeating: 0, count: segments)
            switch writing {
            case .first:
                for segment in 0..<segments { support[segment] = Self.firstSupport }
                (chunk.quality + slot * segments).update(repeating: quality, count: segments)
                firstLines = firstLines.map { min($0.lowerBound, index) ..< max($0.upperBound, index + 1) } ?? index ..< index + 1
            case .arrived(let sameRow, let inward):
                takeIn(source, into: target, at: index, support: support, loose: loose, sameRow: sameRow, alike: inward)
            case .agreeing(let previous, let sameRow, _, _, _, _):
                // Not there yet though the last view showed it (the part that scrolls grew): as just come into view.
                takeIn(source, into: target, at: index, support: support, loose: loose, sameRow: sameRow, alike: previous)
            case .recovered:
                support.update(repeating: Self.seenOnce, count: segments)
            }
            let confirmed = if case .agreeing(_, _, _, true, _, _) = writing { true } else { false }
            chunk.states[slot] = confirmed ? 2 : 1
            rehash(target, chunk: chunk, slot: slot)
            let first = slot * Self.variants
            for variant in 0..<Self.variants { chunk.endCounts[first + variant] = 0 }
            chunk.endHashes[first] = endsHash(source)
            chunk.endCounts[first] = still ? Self.stillCount : 1
            chunk.shown[slot] = 0
            range = grown
            return
        }
        // Under allocation pressure keep the initial snapshot intact. Normally, fixed columns have
        // their own original copy while clearer later views may repair the content near viewport edges.
        if firstSnapshot == nil, firstLines?.contains(index) == true {
            count(source, into: target, chunk: chunk, slot: slot, still: still)
            return
        }
        switch writing {
        case .first, .recovered:
            return
        case .arrived(let sameRow, let inward):
            if reconsider(
                source, into: target, support: support, qualities: chunk.quality + slot * segments, loose: loose, changes: changes,
                quality: quality, sameRow: sameRow, alike: inward
            ) {
                rehash(target, chunk: chunk, slot: slot)
                // Seen only once, and something else then (a banner that was over it): its ends as well.
                if state < 2 {
                    for part in scrollingEnds { memcpy(target + part.lowerBound, source + part.lowerBound, part.count) }
                    let first = slot * Self.variants
                    for variant in 0..<Self.variants { chunk.endCounts[first + variant] = 0 }
                    chunk.endHashes[first] = endsHash(source)
                    chunk.endCounts[first] = still ? Self.stillCount : 1
                    chunk.shown[slot] = 0
                    return
                }
            }
        case .agreeing(let previous, let sameRow, let formerRow, let confirmed, let atEdge, let belowStart):
            driftedLine = driftedRow(of: sameRow)
            weighedIndex = index
            let coherentChange = chunk.coherentChanges[slot]
            // Whether the line still holds just what the first view showed, to tell below whether that gave way.
            let wasFirst: Bool = {
                guard let firstSnapshot, let firstLines, firstLines.contains(index) else { return false }
                return memcmp(target, firstSnapshot.baseAddress + (index - firstLines.lowerBound) * lineBytes, lineBytes) == 0
            }()
            let preferred = preferUnobscured(
                source, into: target, support: support, qualities: chunk.quality + slot * segments, loose: loose, changes: changes,
                quality: quality, previous: previous, sameRow: sameRow
            )
            let firstRow = firstSnapshot.flatMap { snapshot in
                firstLines.flatMap { $0.contains(index) ? UnsafeRawPointer(snapshot.baseAddress + (index - $0.lowerBound) * lineBytes) : nil }
            }
            stale.removeAll(keepingCapacity: true)
            var updatedState = false
            let weighed = weigh(
                source, into: target, support: support, previous: previous, sameRow: sameRow, formerRow: formerRow,
                held: state == 2, atEdge: atEdge, belowStart: belowStart, qualities: chunk.quality + slot * segments, loose: loose, changes: changes,
                quality: quality,
                firstRow: firstRow, calm: &chunk.calm[slot], restless: &chunk.restless[slot], coherentChange: coherentChange, updatedState: &updatedState
            )
            if scrollingEnds.contains(where: { memcmp(source + $0.lowerBound, target + $0.lowerBound, $0.count) != 0 }) {
                let newState = updatedState || coherentChange && scrollingMiddle.allSatisfy { memcmp(source + $0.lowerBound, target + $0.lowerBound, $0.count) == 0 }
                    && (0..<segments).contains { changes[$0] & (Self.video | Self.restless) == 0 && changes[$0] & Self.counted > 0 }
                if newState { refreshChangedEnds(source, target: target, previous: previous, sameRow: sameRow, chunk: chunk, slot: slot) }
            }
            if preferred || weighed {
                rehash(target, chunk: chunk, slot: slot)
                // What the first view showed of the line gave way, most of it, to something else altogether (a picture
                // loaded after the first view, not a shade a little off): its ends no longer outweigh what the views show
                // next by a still view's count, but follow the ends two views agree on.
                if wasFirst, changedThroughout(target, firstOf: index) {
                    let shown = slot * Self.variants + Int(chunk.shown[slot])
                    chunk.endCounts[shown] = min(chunk.endCounts[shown], 1)
                }
            }
            if !stale.isEmpty { pendingStale.append((index, source, quality, stale)) }
            if confirmed { chunk.states[slot] = 2 }
        }
        count(source, into: target, chunk: chunk, slot: slot, still: still)
    }

    /// Marks what the lines of `view` at `rows` show moved part of the way the content did, before any is written: a
    /// segment that says something, shown neither where the content moved nor where it was on screen but where `old`
    /// showed it one of `partwayShifts` on, and the one color beside it in the same column, as near to it as it moved
    /// short of the content (the blank between a sidebar's lines of small print). The lines `noteColumns` looked at are
    /// few, and miss a column's small print stopping partway through the scroll; what the view shows there is over the
    /// lines, as in a column found adrift. Only bands that differ from the last view's line are looked at, and nothing
    /// that keeps changing where it is (a video playing, which matches somewhere by chance).
    func noteDrifted(view: Lines, old: Lines, offset: Int, rows: [Int], at position: Int) {
        if anyDrifted {
            driftedRows.withUnsafeMutableBufferPointer { $0.update(repeating: false) }
            anyDrifted = false
        }
        guard !partwayShifts.isEmpty else { return }
        if driftedRows.count != view.count * segments { driftedRows = [Bool](repeating: false, count: view.count * segments) }
        let reach = partwayShifts.map { abs(offset - $0) }.max() ?? 0
        var found: [(row: Int, segment: Int)] = []
        var differing: [ClosedRange<Int>] = []
        for row in rows where row + offset >= 0 && row + offset < old.count {
            differing.removeAll(keepingCapacity: true)
            for (band, part) in view.bands.enumerated() where view.hashes[band * view.count + row] != old.hashes[band * old.count + row + offset] {
                var range = part.lowerBound * 4 / Self.segmentBytes ... (part.upperBound * 4 - 1) / Self.segmentBytes
                if let last = differing.last, last.upperBound >= range.lowerBound {
                    range = last.lowerBound ... range.upperBound
                    differing.removeLast()
                }
                differing.append(range)
            }
            guard !differing.isEmpty else { continue }
            let index = position + row, number = Self.chunkNumber(of: index)
            let chunk = number >= base && number - base < chunks.count ? chunks[number - base] : nil
            let slot = index - number * Self.chunkLines
            let changes = chunk.flatMap { $0.states[slot] != 0 ? $0.changes + slot * segments : nil }
            let source = view.line(row), previous = old.line(row + offset), sameRow = old.line(row)
            for range in differing {
                for segment in range where isBetweenEnds(segment) && !stays[segment] && !adrift[segment] {
                    if let changes, changes[segment] & (Self.restless | Self.video) != 0 { continue }
                    let start = segment * Self.segmentBytes, length = min(Self.segmentBytes, lineBytes - start)
                    guard !Self.nearlyAlike(source + start, previous + start, length), !Lines.isPlain(source + start, length),
                          memcmp(source + start, sameRow + start, length) != 0 else { continue }
                    for shift in partwayShifts where row + shift >= 0 && row + shift < old.count {
                        guard memcmp(source + start, old.line(row + shift) + start, length) == 0 else { continue }
                        found.append((row, segment))
                        break
                    }
                }
            }
        }
        guard !found.isEmpty else { return }
        anyDrifted = true
        for (row, segment) in found {
            driftedRows[row * segments + segment] = true
            let start = segment * Self.segmentBytes, length = min(Self.segmentBytes, lineBytes - start)
            // The blank beside it, one color up to something else: not across into a bar of another color.
            for direction in [-1, 1] {
                var next = row + direction, color: UInt32?
                while abs(next - row) <= reach, next >= 0, next < view.count, Lines.isPlain(view.line(next) + start, length) {
                    let shown = (view.line(next) + start).load(as: UInt32.self)
                    if color == nil { color = shown } else if shown != color { break }
                    driftedRows[next * segments + segment] = true
                    next += direction
                }
            }
        }
    }

    /// Whether `line`, line `index` of the first view's, now holds between its ends, in half its segments or more,
    /// something unlike what the first view showed there by more than a shade.
    private func changedThroughout(_ line: UnsafeRawPointer, firstOf index: Int) -> Bool {
        guard let firstSnapshot, let firstLines, firstLines.contains(index) else { return false }
        let first = UnsafeRawPointer(firstSnapshot.baseAddress + (index - firstLines.lowerBound) * lineBytes)
        var changed = 0, all = 0
        for run in scrollingMiddle {
            var start = run.lowerBound
            while start < run.upperBound {
                let end = min((start / Self.segmentBytes + 1) * Self.segmentBytes, run.upperBound)
                defer { start = end }
                all += 1
                let a = (line + start).assumingMemoryBound(to: UInt8.self), b = first.assumingMemoryBound(to: UInt8.self) + start
                if (0..<(end - start)).contains(where: { abs(Int(a[$0]) - Int(b[$0])) > 24 }) { changed += 1 }
            }
        }
        return all > 0 && changed * 2 >= all
    }

    /// Counts where the lines of `view` at `rows`, which the last view, `old`, showed `offset` rows on, change where
    /// they are, before any is written: whether something that keeps changing can be taken whole depends on the lines
    /// around it, which come after it.
    func noteChanges(view: Lines, old: Lines, offset: Int, rows: [Int], at position: Int) {
        lastView = old
        lastOffset = offset
        noted = [Bool](repeating: false, count: view.count)
        noisy = noted
        if seen.count != view.count * segments {
            seen = [UInt8](repeating: 0, count: view.count * segments)
        } else {
            seen.withUnsafeMutableBufferPointer { seen in
                for row in written where row < view.count { (seen.baseAddress! + row * segments).update(repeating: 0, count: segments) }
            }
        }
        written.removeAll(keepingCapacity: true)
        // The segments of the line being counted in bands that differ from the last view's line (a band the same in
        // both, by its hash, is the same throughout).
        var differing: [ClosedRange<Int>] = []
        seen.withUnsafeMutableBufferPointer { seen in
            for row in rows {
                let index = position + row
                let number = Self.chunkNumber(of: index)
                guard number >= base, number - base < chunks.count, let chunk = chunks[number - base] else { continue }
                let slot = index - number * Self.chunkLines
                guard chunk.states[slot] != 0, firstSnapshot != nil || firstLines?.contains(index) != true else { continue }
                noted[row] = true
                let changes = chunk.changes + slot * segments, flags = seen.baseAddress! + row * segments
                // Where the line is as the last view showed it, nothing to count, unless something on it keeps changing:
                // most lines of most views, and most of the rest.
                let restless = Self.anyRestless(changes, count: segments)
                differing.removeAll(keepingCapacity: true)
                if restless {
                    differing.append(0 ... segments - 1)
                } else {
                    for (band, part) in view.bands.enumerated() where view.hashes[band * view.count + row] != old.hashes[band * old.count + row + offset] {
                        var range = part.lowerBound * 4 / Self.segmentBytes ... (part.upperBound * 4 - 1) / Self.segmentBytes
                        if let last = differing.last, last.upperBound >= range.lowerBound {
                            range = last.lowerBound ... range.upperBound
                            differing.removeLast()
                        }
                        differing.append(range)
                    }
                    guard !differing.isEmpty else { continue }
                }
                countChanges(
                    view.line(row), previous: old.line(row + offset), sameRow: old.line(row), formerRow: view.line(row + offset), changes: changes,
                    changedNow: flags, within: differing, restless: restless
                )
                written.append(row)
                for segment in 0..<segments where changes[segment] & Self.restless != 0 && isBetweenEnds(segment) && !stays[segment] {
                    flags[segment] |= Self.keepsChanging
                    noisy[row] = true
                }
                let changed = (0..<segments).filter {
                    isBetweenEnds($0) && !stays[$0] && changes[$0] & (Self.video | Self.restless) == 0 && changes[$0] & Self.counted > 0
                }
                let contentWidth = scrollingMiddle.reduce(0) { $0 + $1.count } / Self.segmentBytes
                chunk.coherentChanges[slot] = changed.count >= 4 && (changed.last! - changed.first! + 1) * 2 >= contentWidth
            }
        }
    }

    /// Takes in, from `view`, the content `band` of which lies at `position`, each block of the page that keeps changing
    /// where it is (a video, an advertisement, a carousel) that it shows whole, at least `inset` lines from the bars, all
    /// of it from the one view (`takeWhole`): line by line, each line's clearest view would be another frame, and the
    /// block would come out in bands. A block is what keeps changing held together segment to segment, with the lines
    /// past it come into view since, filling at least half of its bounds. One never shown whole (taller than the view,
    /// or what is around it changing too) is left to the line by line rules, as is what keeps changing here and there.
    func writeRestless(_ view: Lines, band: Range<Int>, at position: Int, inset: Int) {
        var blocks: [(lines: ClosedRange<Int>, segments: ClosedRange<Int>)] = []
        defer { lastBlocks = blocks }
        guard noted.count == view.count, noisy.contains(true) else { return }
        let rows = max(band.lowerBound, 0) ..< min(band.upperBound, view.count)
        // The side rows come into view on: below when the content moves up.
        let arriving = lastOffset > 0 ? 1 : -1
        if visits.count != view.count * segments { visits = [UInt32](repeating: 0, count: view.count * segments) }
        if search > UInt32.max - UInt32(view.count * segments) {
            search = 0
            visits.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        }
        var found: [(top: Int, bottom: Int, left: Int, right: Int, cells: Int, changing: Int)] = []
        var stack: [(row: Int, segment: Int)] = []
        let segments = self.segments
        seen.withUnsafeBufferPointer { seen in
            visits.withUnsafeMutableBufferPointer { visits in
                search += 1
                let mark = search
                for row in rows where noisy[row] {
                    for segment in 0..<segments where seen[row * segments + segment] & Self.keepsChanging != 0 && visits[row * segments + segment] != mark {
                        visits[row * segments + segment] = mark
                        // What keeps changing, with the rows past it that came into view since and change in this view, not
                        // changed often enough yet (the rest of a video come in under it).
                        stack.removeAll(keepingCapacity: true)
                        stack.append((row, segment))
                        var top = row, bottom = row, left = segment, right = segment, cells = 0
                        while let (r, c) = stack.popLast() {
                            cells += 1
                            top = min(top, r)
                            bottom = max(bottom, r)
                            left = min(left, c)
                            right = max(right, c)
                            func reach(_ nr: Int, _ nc: Int) {
                                guard rows.contains(nr), nc >= 0, nc < segments, noted[nr] else { return }
                                let cell = nr * segments + nc
                                guard visits[cell] != mark else { return }
                                guard seen[cell] & Self.keepsChanging != 0 || seen[cell] & Self.changedNow != 0 && nr - r == arriving else { return }
                                visits[cell] = mark
                                stack.append((nr, nc))
                            }
                            reach(r - 1, c)
                            reach(r + 1, c)
                            reach(r, c - 1)
                            reach(r, c + 1)
                        }
                        var changing = 0
                        for r in top...bottom {
                            for c in left...right where seen[r * segments + c] & Self.changedNow != 0 { changing += 1 }
                        }
                        found.append((top, bottom, left, right, cells, changing))
                    }
                }
            }
        }
        for (top, bottom, left, right, cells, changing) in found {
            // A block of the page that keeps changing, most of it (a video, an advertisement, a carousel), not what
            // keeps changing here and there (a heading's letters sliding in, a shape turning, an avatar passing).
            let area = (bottom - top + 1) * (right - left + 1)
            guard bottom - top + 1 >= 2 * inset, right - left + 1 >= 8, cells * 2 >= area else { continue }
            // Where the last view showed it too, or a block all through (a slide sliding in): a video stays where it
            // is in the page, a shape sliding across does not, nor does one turning fill its corners.
            let block = (lines: position + top ... position + bottom, segments: left...right)
            blocks.append(block)
            let staying = cells * 20 >= area * 19 || lastBlocks.contains { Self.overlapsMostly($0, block) }
            takeWhole(
                view, rows: top...bottom, segments: left...right, band: band, inset: inset, settled: changing == 0,
                moving: changing * 2 >= area && staying, at: position
            )
        }
    }

    /// Whether any of the `count` segments `changes` has of a line keeps changing.
    private static func anyRestless(_ changes: UnsafePointer<UInt8>, count: Int) -> Bool {
        var index = 0
        while index + 8 <= count {
            if UnsafeRawPointer(changes + index).loadUnaligned(as: UInt64.self) & 0x8080_8080_8080_8080 != 0 { return true }
            index += 8
        }
        while index < count {
            if changes[index] & restless != 0 { return true }
            index += 1
        }
        return false
    }

    /// Whether two blocks share at least half of what either covers.
    private static func overlapsMostly(
        _ a: (lines: ClosedRange<Int>, segments: ClosedRange<Int>), _ b: (lines: ClosedRange<Int>, segments: ClosedRange<Int>)
    ) -> Bool {
        let lines = min(a.lines.upperBound, b.lines.upperBound) - max(a.lines.lowerBound, b.lines.lowerBound) + 1
        let columns = min(a.segments.upperBound, b.segments.upperBound) - max(a.segments.lowerBound, b.segments.lowerBound) + 1
        guard lines > 0, columns > 0 else { return false }
        let shared = lines * columns
        return shared * 2 >= a.lines.count * a.segments.count && shared * 2 >= b.lines.count * b.segments.count
    }

    /// Takes the stretch `rows` by `segments` of `view` into the picture, if the view shows it whole: all of it, though
    /// parts were taken clearer, for one frame of it; from then on only a view that shows it whole writes it. The first
    /// view to show it whole while most of it changes where the last view showed it too (`moving`: a video playing, not
    /// a shape turning, which changes at its edge, nor one sliding across) takes it; then a view where nothing in it
    /// changed (`settled`: a slide held, a video paused), and one where it is changing (a crossfade, a slide sliding, a
    /// video playing) when no less clear than the least clear part of it was taken, unless all of it was taken from a
    /// view where nothing in it changed.
    private func takeWhole(
        _ view: Lines, rows: ClosedRange<Int>, segments columns: ClosedRange<Int>, band: Range<Int>, inset: Int, settled: Bool, moving: Bool,
        at position: Int
    ) {
        // Well inside the view: what changes under a bar seen through (a header's blur) keeps changing too, and none of
        // it is the page's.
        guard rows.lowerBound - inset >= band.lowerBound, rows.upperBound + inset < band.upperBound,
              noted[rows.lowerBound - 1], noted[rows.upperBound + 1], rows.allSatisfy({ noted[$0] }) else { return }
        let taken = columns.filter { isBetweenEnds($0) && !stays[$0] && !adrift[$0] }
        guard !taken.isEmpty, taken.allSatisfy({ column in
            seen[(rows.lowerBound - 1) * segments + column] & Self.changedNow == 0 && seen[(rows.upperBound + 1) * segments + column] & Self.changedNow == 0
        }) else { return }
        let quality = UInt8(clamping: min(rows.lowerBound - band.lowerBound, band.upperBound - 1 - rows.upperBound) + 1)
        var lines: [(chunk: Chunk, slot: Int)] = []
        var least = UInt8.max, held = true, fresh = false
        for row in rows {
            let index = position + row
            let number = Self.chunkNumber(of: index)
            guard number >= base, number - base < chunks.count, let chunk = chunks[number - base] else { return }
            let slot = index - number * Self.chunkLines
            for column in taken {
                let cell = slot * segments + column
                least = min(least, chunk.quality[cell])
                if chunk.changes[cell] & Self.still == 0 { held = false }
                if chunk.changes[cell] & Self.video == 0 { fresh = true }
            }
            lines.append((chunk, slot))
        }
        guard fresh ? moving : settled || !held && quality >= least else { return }
        for (row, line) in zip(rows, lines) {
            let target = line.chunk.pixels.baseAddress + line.slot * lineBytes, source = view.line(row)
            for column in taken {
                let start = column * Self.segmentBytes, bytes = min(Self.segmentBytes, lineBytes - start)
                // Not where the view shows what the last view did at the same place on screen and not where the content
                // moved from: something stuck over it there (a header come down over the top of a video).
                if let lastView, row < lastView.count, memcmp(source + start, lastView.line(row) + start, bytes) == 0,
                   row + lastOffset < 0 || row + lastOffset >= lastView.count
                       || memcmp(source + start, lastView.line(row + lastOffset) + start, bytes) != 0 { continue }
                memcpy(target + start, source + start, bytes)
                let cell = line.slot * segments + column
                line.chunk.quality[cell] = quality
                line.chunk.support[cell] = max(Self.firstSupport, line.chunk.support[cell])
                line.chunk.loose[cell] = 0
                line.chunk.changes[cell] |= settled ? Self.video | Self.still : Self.video
            }
            rehash(target, chunk: line.chunk, slot: line.slot)
        }
    }

    /// Counts, segment by segment, where `source` shows the line otherwise than `previous`, the last view, did, and where
    /// as it did: what changes where it is (a video playing, a picture loading) and for how long it holds still. Not
    /// where what did not move with the content says why it changed: it came over the line (`sameRow`, the last view's
    /// line at the same place on screen, shows it too) or left it (`formerRow`, this view's line where the line was,
    /// still shows what the line did), as a chat button in a corner does over each line passing under it. Only the
    /// segments `within` the ranges, the rest being as `previous` has them; `restless`: something on the line keeps
    /// changing, so what holds still counts too.
    private func countChanges(
        _ source: UnsafeRawPointer, previous: UnsafeRawPointer, sameRow: UnsafeRawPointer, formerRow: UnsafeRawPointer,
        changes: UnsafeMutablePointer<UInt8>, changedNow: UnsafeMutablePointer<UInt8>, within ranges: [ClosedRange<Int>], restless: Bool
    ) {
        for range in ranges {
            for run in scrollingMiddle {
                let lower = max(run.lowerBound, range.lowerBound * Self.segmentBytes)
                let upper = min(run.upperBound, (range.upperBound + 1) * Self.segmentBytes)
                guard lower < upper else { continue }
                // All of it as the last view showed it, nothing on the line changing lately: nothing to count.
                if !restless, memcmp(source + lower, previous + lower, upper - lower) == 0 { continue }
                countChanges(source, previous: previous, sameRow: sameRow, formerRow: formerRow, changes: changes, changedNow: changedNow, bytes: lower..<upper)
            }
        }
    }

    /// Counts the segments of `run`, bytes of the line, as `countChanges(_:previous:sameRow:formerRow:...)` says.
    private func countChanges(
        _ source: UnsafeRawPointer, previous: UnsafeRawPointer, sameRow: UnsafeRawPointer, formerRow: UnsafeRawPointer,
        changes: UnsafeMutablePointer<UInt8>, changedNow: UnsafeMutablePointer<UInt8>, bytes run: Range<Int>
    ) {
        var start = run.lowerBound
        while start < run.upperBound {
            let segment = start / Self.segmentBytes
            let end = min((segment + 1) * Self.segmentBytes, run.upperBound), length = end - start
            defer { start = end }
            guard !adrift[segment] else { continue }
            let value = changes[segment], flags = value & (Self.still | Self.video), count = value & Self.counted
            if Self.nearlyAlike(source + start, previous + start, length) {
                // Held still long enough, it is done changing: the line by line rules take it again.
                if value & Self.restless != 0 {
                    changes[segment] = count + 1 >= Self.calmViews ? value & Self.still : Self.restless | flags | (count + 1)
                }
                continue
            }
            guard memcmp(source + start, sameRow + start, length) != 0, memcmp(previous + start, formerRow + start, length) != 0 else { continue }
            changedNow[segment] |= Self.changedNow
            changes[segment] = value & Self.restless != 0 || count + 1 >= Self.restlessChanges ? Self.restless | flags : flags | (count + 1)
        }
    }

    /// The view's row whose line the view before showed at `sameRow`, when `noteDrifted` found something there.
    private func driftedRow(of sameRow: UnsafeRawPointer) -> Int? {
        guard anyDrifted, let lastView else { return nil }
        let offset = UnsafeRawPointer(lastView.pixels.baseAddress).distance(to: sameRow)
        guard offset >= 0, offset.isMultiple(of: lineBytes), offset / lineBytes < lastView.count else { return nil }
        let row = offset / lineBytes
        return row * segments < driftedRows.count ? row : nil
    }

    /// Whether `segment` of the line being weighed is over the line: its column found adrift, or what it shows moved
    /// part of the way the content did.
    private func drifting(_ segment: Int) -> Bool {
        adrift[segment] || driftedLine.map { driftedRows[$0 * segments + segment] } ?? false
    }

    /// Whether the line being weighed lies past the reach of the run of columns adrift that `segment` is in: what the
    /// view shows there stuck over the line, loose or not.
    private func pastReach(_ segment: Int) -> Bool {
        adrift[segment] && segment < driftReach.count && weighedIndex >= driftReach[segment]
    }

    /// Votes alone favor whichever direction was traversed most often. Near a sticky edge that can be a
    /// displaced avatar, or the blank margin hiding its real position. Prefer a view whose page position
    /// is confirmed farther inside the viewport, even when visited only once. Fixed columns keep their first view.
    private func preferUnobscured(
        _ source: UnsafeRawPointer, into target: UnsafeMutableRawPointer, support: UnsafeMutablePointer<UInt8>,
        qualities: UnsafeMutablePointer<UInt8>, loose: UnsafeMutablePointer<UInt8>, changes: UnsafeMutablePointer<UInt8>, quality: UInt8,
        previous: UnsafeRawPointer, sameRow: UnsafeRawPointer
    ) -> Bool {
        var changed = false
        for run in scrollingMiddle {
            var start = run.lowerBound
            while start < run.upperBound {
                let segment = start / Self.segmentBytes
                let end = min((segment + 1) * Self.segmentBytes, run.upperBound)
                defer { start = end }
                guard quality > qualities[segment] else { continue }
                // A clearer view of just what the line holds holds it at that clearness, though it looks the same where
                // it was on screen (a flat stretch of a picture): else what comes over it there later (a sticky tab
                // bar), seen once a little clearer than ever counted, takes its place for good.
                if memcmp(source + start, target + start, end - start) == 0 {
                    qualities[segment] = quality
                    continue
                }
                // What a column shows in a view that saw it mostly not move with the content, staying put or moving
                // part of the way (a sidebar held by its foot, stopped partway through the scroll and stuck from then
                // on, before the views tell it stays put), is over the line: no clearer view of what a view that saw
                // the column move showed there. Of what is loose it may be (an avatar stuck below a header come to
                // rest where its post begins, moving part of the way as it does); not past the last line any view saw
                // the column move over, though, where what stuck there is never the line's (a sidebar held by its foot,
                // below its foot).
                if drifting(segment), loose[segment] == 0 || pastReach(segment) { continue }
                // Nor is anything of a block that keeps changing where it is (a video): only a view that shows all of it
                // writes it, one frame (`writeRestless`).
                if changes[segment] & Self.video != 0 { continue }
                guard !staysPut(source, start, end - start, sameRow: sameRow, alike: previous) else { continue }
                // What stayed where it was on screen while the content moved on is over the content (a sticky
                // sidebar's flat strokes, a highlighted item's bar), no clearer observation of it; and a table's or
                // timeline's stroke, alike top to bottom, matches both positions without saying anything.
                if !Lines.isPlain(source + start, end - start), memcmp(source + start, sameRow + start, end - start) == 0 { continue }
                // So is one color where it was on screen that the line did not show in the last view, but for the
                // column's own ground (the page come out from under what was over it): a flat button fixed over the
                // page, which shows the line as it never is when the line passes under it nearer the view's middle
                // than any view showed it since.
                if memcmp(source + start, sameRow + start, end - start) == 0, !Self.nearlyAlike(source + start, previous + start, end - start),
                   let ground, memcmp(source + start, ground.baseAddress + start, end - start) != 0 { continue }
                // Nor is a segment the edge of such a button crosses, beside its flat inside or its mark.
                if partlyOver(source, start, end - start, sameRow: sameRow, alike: previous),
                   besideOver(source, segment: segment, run: run, sameRow: sameRow, alike: previous) { continue }
                qualities[segment] = quality
                if memcmp(source + start, target + start, end - start) != 0 {
                    memcpy(target + start, source + start, end - start)
                    support[segment] = max(Self.firstSupport, support[segment])
                    loose[segment] = drifting(segment) ? 1 : 0
                    changed = true
                }
            }
        }
        return changed
    }

    /// Whether some of the `length` bytes of `source` at `start`, two pixels at least, are something over the content:
    /// what the last view showed at the same place on screen (`sameRow`), unlike the column's ground and unlike `alike`
    /// but for the display's dither, the rest of them showing the content beside it (the edge of a button fixed over
    /// the page, across a segment).
    private func partlyOver(_ source: UnsafeRawPointer, _ start: Int, _ length: Int, sameRow: UnsafeRawPointer, alike: UnsafeRawPointer?) -> Bool {
        guard let ground else { return false }
        let pixels = (source + start).assumingMemoryBound(to: UInt32.self), same = (sameRow + start).assumingMemoryBound(to: UInt32.self)
        let floor = UnsafeRawPointer(ground.baseAddress + start).assumingMemoryBound(to: UInt32.self)
        var over = 0
        for pixel in 0 ..< length / 4 where pixels[pixel] == same[pixel] && pixels[pixel] != floor[pixel] {
            if let alike, Self.nearlyAlike(source + start + pixel * 4, alike + start + pixel * 4, 4) { continue }
            over += 1
            if over >= 2 { return true }
        }
        return false
    }

    /// Whether a segment beside `segment` in `run` is all over the content: one color where it was on screen that the
    /// line did not show in the last view, but for the column's own ground (a button's flat inside), or what stays put
    /// (its mark).
    private func besideOver(_ source: UnsafeRawPointer, segment: Int, run: Range<Int>, sameRow: UnsafeRawPointer, alike: UnsafeRawPointer?) -> Bool {
        guard let ground else { return false }
        for next in [segment - 1, segment + 1] {
            let lower = max(next * Self.segmentBytes, run.lowerBound), upper = min((next + 1) * Self.segmentBytes, run.upperBound)
            guard lower < upper else { continue }
            let length = upper - lower
            if Lines.isPlain(source + lower, length) {
                if memcmp(source + lower, sameRow + lower, length) == 0, memcmp(source + lower, ground.baseAddress + lower, length) != 0,
                   alike.map({ !Self.nearlyAlike(source + lower, $0 + lower, length) }) ?? true { return true }
            } else if staysPut(source, lower, length, sameRow: sameRow, alike: alike) {
                return true
            }
        }
        return false
    }

    /// Whether `length` bytes of `source` at `start` are something over the content: they are what the last view
    /// showed at the same place on screen, they say something, and they are unlike `alike` (a line that shows them
    /// where they would be had they moved with the content, or further along a stretch alike top to bottom, such as
    /// a table's edge).
    private func staysPut(_ source: UnsafeRawPointer, _ start: Int, _ length: Int, sameRow: UnsafeRawPointer, alike: UnsafeRawPointer?) -> Bool {
        guard memcmp(source + start, sameRow + start, length) == 0, isFixedFeature(source, start, length) else { return false }
        guard let alike else { return true }
        return !Self.nearlyAlike(source + start, alike + start, length)
    }

    /// A colored flat run is a fixed-rule candidate only when surrounded by background along the scroll
    /// axis. Large white images on dark pages must not be mistaken for fixed borders while they load.
    private func isFixedFeature(_ source: UnsafeRawPointer, _ start: Int, _ length: Int) -> Bool {
        if !Lines.isPlain(source + start, length) { return true }
        guard let ground, let view = currentView,
              memcmp(source + start, ground.baseAddress + start, length) != 0 else { return false }
        let offset = UnsafeRawPointer(view.pixels.baseAddress).distance(to: source)
        guard offset >= 0, offset.isMultiple(of: lineBytes) else { return false }
        let row = offset / lineBytes
        let reach = max(2, min(8, endBytes / 24))
        guard row >= reach, row + reach < view.count else { return false }
        return memcmp(view.line(row - reach) + start, ground.baseAddress + start, length) == 0
            && memcmp(view.line(row + reach) + start, ground.baseAddress + start, length) == 0
    }

    /// A line new to the canvas, `source` already copied to `target`: each segment seen once, but what stays put
    /// on screen and one color beside it where it was on screen too (a button's flat inside), which take the ground.
    /// Loose, what took the ground and what the view showed where it saw the column not move with the content.
    private func takeIn(
        _ source: UnsafeRawPointer, into target: UnsafeMutableRawPointer, at index: Int, support: UnsafeMutablePointer<UInt8>,
        loose: UnsafeMutablePointer<UInt8>, sameRow: UnsafeRawPointer, alike: UnsafeRawPointer?
    ) {
        support.update(repeating: Self.seenOnce, count: segments)
        guard let ground else { return }
        // The columns that stay put, ends and all; between the ends, what stays put on screen this time. But between
        // the ends, where the line shows what was not on screen there before, and the column was seen moving with
        // the content this time or what of it stays put was never seen this far along the view, it may be content
        // come in under or past what stays put (a page's footer below a sticky contents list): it is taken until the
        // next view tells whether it moved with the content (or stayed on screen where it was: a floating button
        // fading in).
        // Only a line of the view the columns were last weighed on can say so (not one a view found again shows).
        let row = currentView.flatMap { view -> Int? in
            let offset = UnsafeRawPointer(view.pixels.baseAddress).distance(to: source)
            return offset >= 0 && offset.isMultiple(of: lineBytes) && offset / lineBytes < view.count ? offset / lineBytes : nil
        }
        var taken: [Int] = []
        for run in stayingSegments {
            for segment in run {
                let start = segment * Self.segmentBytes, bytes = min(Self.segmentBytes, lineBytes - start)
                let beyond = row.map { $0 < stillFrom[segment] || $0 > stillTo[segment] } ?? false
                if row != nil, isBetweenEnds(segment), movingNow[segment] || beyond, memcmp(source + start, sameRow + start, bytes) != 0 {
                    taken.append(segment)
                    continue
                }
                memcpy(target + start, (past ?? ground).baseAddress + start, bytes)
                support[segment] = 0
            }
        }
        if !taken.isEmpty { tentative.append((index, taken)) }
        if overlay.count != segments { overlay = [UInt8](repeating: 0, count: segments) }
        for run in scrollingMiddle {
            var start = run.lowerBound
            while start < run.upperBound {
                let segment = start / Self.segmentBytes, end = min((segment + 1) * Self.segmentBytes, run.upperBound)
                overlay[segment] = 0
                if staysPut(source, start, end - start, sameRow: sameRow, alike: alike) {
                    memcpy(target + start, ground.baseAddress + start, end - start)
                    support[segment] = 0
                    overlay[segment] = 1
                } else if Lines.isPlain(source + start, end - start), memcmp(source + start, sameRow + start, end - start) == 0,
                          memcmp(source + start, ground.baseAddress + start, end - start) != 0,
                          alike.map({ !Self.nearlyAlike(source + start, $0 + start, end - start) }) ?? true {
                    overlay[segment] = 2
                }
                start = end
            }
        }
        // One color where it was on screen, held between or beside what is over the content in the line, is over it
        // too: the inside of a button fixed over the page, whose edge and mark are. A stretch of the page that looks
        // the same where it was on screen (the inside of a white picture whose text just loaded) has no such edge: the
        // picture's sides are alike all down, so they are not over the content.
        for run in scrollingMiddle {
            let first = run.lowerBound / Self.segmentBytes, last = (run.upperBound - 1) / Self.segmentBytes
            var segment = first
            while segment <= last {
                guard overlay[segment] == 2 else { segment += 1; continue }
                var end = segment
                while end <= last, overlay[end] == 2 { end += 1 }
                if segment > first && overlay[segment - 1] == 1 || end <= last && overlay[end] == 1 {
                    for flat in segment..<end {
                        let start = max(flat * Self.segmentBytes, run.lowerBound), stop = min((flat + 1) * Self.segmentBytes, run.upperBound)
                        memcpy(target + start, ground.baseAddress + start, stop - start)
                        support[flat] = 0
                    }
                }
                segment = end
            }
        }
        for segment in 0..<segments where support[segment] == 0 || row != nil && adrift[segment] { loose[segment] = 1 }
    }

    /// A line come into view again: each segment that shows something else says so once against what it
    /// holds, but what stays put on screen. Whether the line changed.
    private func reconsider(
        _ source: UnsafeRawPointer, into target: UnsafeMutableRawPointer, support: UnsafeMutablePointer<UInt8>,
        qualities: UnsafeMutablePointer<UInt8>, loose: UnsafeMutablePointer<UInt8>, changes: UnsafeMutablePointer<UInt8>, quality: UInt8,
        sameRow: UnsafeRawPointer, alike: UnsafeRawPointer?
    ) -> Bool {
        var changed = false
        for run in scrollingMiddle {
            var start = run.lowerBound
            while start < run.upperBound {
                let end = min((start / Self.segmentBytes + 1) * Self.segmentBytes, run.upperBound), segment = start / Self.segmentBytes
                defer { start = end }
                guard quality >= qualities[segment], memcmp(source + start, target + start, end - start) != 0,
                      !staysPut(source, start, end - start, sameRow: sameRow, alike: alike),
                      !adrift[segment] || loose[segment] != 0, changes[segment] & Self.video == 0 else { continue }
                if support[segment] > step {
                    support[segment] -= step
                } else {
                    memcpy(target + start, source + start, end - start)
                    support[segment] = Self.seenOnce
                    loose[segment] = adrift[segment] ? 1 : 0
                    changed = true
                }
            }
        }
        return changed
    }

    /// A line the last view showed too, already backed by this view: segment by segment where it shows
    /// something else, that backing is taken back; what moved with the content there says so against what the
    /// segment holds (twice as much when it says something and stayed nowhere on screen); and what the line
    /// held from the last view alone, which stayed where it was on screen while the line moved on, was over the
    /// content and gives way to the ground. `held`: among the lines that agreed before, whose blocks that stay
    /// put on screen are passed over. `atEdge`: next to a bar, where a plain stretch says nothing: an avatar
    /// stuck below a header leaves its post's blank margin where it was, which must neither back the margin nor
    /// wear the avatar away there. `belowStart`: where an avatar stuck below a header is pushed out by its post's
    /// end, moving with the content as it goes: what moves there says nothing against what a segment holds, though
    /// it may fill one that holds nothing. Columns that stay put are only backed where they show what they hold:
    /// should one turn out to move after all (an avatar stuck from the start, until the next one moves through),
    /// what was over it backs nothing there. `loose`: per segment, whether what the line holds may give way to what a
    /// view shows that saw the column not move with the content. Whether the line changed.
    private func weigh(
        _ source: UnsafeRawPointer, into target: UnsafeMutableRawPointer, support: UnsafeMutablePointer<UInt8>,
        previous: UnsafeRawPointer, sameRow: UnsafeRawPointer, formerRow: UnsafeRawPointer, held: Bool, atEdge: Bool, belowStart: Bool,
        qualities: UnsafeMutablePointer<UInt8>, loose: UnsafeMutablePointer<UInt8>, changes: UnsafeMutablePointer<UInt8>, quality: UInt8,
        firstRow: UnsafeRawPointer?, calm: UnsafeMutablePointer<UInt8>, restless: UnsafeMutablePointer<UInt8>, coherentChange: Bool,
        updatedState: inout Bool
    ) -> Bool {
        for run in stayingMiddle {
            var from = run.lowerBound
            while from < run.upperBound {
                let to = min(run.upperBound, (from / Self.segmentBytes + Self.blockSegments) * Self.segmentBytes)
                if memcmp(source + from, target + from, to - from) != 0 {
                    for segment in from / Self.segmentBytes ..< (to + Self.segmentBytes - 1) / Self.segmentBytes { support[segment] -= min(support[segment], step) }
                }
                from = to
            }
        }
        if atEdge {
            for run in scrollingMiddle {
                var start = run.lowerBound
                while start < run.upperBound {
                    let end = min((start / Self.segmentBytes + 1) * Self.segmentBytes, run.upperBound)
                    let segment = start / Self.segmentBytes
                    if Lines.isPlain(source + start, end - start), memcmp(source + start, target + start, end - start) == 0 {
                        support[segment] -= min(support[segment], step)
                    }
                    start = end
                }
            }
        }
        var differs = false
        for run in scrollingMiddle where memcmp(source + run.lowerBound, target + run.lowerBound, run.count) != 0 {
            differs = true
            break
        }
        guard differs else { return false }
        // Whether all the line shows otherwise than it holds moved with the content since the last view, and for how
        // many views in a row: nothing on it changing any more (a video playing changes, or rests a view at most).
        var settled = true
        for run in scrollingMiddle where settled {
            var start = run.lowerBound
            while start < run.upperBound, settled {
                let end = min((start / Self.segmentBytes + 1) * Self.segmentBytes, run.upperBound)
                if memcmp(source + start, target + start, end - start) != 0, !Self.nearlyAlike(source + start, previous + start, end - start) {
                    settled = false
                }
                start = end
            }
        }
        calm.pointee = settled ? calm.pointee &+ (calm.pointee < .max ? 1 : 0) : 0
        if !settled, restless.pointee < .max { restless.pointee += 1 }
        var changed = false
        for run in scrollingMiddle {
            var from = run.lowerBound
            while from < run.upperBound {
                let to = min(run.upperBound, (from / Self.segmentBytes + Self.blockSegments) * Self.segmentBytes)
                defer { from = to }
                guard memcmp(source + from, target + from, to - from) != 0 else { continue }
                // What stays put on screen, over a line the views agreed on: nothing in it moved, nothing to weigh,
                // and what the line holds under it is not backed by this view.
                if held, !Lines.isPlain(source + from, to - from), memcmp(source + from, sameRow + from, to - from) == 0 {
                    for segment in from / Self.segmentBytes ..< (to + Self.segmentBytes - 1) / Self.segmentBytes { support[segment] -= min(support[segment], step) }
                    continue
                }
                var start = from
                while start < to {
                    let segment = start / Self.segmentBytes
                    let end = min((segment + 1) * Self.segmentBytes, to), length = end - start
                    defer { start = end }
                    guard memcmp(source + start, target + start, length) != 0 else { continue }
                    support[segment] -= min(support[segment], step)
                    // Against what a view showed that saw the column move with the content, a view that saw it mostly
                    // not move says nothing: what it shows there stayed put or moved otherwise. Nor does a line that shows
                    // what moved part of the way, where the lines the view looked at missed it.
                    let drifted = drifting(segment)
                    if drifted, loose[segment] == 0,
                       !(coherentChange && Self.nearlyAlike(source + start, previous + start, length) && memcmp(source + start, sameRow + start, length) != 0) { continue }
                    // Repeated passes close to a sticky edge cannot overrule a clearer interior observation.
                    // A broad, confirmed in-place update which subsequent aligned views show unchanged can:
                    // a carousel's older sharp frame is no longer its current state. Isolated avatars and
                    // continuously changing video retain their existing protection. The original viewport's
                    // placeholder still uses the grouped `endView` path, including its margin-vote reset.
                    if quality < qualities[segment] {
                        let changedInPlace = coherentChange && changes[segment] & (Self.video | Self.restless) == 0 && changes[segment] & Self.counted > 0
                        let original = firstRow.map { memcmp(target + start, $0 + start, length) == 0 } ?? false
                        guard calm.pointee >= 2, restless.pointee <= 2, !atEdge, !belowStart || changedInPlace,
                              original || changedInPlace, Self.nearlyAlike(source + start, previous + start, length),
                              // What stayed where it was on screen is over the content; but a plain stretch over one (a
                              // placeholder's color, a blank row of the picture that replaced it) looks alike everywhere.
                              changedInPlace || memcmp(source + start, sameRow + start, length) != 0
                                  || Lines.isPlain(source + start, length) && Lines.isPlain(target + start, length) else { continue }
                        if !original && changedInPlace {
                            // In-place change is positive evidence, independent of the first viewport:
                            // after repeated aligned observations of the new state, old sharpness cannot
                            // preserve an earlier carousel slide or stale document text indefinitely.
                            memcpy(target + start, source + start, length)
                            support[segment] = Self.firstSupport
                            qualities[segment] = quality
                            loose[segment] = 0
                            changed = true
                            updatedState = true
                        } else {
                            stale.append(start)
                        }
                        continue
                    }
                    if Self.nearlyAlike(source + start, previous + start, length) {
                        // What a column stuck there shows past the last line it was seen to move over is not the line's.
                        if drifted, pastReach(segment) { continue }
                        let plain = Lines.isPlain(source + start, length)
                        if (plain && atEdge) || belowStart, support[segment] > Self.seenOnce { continue }
                        // Below the bar at the start, plain and just where it was on screen: a stuck avatar's blank
                        // edge as much as the content's margin.
                        if plain, belowStart, memcmp(source + start, sameRow + start, length) == 0 { continue }
                        let still = !plain && memcmp(source + start, sameRow + start, length) == 0
                        // Alike where it was on screen too: a line alike top to bottom, moving or not (a table's edge,
                        // a timeline's track). It fills what holds nothing, never what something backs.
                        if still, support[segment] > Self.seenOnce { continue }
                        let against = Int(step) * (plain || still ? 1 : 2)
                        if Int(support[segment]) > against {
                            support[segment] -= UInt8(against)
                        } else if changes[segment] & Self.video == 0 {
                            memcpy(target + start, source + start, length)
                            support[segment] = step + 1
                            loose[segment] = drifted ? 1 : 0
                            changed = true
                        }
                    } else if support[segment] <= step, let ground,
                              memcmp(target + start, previous + start, length) == 0,
                              memcmp(previous + start, formerRow + start, length) == 0,
                              memcmp(target + start, ground.baseAddress + start, length) != 0 {
                        memcpy(target + start, ground.baseAddress + start, length)
                        support[segment] = 0
                        loose[segment] = 1
                        changed = true
                    } else if support[segment] <= Self.seenOnce, changes[segment] & Self.video == 0,
                              // Not what a column stuck there shows past the last line it was seen to move over, either.
                              !(drifted && pastReach(segment)),
                              memcmp(source + start, sameRow + start, length) != 0 {
                        // Nothing held but what one view showed, or the ground where something stayed put over the
                        // content, and now something that does not stay put (the content come out from under it):
                        // taken instead, until a view backs something.
                        memcpy(target + start, source + start, length)
                        support[segment] = Self.seenOnce
                        loose[segment] = drifted ? 1 : 0
                        changed = true
                    }
                }
            }
        }
        return changed
    }

    /// A confirmed new content state also replaces its matching margins. Old votes for a carousel's
    /// previous slide must not retain strips of that slide beside the newly settled middle. A fixed
    /// overlay or sidebar at an end still does not vote: an end must either already agree or have
    /// moved with the same stable content, with plain ends continuing the adjoining content color.
    private func refreshChangedEnds(
        _ source: UnsafeRawPointer, target: UnsafeMutableRawPointer, previous: UnsafeRawPointer, sameRow: UnsafeRawPointer,
        chunk: Chunk, slot: Int
    ) {
        guard !scrollingEnds.isEmpty, scrollingEnds.allSatisfy({ part in
            if memcmp(source + part.lowerBound, target + part.lowerBound, part.count) == 0 { return true }
            guard Self.nearlyAlike(source + part.lowerBound, previous + part.lowerBound, part.count),
                  !(part.lowerBound / Self.segmentBytes...((part.upperBound - 1) / Self.segmentBytes)).contains(where: { adrift[$0] }) else { return false }
            if memcmp(source + part.lowerBound, sameRow + part.lowerBound, part.count) != 0 { return true }
            let adjacent = part.upperBound <= endBytes ? part.upperBound : part.lowerBound - 4
            return adjacent >= 0 && adjacent + 4 <= lineBytes && Lines.isPlain(source + part.lowerBound, part.count)
                && (source + part.lowerBound).load(as: UInt32.self) == (source + adjacent).load(as: UInt32.self)
        }) else { return }
        for part in scrollingEnds { memcpy(target + part.lowerBound, source + part.lowerBound, part.count) }
        let first = slot * Self.variants
        for variant in 0..<Self.variants { chunk.endCounts[first + variant] = 0 }
        chunk.endHashes[first] = endsHash(source)
        chunk.endCounts[first] = Self.stillCount
        chunk.shown[slot] = 0
    }

    /// The line's hash in each band, for finding views in the picture, after it changed: as a view's line is hashed
    /// (`Lines.hash`), which `locate` looks up among these.
    private func rehash(_ line: UnsafeMutableRawPointer, chunk: Chunk, slot: Int) {
        for (band, part) in bands.enumerated() {
            (chunk.hashes[slot * bands.count + band], chunk.plain[slot * bands.count + band]) = Lines.hash(line, band: part)
        }
        located = nil
    }

    /// Whether two lines' ends are alike.
    func endsAlike(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool {
        guard endBytes > 0 else { return true }
        return memcmp(a, b, endBytes) == 0 && memcmp(a + lineBytes - endBytes, b + lineBytes - endBytes, endBytes) == 0
    }

    /// The one color the content's last line is between its ends, outside the columns that stay put, and how many of
    /// the last lines are it, `most` at most: nil when the last line is not one color.
    func blankEnd(most: Int) -> (color: UInt32, lines: Int)? {
        guard let range, let last = line(range.upperBound - 1), let first = scrollingMiddle.first else { return nil }
        let color = last.load(fromByteOffset: first.lowerBound, as: UInt32.self)
        let straddling = straddling(bands)
        var lines = 0
        lines: while lines < most, range.upperBound - 1 - lines >= range.lowerBound {
            let index = range.upperBound - 1 - lines
            let number = Self.chunkNumber(of: index)
            guard number >= base, number - base < chunks.count, let chunk = chunks[number - base] else { break }
            let slot = index - number * Self.chunkLines
            guard chunk.states[slot] > 0 else { break }
            let line = UnsafeRawPointer(chunk.pixels.baseAddress + slot * lineBytes)
            // By the bands first, as hashed: one plain in the color says so without a look at the rest of its pixels.
            for (band, part) in bands.enumerated() {
                if chunk.plain[slot * bands.count + band], line.load(fromByteOffset: part.lowerBound * 4, as: UInt32.self) == color { continue }
                guard straddling[band], isBlank(line, color: color, besides: nil, within: part.lowerBound * 4 ..< part.upperBound * 4) else { break lines }
            }
            lines += 1
        }
        return lines > 0 ? (color, lines) : nil
    }

    /// Whether each of `bands` (pixels across a line) is partly or wholly over a column that stays put.
    func straddling(_ bands: [Range<Int>]) -> [Bool] {
        bands.map { band in
            (band.lowerBound * 4 / Self.segmentBytes ..< (band.upperBound * 4 + Self.segmentBytes - 1) / Self.segmentBytes).contains {
                $0 < stays.count && stays[$0]
            }
        }
    }

    /// Whether `line` is `color` throughout between its ends, outside the columns that stay put (and within the bytes
    /// `within`), but where it shows what `other` shows at the same place.
    func isBlank(_ line: UnsafeRawPointer, color: UInt32, besides other: UnsafeRawPointer?, within: Range<Int>? = nil) -> Bool {
        for run in scrollingMiddle {
            let bytes = within.map { run.clamped(to: $0) } ?? run
            for offset in stride(from: bytes.lowerBound, to: bytes.upperBound, by: 4) {
                let pixel = line.load(fromByteOffset: offset, as: UInt32.self)
                guard pixel == color || other?.load(fromByteOffset: offset, as: UInt32.self) == pixel else { return false }
            }
        }
        return true
    }

    /// Whether a line of `view` among `lines` says the view is where `reference` was: what it shows between the ends
    /// and outside the columns that stay put (a sidebar's text is where it was however the content moved), not
    /// plain, is where `reference` showed it, and no other line of `reference` shows it.
    func placed(_ view: Lines, by reference: Lines, within lines: Range<Int>) -> Bool {
        let parts = scrollingMiddle
        guard !parts.isEmpty else { return false }
        func hash(_ line: UnsafeRawPointer) -> UInt32? {
            let color = (line + parts[0].lowerBound).load(as: UInt32.self)
            var plain = true
            var hash: uLong = 0
            for part in parts {
                hash = crc32(hash, (line + part.lowerBound).assumingMemoryBound(to: UInt8.self), uInt(part.count))
                if plain { plain = Lines.isPlain(line + part.lowerBound, part.count) && (line + part.lowerBound).load(as: UInt32.self) == color }
            }
            return plain ? nil : UInt32(truncatingIfNeeded: hash)
        }
        var shown: [UInt32: Int] = [:]
        for line in lines {
            guard let hash = hash(reference.line(line)) else { continue }
            shown[hash] = shown[hash] == nil ? line : -1
        }
        return lines.contains { line in hash(view.line(line)).map { shown[$0] == line } ?? false }
    }

    /// Counts the ends `source`, a still view's line, shows for line `index`, when the line is there and the same
    /// between them.
    func count(_ source: UnsafeRawPointer, at index: Int) {
        let number = Self.chunkNumber(of: index)
        guard number >= base, number - base < chunks.count, let chunk = chunks[number - base] else { return }
        let slot = index - number * Self.chunkLines
        let target = chunk.pixels.baseAddress + slot * lineBytes
        guard chunk.states[slot] > 0, same(target, source) else { return }
        count(source, into: target, chunk: chunk, slot: slot, still: true)
    }

    /// Forgets the lines past `index` (before it, `towardEnd` false): what only an overscroll showed.
    func truncate(at index: Int, towardEnd: Bool) {
        guard let range else { return }
        let cut = min(max(index, range.lowerBound), range.upperBound)
        let gone = towardEnd ? cut ..< range.upperBound : range.lowerBound ..< cut
        guard !gone.isEmpty, gone.count < range.count else { return }
        for line in gone {
            let number = Self.chunkNumber(of: line)
            guard number >= base, number - base < chunks.count, let chunk = chunks[number - base] else { continue }
            chunk.states[line - number * Self.chunkLines] = 0
        }
        self.range = towardEnd ? range.lowerBound ..< gone.lowerBound : gone.upperBound ..< range.upperBound
        located = nil
    }

    /// Moves the lines in `range` into `target`, one after another, a chunk at a time, letting each chunk go once
    /// its lines are out; a line never written takes the ground. Nothing is left in the canvas after.
    func move(_ range: Range<Int>, into target: UnsafeMutableRawPointer) {
        var line = range.lowerBound
        while line < range.upperBound {
            let number = Self.chunkNumber(of: line)
            let end = min(range.upperBound, (number + 1) * Self.chunkLines)
            if number >= base, number - base < chunks.count, let chunk = chunks[number - base] {
                let slot = line - number * Self.chunkLines
                memcpy(target + (line - range.lowerBound) * lineBytes, chunk.pixels.baseAddress + slot * lineBytes, (end - line) * lineBytes)
                // A line never written takes the ground, never a clear stripe across the picture.
                if let ground {
                    for index in line..<end where chunk.states[index - number * Self.chunkLines] == 0 {
                        memcpy(target + (index - range.lowerBound) * lineBytes, ground.baseAddress, lineBytes)
                    }
                }
                chunks[number - base] = nil
            } else if let ground {
                for index in line..<end { memcpy(target + (index - range.lowerBound) * lineBytes, ground.baseAddress, lineBytes) }
            }
            line = end
        }
        chunks = []
        located = nil
        self.range = nil
    }

    func line(_ index: Int) -> UnsafeRawPointer? {
        let number = Self.chunkNumber(of: index)
        guard number >= base, number - base < chunks.count, let chunk = chunks[number - base] else { return nil }
        let slot = index - number * Self.chunkLines
        guard chunk.states[slot] > 0 else { return nil }
        return UnsafeRawPointer(chunk.pixels.baseAddress + slot * lineBytes)
    }

    /// Where `view` lies in the content, when enough of its lines that say something are there, at one offset,
    /// in most bands: its first line's position, and its lines that agree, from the first that says something
    /// to the last. In columns that stay put (a sidebar, a timeline, kept as the first view showed them), what
    /// `reference`, the last view placed, showed at the same place on screen neither votes nor need agree. A place
    /// well ahead of any other wins, or one nearly as good near `expected`; two as good, neither near, tell nothing.
    /// With the place: how many of the view's lines there agree and say something, and how many say something at all.
    func locate(_ view: Lines, reference: Lines, near expected: Int) -> (position: Int, lines: Range<Int>, agreeing: Int, saying: Int)? {
        guard let range, range.count >= 16, view.bands == bands else { return nil }
        let bandCount = bands.count
        if located?.range != range {
            // The content's lines in one run, band by band, as a view's are.
            var hashes = [UInt32](repeating: 0, count: range.count * bandCount)
            var plain = [Bool](repeating: true, count: range.count * bandCount)
            for (index, line) in range.enumerated() {
                let number = Self.chunkNumber(of: line)
                guard number >= base, number - base < chunks.count, let chunk = chunks[number - base] else { continue }
                let slot = line - number * Self.chunkLines
                guard chunk.states[slot] > 0 else { continue }
                for band in 0..<bandCount {
                    hashes[band * range.count + index] = chunk.hashes[slot * bandCount + band]
                    plain[band * range.count + index] = chunk.plain[slot * bandCount + band]
                }
            }
            let indexes = hashes.withUnsafeBufferPointer { hashBuffer in
                plain.withUnsafeBufferPointer { plainBuffer in
                    (0..<bandCount).map { band in
                        LineIndex(hashes: hashBuffer.baseAddress! + band * range.count, plain: plainBuffer.baseAddress! + band * range.count, count: range.count)
                    }
                }
            }
            located = (range, indexes, hashes, plain)
        }
        guard let located else { return nil }
        let count = view.count
        func stayed(_ band: Int, _ index: Int) -> Bool { view.hashes[band * count + index] == reference.hashes[band * count + index] }
        // Bands mostly over columns that stay put (a sidebar, a timeline): what they show where the reference did is
        // no part of the content there. Elsewhere it must agree like the rest: tiles a frame late are content.
        let staying = bands.map { band in
            let segments = band.lowerBound * 4 / Self.segmentBytes ..< max(band.lowerBound * 4 / Self.segmentBytes + 1, band.upperBound * 4 / Self.segmentBytes)
            return segments.count { $0 < stays.count && stays[$0] } * 2 >= segments.count
        }
        // Each line of the view that says something votes for where the view begins, but in columns that stay put
        // what the reference showed there too: kept as the first view showed them, it would vote for that.
        let lowest = range.lowerBound - count
        var votes = [Int32](repeating: 0, count: range.count + count)
        var cast = 0
        for band in 0..<bandCount {
            for index in 0..<count where !view.plain[band * count + index] && !(staying[band] && stayed(band, index)) {
                guard let found = located.indexes[band].line(of: view.hashes[band * count + index]) else { continue }
                votes[range.lowerBound + found - index - lowest] += 1
                cast += 1
            }
        }
        guard let most = votes.max(), most >= 12, Int(most) * 10 >= cast else { return nil }
        let expectedSlot = expected - lowest
        var best = -1
        for slot in votes.indices where votes[slot] == most && (best < 0 || abs(slot - expectedSlot) < abs(best - expectedSlot)) { best = slot }
        var elsewhere: Int32 = 0
        for slot in votes.indices where abs(slot - best) > 16 { elsewhere = max(elsewhere, votes[slot]) }
        // Content repeating down the page lines up a period off as well: near where the view should be wins.
        var near = -1
        var nearVotes: Int32 = 0
        for slot in stride(from: max(0, expectedSlot - count / 4), to: min(votes.count, expectedSlot + count / 4 + 1), by: 1) where votes[slot] > nearVotes {
            near = slot
            nearVotes = votes[slot]
        }
        let slot: Int
        if near >= 0, nearVotes >= 12, nearVotes * 2 >= most {
            slot = near
        } else if elsewhere * 3 < most * 2 {
            slot = best
        } else {
            return nil
        }
        let position = slot + lowest
        // The lines that agree in most bands where the view shows something other than the reference did there,
        // and those of them that say something; and how many of the view's lines there say something at all.
        var first: Int?
        var end = 0
        var telling = 0
        var saying = 0
        for index in 0..<count {
            let line = position + index - range.lowerBound
            guard line >= 0, line < range.count else { continue }
            var testable = 0
            var agreeing = 0
            var says = false
            var anything = false
            for band in 0..<bandCount where !(staying[band] && stayed(band, index)) {
                testable += 1
                if !view.plain[band * count + index] { anything = true }
                if located.hashes[band * range.count + line] == view.hashes[band * count + index] {
                    agreeing += 1
                    if !view.plain[band * count + index] { says = true }
                }
            }
            if anything { saying += 1 }
            guard testable > 0, agreeing * 3 >= testable * 2, says else { continue }
            if first == nil { first = index }
            end = index + 1
            telling += 1
        }
        guard let first, telling >= max(16, count / 10) else { return nil }
        return (position, first ..< end, telling, saying)
    }

    /// Whether `source` shows what line `target` holds between the ends, but where it holds the ground, where
    /// something over the content stayed put.
    private func same(_ target: UnsafeRawPointer, _ source: UnsafeRawPointer) -> Bool {
        let differing = scrollingMiddle.filter { memcmp(target + $0.lowerBound, source + $0.lowerBound, $0.count) != 0 }
        guard !differing.isEmpty else { return true }
        guard let ground else { return false }
        for run in differing {
            var start = run.lowerBound
            while start < run.upperBound {
                let end = min((start / Self.segmentBytes + 1) * Self.segmentBytes, run.upperBound)
                if memcmp(target + start, source + start, end - start) != 0, memcmp(target + start, ground.baseAddress + start, end - start) != 0 { return false }
                start = end
            }
        }
        return true
    }

    /// The hash of a line's ends, but what of them stays put.
    private func endsHash(_ line: UnsafeRawPointer) -> UInt32 {
        var hash: uLong = 0
        for part in scrollingEnds {
            hash = crc32(hash, (line + part.lowerBound).assumingMemoryBound(to: UInt8.self), uInt(part.count))
        }
        return UInt32(truncatingIfNeeded: hash)
    }

    private func count(_ source: UnsafeRawPointer, into target: UnsafeMutableRawPointer, chunk: Chunk, slot: Int, still: Bool) {
        guard endBytes > 0 else { return }
        let hash = endsHash(source)
        let first = slot * Self.variants
        let shown = Int(chunk.shown[slot])
        var variant = (0..<Self.variants).first { chunk.endCounts[first + $0] > 0 && chunk.endHashes[first + $0] == hash }
        if variant == nil {
            // A new one takes the place of the one seen least, never of the one the line holds.
            let place = (0..<Self.variants).filter { $0 != shown }.min { chunk.endCounts[first + $0] < chunk.endCounts[first + $1] } ?? 0
            chunk.endHashes[first + place] = hash
            chunk.endCounts[first + place] = 0
            variant = place
        }
        guard let variant else { return }
        if still {
            // The latest still view outweighs everything seen before it.
            let most = (0..<Self.variants).map { chunk.endCounts[first + $0] }.max() ?? 0
            chunk.endCounts[first + variant] = max(Self.stillCount, most < .max ? most + 1 : most)
        } else if chunk.endCounts[first + variant] < .max {
            chunk.endCounts[first + variant] += 1
        }
        guard variant != shown, chunk.endCounts[first + variant] > chunk.endCounts[first + shown] else { return }
        for part in scrollingEnds { memcpy(target + part.lowerBound, source + part.lowerBound, part.count) }
        chunk.shown[slot] = UInt8(variant)
    }

    private static func chunkNumber(of index: Int) -> Int {
        index >= 0 ? index / chunkLines : -((-index + chunkLines - 1) / chunkLines)
    }
}
