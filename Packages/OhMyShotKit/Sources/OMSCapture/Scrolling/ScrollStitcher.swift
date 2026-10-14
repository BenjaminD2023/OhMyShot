import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import OMSCore
import zlib

/// Puts the views of a scrolled area together into one long picture: scrolled down or up, right or left.
///
/// Each new view is compared with the last one taken in. Its lines (rows, or columns when it scrolls
/// sideways) are hashed in a few bands across the line, and every line that is not one plain color looks
/// itself up among the last view's: the offset most of them agree on is how far the content moved. The offset
/// holds when most of the lines it lines up agree in most bands, so something animating inside the view (a
/// caret, a spinner) costs it only those lines. The lines that agree are the part that scrolls; what stays
/// put before and after it is a header or a footer (a site's bar, a cookie banner), kept once: the header
/// of the view that reached furthest toward the content's start, the footer of the one that reached furthest
/// toward its end, each meeting the content where that view's part that scrolls did.
///
/// The ends of each line are left out of the hashes: overlay scroll bars come and go there. Each line keeps
/// the ends it was seen with most often, so a scroll bar's knob, which covers a line in only a view or two as
/// the line passes it, is left out of the picture. A view taken while nothing scrolls shows no overlay knob:
/// the first view's ends count for several, and the latest still view's (the knob fading once the scrolling
/// stops) for more than any seen before.
///
/// The picture is kept by where its lines are in the content, in chunks of lines, and each line in segments
/// of 8 pixels. A segment holds what the views back most: a view backs what it shows where it moved there with
/// the content, by about as far as the content moved, so the page, which moves with itself all the way across
/// the view, outweighs what is over it for a while as it passes (a post's avatar stuck while the post
/// scrolls, a chat button in a corner, a banner that pops up). On revisits, a clearer observation farther
/// from the viewport's edges takes precedence over repeated occluded views near those edges.
/// What stays where it is on screen while the
/// content moves (a sidebar, a timeline) backs nothing: a line coming into view takes the ground there, the
/// color the first view showed in that column, and the first view's lines keep it as that view showed it.
///
/// Not thread-safe: one queue adds views and reads the picture.
nonisolated public final class ScrollStitcher {
    public enum Axis: Sendable, Equatable {
        case vertical
        case horizontal
    }

    /// What adding a view did.
    public enum Step: Sendable, Equatable {
        /// The first view: the picture starts as it.
        case started
        /// Nothing scrolled: the view is the same, or what changed in it did not move.
        case unchanged
        /// The content scrolled `offset` pixels along the axis: positive when what follows came into view
        /// (scrolled down or right), negative when what goes before did.
        case scrolled(offset: Int)
        /// The view changed but lines up with nothing: scrolled too far at once, or the content changed.
        case lost
        /// The picture is as long as it may be; nothing more is taken in.
        case full
    }

    /// The views' size in pixels.
    public let width: Int
    public let height: Int
    /// The direction the content scrolls in, known from the first scroll.
    public private(set) var axis: Axis?
    /// The picture is as long as it may be: what scrolls into view now is left out.
    public private(set) var isFull = false
    /// The direction the content is being made to scroll in (Auto-scroll), before the first scroll says: the other
    /// one is never tried, so a carousel's slide cannot turn a page on its side.
    public var preferredAxis: Axis?
    /// The app is being made to scroll (Auto-scroll), on and on: only then is content creeping past its end the
    /// app pushing it on in elastic overscroll; by hand it is as likely slow scrolling through blank rows.
    public var isDriven = false
    /// Where the gesture making the app scroll lands, in fractions of the view as `movingPart` gives them: a part
    /// around it that scrolls alone, beside content that stays put, is a scroller inside the page (a code block, a
    /// map) that took the gesture, and is not taken in. Nil takes in whatever scrolls.
    public var drivenAt: CGPoint? {
        didSet { if drivenAt != oldValue { viewsSinceMoved = 0 } }
    }
    /// The part of the view that scrolled alone around `drivenAt` in the view just added, which was not taken in.
    public private(set) var innerPart: CGRect?
    /// Views added since the gesture last moved to where it lands now.
    private var viewsSinceMoved = 0
    /// The scroller inside the page last left out, where it is in the view as the page scrolls on: compared with a
    /// view from before it last scrolled, it seems to move however far it scrolled, the page around it moving otherwise.
    private var heldInner: CGRect?

    private let margin: Int
    private let colorSpace: CGColorSpace
    /// The most lines the content may hold, scrolling down or up and sideways: as many as the bytes allow at a
    /// line's size that way, and the picture's length allows with a view's worth of header and footer.
    private let maxLines: (vertical: Int, horizontal: Int)
    /// The content's lines and the gaps in them, once `takePicture()` has moved them out, for the log.
    private var taken: (lines: Int, gaps: Int)?
    /// Each direction's views, both until the first scroll says which it is.
    private var vertical: Track?
    private var horizontal: Track?
    /// Where the reference view's first line is in the content.
    private var position = 0
    private var canvas: Canvas?
    /// The lines before the part that scrolls, of the view that reached furthest toward the content's start;
    /// and the lines after it, of the view that reached furthest toward its end. Each meets the content where
    /// that view's part that scrolls did.
    private var head = Ends()
    private var tail = Ends()
    /// Where in the content the tail's first line would be: the content's end when it was kept.
    private var tailFrom = 0
    /// Where the view the head was kept from was in the content.
    private var headPosition = 0
    /// While the content may be pulled past its end (or start) in elastic overscroll: that end, whether it is
    /// springing back, where the reference view was in the content when the pull began (where it springs back to),
    /// and whether what stays put while the content scrolls went along with the pull, which makes it a pull for sure.
    /// Pulled, what comes into view past the end is kept for now, as slow scrolling through blank rows looks just the
    /// same; springing back, it goes, and nothing past the end is taken until the content is back.
    private var overscroll: (line: Int, towardEnd: Bool, springing: Bool, from: Int, along: Bool)?
    /// Views in a row that crept past the content's end while driven, where that end was before the first, and
    /// where the reference view was then, with its part that scrolls and how many bands moved with the content.
    private var creeping: (views: Int, line: Int, from: Int, band: Range<Int>?, moving: Int)?
    /// How far the bars at the view's ends reach, and in how many views in a row that scrolled they stayed put.
    private var barsSeen = (head: (views: 0, lines: Int.max), tail: (views: 0, lines: Int.max))
    private var bars: (head: Int, tail: Int) {
        (barsSeen.head.views >= 3 ? barsSeen.head.lines : 0, barsSeen.tail.views >= 3 ? barsSeen.tail.lines : 0)
    }
    /// The reference view's part that scrolls, in its own lines.
    private var band: Range<Int>?
    /// Whether the content last moved toward its start (scrolled up or left).
    private var movedTowardStart = false
    /// Since the reference view was taken in: whether a view showed its part that scrolls all the one color the
    /// picture ends in, a blank stretch taller than the view going by however far; whether a view that lined up with
    /// nothing showed what the reference does not (something that could not be placed), which a view past a blank
    /// stretch must never pass over; and that color and how many of the picture's last lines are it, once worked out.
    private var sinceReference: (blank: Bool, unplaced: Bool, end: (color: UInt32, lines: Int)?) = (false, false, nil)
    /// What the last view that lined up with nothing was found to do, for the log.
    public private(set) var lostBecause = ""

    /// - Parameters:
    ///   - width: The views' width in pixels.
    ///   - height: Their height in pixels.
    ///   - pixelsPerPoint: The display's scale, which sizes the ends of lines left out of the hashes.
    ///   - colorSpace: The views' color space.
    ///   - maxBytes: The most the picture may hold; past it, it stops growing. A gigabyte takes a capture the
    ///     width of a Retina display's window to its longest, and a 5K display's nearly.
    ///   - maxLength: The most pixels the picture may be long.
    public init(
        width: Int, height: Int, pixelsPerPoint: CGFloat, colorSpace: CGColorSpace,
        maxBytes: Int = 1 << 30, maxLength: Int = 50_000
    ) {
        self.width = max(1, width)
        self.height = max(1, height)
        // An overlay scroll bar's knob, its widest while the pointer is over it, with its edge.
        margin = Int((18 * pixelsPerPoint).rounded())
        self.colorSpace = colorSpace
        // The views' ends come on top of the content.
        maxLines = (
            max(1, min(maxLength, maxBytes / (self.width * 4)) - self.height),
            max(1, min(maxLength, maxBytes / (self.height * 4)) - self.width)
        )
    }

    /// Takes in a view: BGRA pixels, `width` × `height`, rows `bytesPerRow` apart.
    public func add(_ pixels: UnsafeRawPointer, bytesPerRow: Int) -> Step {
        innerPart = nil
        viewsSinceMoved += 1
        guard !isFull, taken == nil else { return .full }
        guard vertical != nil || horizontal != nil else {
            vertical = Track(Lines.make(pixels, bytesPerRow: bytesPerRow, width: width, height: height, turned: false, margin: margin))
            horizontal = Track(Lines.make(pixels, bytesPerRow: bytesPerRow, width: width, height: height, turned: true, margin: margin))
            return .started
        }
        var verticalReason: String?
        if axis != .horizontal, preferredAxis != .horizontal, var track = vertical {
            guard let view = track.take(pixels, bytesPerRow: bytesPerRow, width: width, height: height, turned: false, margin: margin) else { return .lost }
            var why = ""
            let reference = track.reference
            switch Lines.compare(
                view, with: reference, movingBands: track.movingBands, content: band, expected: track.lastOffset, previousVotes: track.lastVotes,
                avoiding: isDriven && drivenAt != nil ? { [unowned self] in innerScroller($0, view: view, old: reference, turned: false) != nil } : nil,
                why: &why
            ) {
            case .same:
                count(view, reference: track.reference)
                noteBlank(view, reference: track.reference)
                track.spare = view
                vertical = track
                return .unchanged
            case .scrolled(let match):
                if axis != nil, overscrolled(match, view: view, old: track.reference) {
                    track.spare = view
                    vertical = track
                    return .unchanged
                }
                if let inner = innerScroller(match, view: view, old: track.reference, turned: false) {
                    innerPart = inner.part
                    if inner.underGesture { heldInner = inner.part }
                    track.spare = view
                    vertical = track
                    return .unchanged
                }
                axis = .vertical
                horizontal = nil
                let step = accept(match, view: view, track: &track)
                vertical = track
                return step
            case .lost:
                if axis != nil, let step = pastBlank(view, track: &track) ?? relocate(view, track: &track) {
                    vertical = track
                    return step
                }
                track.spare = view
                vertical = track
                lostBecause = why
                guard axis == nil else { return .lost }
                verticalReason = why
            }
        }
        guard preferredAxis != .vertical, var track = horizontal else { return .lost }
        guard let view = track.take(pixels, bytesPerRow: bytesPerRow, width: width, height: height, turned: true, margin: margin) else { return .lost }
        var why = ""
        let reference = track.reference
        switch Lines.compare(
            view, with: reference, movingBands: track.movingBands, content: band, expected: track.lastOffset, previousVotes: track.lastVotes,
            avoiding: isDriven && drivenAt != nil ? { [unowned self] in innerScroller($0, view: view, old: reference, turned: true) != nil } : nil,
            why: &why
        ) {
        case .same:
            count(view, reference: track.reference)
            noteBlank(view, reference: track.reference)
            track.spare = view
            horizontal = track
            return .unchanged
        case .scrolled(let match):
            if axis != nil, overscrolled(match, view: view, old: track.reference) {
                track.spare = view
                horizontal = track
                return .unchanged
            }
            if let inner = innerScroller(match, view: view, old: track.reference, turned: true) {
                innerPart = inner.part
                if inner.underGesture { heldInner = inner.part }
                track.spare = view
                horizontal = track
                return .unchanged
            }
            // Before the axis is known, only the whole view moving sideways says the content scrolls sideways: a
            // carousel's slide, or a hero's, moves only some of it, and must never turn a page on its side.
            let bands = track.reference.bands.count
            if axis == nil, match.movingBands.count < max(1, bands - 1, (bands * 3 + 3) / 4) {
                track.spare = view
                horizontal = track
                lostBecause = "\(verticalReason ?? why); sideways only \(match.movingBands.count) of \(bands) bands moved"
                return .lost
            }
            axis = .horizontal
            vertical = nil
            let step = accept(match, view: view, track: &track)
            horizontal = track
            return step
        case .lost:
            if axis != nil, let step = pastBlank(view, track: &track) ?? relocate(view, track: &track) {
                horizontal = track
                return step
            }
            track.spare = view
            horizontal = track
            // Before the axis is known the vertical comparison's reason is the one that tells most.
            lostBecause = verticalReason.map { "\($0); sideways: \(why)" } ?? why
            return .lost
        }
    }

    /// The picture's size in pixels if it were made now.
    public var pictureSize: (width: Int, height: Int) {
        let length = pictureLength
        return axis == .horizontal ? (length, height) : (width, length)
    }

    /// The picture's length along the axis but for what an elastic overscroll may have pulled into view past the
    /// content's end (or start), which goes again when the content springs back: how far the capture got.
    public var settledLength: Int {
        guard let edge = overscroll, !edge.springing, let range = canvas?.range else { return pictureLength }
        return pictureLength - (edge.towardEnd ? max(0, range.upperBound - edge.line) : max(0, edge.line - range.lowerBound))
    }

    /// The content is pulled past its end (or start), as far as the views tell: elastic overscroll.
    public var isPulled: Bool { overscroll.map { !$0.springing } ?? false }

    /// Since the view last taken in as scrolled, a view showed nothing but a blank stretch going by, the one color the
    /// picture ends in: the picture cannot grow until what follows the stretch comes in.
    public var isInBlank: Bool { sinceReference.blank }

    /// The part of the view that moved with the content when it last scrolled, in fractions of the view (x across, y
    /// along the rows as they are on screen): its lines, and the bands across them that moved.
    public var movingPart: CGRect? {
        guard let band, let axis, let track = axis == .horizontal ? horizontal : vertical, !track.movingBands.isEmpty else { return nil }
        return Self.part(lines: band, bands: track.movingBands, of: track.reference, turned: axis == .horizontal)
    }

    /// `lines` of `view` across `bands`, in fractions of the view as `movingPart` gives them.
    private static func part(lines: Range<Int>, bands: [Int], of view: Lines, turned: Bool) -> CGRect {
        let count = CGFloat(view.count), length = CGFloat(view.length)
        let across = bands.map { view.bands[$0] }
        let low = CGFloat(across.map(\.lowerBound).min() ?? 0) / length, high = CGFloat(across.map(\.upperBound).max() ?? 0) / length
        let start = CGFloat(lines.lowerBound) / count, end = CGFloat(lines.upperBound) / count
        // Columns turned a quarter clockwise into lines: line 0 is the view's leftmost column, band positions run
        // from the view's bottom up.
        return turned
            ? CGRect(x: start, y: 1 - high, width: end - start, height: high - low)
            : CGRect(x: low, y: start, width: high - low, height: end - start)
    }

    /// Where `match` moves the view when that is a scroller inside the page that took the gesture making the app
    /// scroll: short of three quarters of the view along the axis (a pane nearly filling it is what there is to
    /// capture), around where the gesture lands, beside content that stayed put. Taken in, the picture would scroll
    /// that content along with the scroller, and repeat it once the page itself scrolls. Once the gesture has moved
    /// off it, its last moves may still scroll it alone for a view or two; and as the page scrolls, compared with a
    /// view from before it last scrolled, it seems to move on its own, where it was, the page around it moving
    /// otherwise.
    private func innerScroller(_ match: Lines.Match, view: Lines, old: Lines, turned: Bool) -> (part: CGRect, underGesture: Bool)? {
        guard isDriven, let point = drivenAt, !match.movingBands.isEmpty else { return nil }
        let lines = match.band
        // Between the bars the content has scrolled under (a header that stays put says nothing of a scroller).
        let top = min(bars.head, lines.lowerBound), bottom = max(view.count - bars.tail, lines.upperBound)
        guard lines.count * 4 < (bottom - top) * 3 else { return nil }
        // Blank rows beside it say nothing: a short page's content alone scrolls just the same.
        let around = Self.staysPut(view, old, lines: top ..< lines.lowerBound) || Self.staysPut(view, old, lines: lines.upperBound ..< bottom)
        if around {
            // Along the axis only: what it shows may not reach across it (code is short lines on the left).
            let part = Self.part(lines: lines, bands: match.movingBands, of: view, turned: turned)
            if turned ? (part.minX ..< part.maxX).contains(point.x) : (part.minY ..< part.maxY).contains(point.y) { return (part, true) }
        }
        // Where it was, by the lines that agree: what came into view past them reaches beyond it, as far as it
        // scrolled since that view. Alone, the page around it still, past the gesture's last moves, it is what
        // scrolls after all (a page between bars that stay put, its middle short).
        guard let held = heldInner, match.end > match.first, !around || viewsSinceMoved <= 6 else { return nil }
        let part = Self.part(lines: match.first ..< match.end, bands: match.movingBands, of: view, turned: turned)
        let (along, was) = turned ? (part.minX ..< part.maxX, held.minX ..< held.maxX) : (part.minY ..< part.maxY, held.minY ..< held.maxY)
        let common = max(0, min(along.upperBound, was.upperBound) - max(along.lowerBound, was.lowerBound))
        return common * 5 >= (along.upperBound - along.lowerBound) * 4 ? (part, false) : nil
    }

    /// Lets go of what an elastic overscroll pulled into view past the content's end (or start): the content was
    /// only pulled there, as Auto-scroll finds when it pushes on and nothing more comes. It springs back from
    /// there, and nothing past the end is taken in on the way.
    public func trimOverscroll() {
        guard let edge = overscroll, !edge.springing else { return }
        overscroll = (edge.line, edge.towardEnd, true, edge.from, edge.along)
        canvas?.truncate(at: edge.line, towardEnd: edge.towardEnd)
    }

    /// The picture's length along the axis, in pixels.
    private var pictureLength: Int {
        guard let range = canvas?.range else { return axis == .horizontal ? width : height }
        return head.lines + range.count + tail.lines
    }

    /// The picture as it stands: the header, the content, and the footer, in a copy of its own.
    public func picture() -> CGImage? {
        guard let track = axis == .horizontal ? horizontal : vertical else { return nil }
        let lines = segments(of: track.reference)
        let length = lines.reduce(0) { $0 + $1.count }
        let lineBytes = track.reference.lineBytes
        guard length > 0, let buffer = PageBuffer(byteCount: length * lineBytes) else { return nil }
        var at = 0
        for segment in lines {
            for index in 0..<segment.count {
                if let line = segment.line(index) { memcpy(buffer.baseAddress + (at + index) * lineBytes, line, lineBytes) }
            }
            at += segment.count
        }
        return Self.image(buffer, lines: length, length: track.reference.length, turned: axis == .horizontal, colorSpace: colorSpace)
    }

    /// The picture once the views are all in, as `picture()` makes it, but the content's lines move into it a chunk
    /// at a time, each chunk let go as it is emptied: a long picture never needs its memory twice. Nothing more is
    /// taken in after it (`add` answers `.full`).
    public func takePicture() -> CGImage? {
        guard let track = axis == .horizontal ? horizontal : vertical else { return nil }
        let reference = track.reference
        let lineBytes = reference.lineBytes
        let content = canvas?.range
        let length = head.lines + (content?.count ?? reference.count) + tail.lines
        defer { canvas = nil }
        guard length > 0, let buffer = PageBuffer(byteCount: length * lineBytes) else { return nil }
        var at = 0
        for index in 0..<head.lines {
            if let line = head.line(index) { memcpy(buffer.baseAddress + (at + index) * lineBytes, line, lineBytes) }
        }
        at += head.lines
        if let canvas, let content {
            taken = (content.count, canvas.gaps)
            canvas.move(content, into: buffer.baseAddress + at * lineBytes)
            at += content.count
        } else {
            taken = (reference.count, 0)
            memcpy(buffer.baseAddress + at * lineBytes, reference.line(0), reference.count * lineBytes)
            at += reference.count
        }
        for index in 0..<tail.lines {
            if let line = tail.line(index) { memcpy(buffer.baseAddress + (at + index) * lineBytes, line, lineBytes) }
        }
        return Self.image(buffer, lines: length, length: reference.length, turned: axis == .horizontal, colorSpace: colorSpace)
    }

    /// The picture where the view is, scaled to `across` pixels across the axis and at most `along` pixels along
    /// it: all of it when it fits, else as much as fits with the last view taken in at the end it moved toward
    /// (its bottom at the preview's bottom while the content scrolls down, its top at the top while it scrolls
    /// up), so what just came into view is always in the preview.
    public func preview(across: Int, along: Int) -> CGImage? {
        guard let track = axis == .horizontal ? horizontal : vertical, across > 0, along > 0 else { return nil }
        let reference = track.reference
        let scale = Double(across) / Double(reference.length)
        let lines = segments(of: reference)
        let length = lines.reduce(0) { $0 + $1.count }
        let shown = min(length, Int(Double(along) / scale))
        let height = max(1, Int((Double(shown) * scale).rounded()))
        // Drawn in line space, a line a row, then turned back for a sideways picture.
        guard let buffer = PageBuffer(byteCount: across * height * 4), let context = CGContext(
            data: buffer.baseAddress, width: across, height: height, bitsPerComponent: 8, bytesPerRow: across * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        var at = 0
        let skip = previewStart(length: length, shown: shown, reference: reference)
        for segment in lines {
            defer { at += segment.count }
            let from = max(skip - at, 0), to = min(segment.count, skip + shown - at)
            guard from < to else { continue }
            // Runs of lines that are there, each drawn as one picture of the lines' own memory.
            var start = from
            while start < to {
                guard let first = segment.line(start) else { start += 1; continue }
                var end = start + 1
                while end < to, let line = segment.line(end), line == first + (end - start) * reference.lineBytes { end += 1 }
                if let image = Self.borrowedImage(first, lines: end - start, length: reference.length, colorSpace: colorSpace) {
                    // Context space is y up: line 0 of what is shown at the top. Edges on whole pixels, so runs
                    // drawn apart meet without a seam.
                    let top = (Double(at + start - skip) * scale).rounded()
                    let bottom = (Double(at + end - skip) * scale).rounded()
                    let rect = CGRect(x: 0, y: Double(height) - bottom, width: Double(across), height: bottom - top)
                    context.draw(image, in: rect)
                }
                start = end
            }
        }
        context.flush()
        return Self.image(buffer, lines: height, length: across, turned: axis == .horizontal, colorSpace: colorSpace)
    }

    /// Where the preview's first line is in the picture: the view's moving end kept in it.
    private func previewStart(length: Int, shown: Int, reference: Lines) -> Int {
        guard let range = canvas?.range else { return 0 }
        let band = self.band ?? 0 ..< reference.count
        let viewStart = head.lines + position + band.lowerBound - range.lowerBound
        let viewEnd = head.lines + position + band.upperBound - range.lowerBound
        let start = movedTowardStart ? viewStart : viewEnd - shown
        return min(max(start, 0), length - shown)
    }

    #if DEBUG
    /// Writes the last view taken in and the last that lined up with nothing, as they were hashed, for checks.
    public func debugDump(to folder: URL) {
        guard let track = axis == .horizontal ? horizontal : vertical else { return }
        for (name, lines) in [("reference", track.reference), ("lost", track.spare)] {
            guard let lines, let image = Self.image(lines.pixels, width: lines.length, height: lines.count, colorSpace: colorSpace),
                  let destination = CGImageDestinationCreateWithURL(folder.appending(path: "dump-\(name).png") as CFURL, "public.png" as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }
    #endif

    /// The lines after the content at the picture's end: a footer, or what the view that reached furthest
    /// showed past its part that scrolls.
    var tailLines: Int { tail.lines }

    /// How the views went, for the log.
    public var summary: String {
        let content = canvas?.range?.count ?? taken?.lines ?? 0, gaps = canvas?.gaps ?? taken?.gaps ?? 0
        return "axis \(axis.map { "\($0)" } ?? "none"), head \(head.lines), content \(content), tail \(tail.lines), gaps \(gaps)\(isFull ? ", full" : "")"
    }

    // MARK: - Taking views in

    /// A view that lines up with nothing in the last one taken in, found in the picture so far instead: the last
    /// view may have caught a passing state, or the user scrolled back past it. It becomes the view the next
    /// one is lined up with; what it shows past the content's end (or before its start) is taken in as just come
    /// into view, so views found this way one after another still record what scrolls by. Found where it was: it
    /// only changed in place, and nothing scrolled. Found far from where it was or would have scrolled on to, most of
    /// what it shows must be there: a phrase or a pattern a page repeats lines up in many places, around what does not.
    private func relocate(_ view: Lines, track: inout Track) -> Step? {
        let last = track.lastOffset ?? 0
        guard let canvas, let found = canvas.locate(view, reference: track.reference, near: position + last),
              found.position == position || abs(found.position - position - last) <= max(8, abs(last) / 2) || found.agreeing * 2 >= found.saying
        else { return nil }
        let offset = found.position - position
        let old = track.reference
        position = found.position
        band = found.lines
        canvas.settleTentative(view, at: position)
        if offset != 0 { movedTowardStart = offset < 0 }
        track.spare = old
        track.reference = view
        track.movingBands = []
        track.lastVotes = nil
        sinceReference = (false, false, nil)
        guard offset != 0 else { return .unchanged }
        extend(with: view, sameRows: old)
        return .scrolled(offset: offset)
    }

    /// A view past a blank stretch of the page taller than the view, which no view can measure: since the reference
    /// view, which reached the picture's end where the picture ends in one color, views showed nothing but that color
    /// between the bars; now this one shows the stretch down to what comes in after it, which lines up with nothing
    /// (a grid of cards alike may seem to line up with the grid before the stretch, and must not). It comes in past
    /// the stretch, as much of the stretch kept as the picture or this view shows of it. Never past something a view
    /// since showed that could not be placed: that is no blank stretch going by. A view of nothing but the stretch
    /// shows nothing to line up or take in, and nothing scrolled as far as anything tells: unchanged, as it is under a
    /// header that stays put, not lost.
    private func pastBlank(_ view: Lines, track: inout Track) -> Step? {
        let reference = track.reference
        guard let canvas, let range = canvas.range, let end = pictureEnd() else { return nil }
        let band = end.band
        let top = blankTop(view, besides: reference, end: end)
        if top == band.upperBound {
            sinceReference.blank = true
            track.spare = view
            return .unchanged
        }
        // Too little of the stretch above what came in to tell it from a view that scrolled too far at once: what it
        // shows that the reference shows nowhere was not placed.
        let overlap = Lines.minimumOverlap(view.count)
        guard top - band.lowerBound >= overlap else {
            if view.lines(newIn: band, to: reference) >= 16 { sinceReference.unplaced = true }
            return nil
        }
        // Enough of what came in for the next view to line up with (a line or two is waited out), and of the stretch at
        // the picture's end.
        guard sinceReference.blank, !sinceReference.unplaced, end.lines >= overlap,
              view.lines(saying: top ..< band.upperBound, besides: reference) >= 16 else { return nil }
        // What came in follows as much of the stretch as either shows; this view's stretch overlaps the picture's, so no
        // line in between goes unwritten.
        let next = range.upperBound - end.lines + max(end.lines, top - band.lowerBound) - top
        guard next > position else { return nil }
        let grown = range.lowerBound ..< max(range.upperBound, next + band.upperBound)
        guard grown.count <= (axis == .horizontal ? maxLines.horizontal : maxLines.vertical) else {
            isFull = true
            track.spare = view
            return .full
        }
        let offset = next - position
        position = next
        canvas.settleTentative(view, at: position)
        for line in max(band.lowerBound, range.upperBound - position) ..< band.upperBound {
            canvas.write(view.line(line), at: position + line, as: .arrived(sameRow: reference.line(line), inward: nil))
        }
        movedTowardStart = false
        track.spare = reference
        track.reference = view
        track.movingBands = []
        track.lastVotes = nil
        sinceReference = (false, false, nil)
        return .scrolled(offset: offset)
    }

    /// Notes a view where nothing scrolled that shows a blank stretch going by: its part that scrolls all the one color
    /// the picture ends in.
    private func noteBlank(_ view: Lines, reference: Lines) {
        guard !sinceReference.blank, let end = pictureEnd(), blankTop(view, besides: reference, end: end) == end.band.upperBound else { return }
        sinceReference.blank = true
    }

    /// Where the reference view reached the picture's end, when the picture ends in one color between the ends of its
    /// lines, outside the columns that stay put: that color and how many of the picture's last lines are it (worked out
    /// once for the reference), the reference's part that scrolls, and its line where the picture ends.
    private func pictureEnd() -> (color: UInt32, lines: Int, band: Range<Int>, line: Int)? {
        guard axis != nil, overscroll == nil, heldInner == nil, let canvas, let range = canvas.range, let band else { return nil }
        let line = range.upperBound - position
        guard line > band.lowerBound, line <= band.upperBound else { return nil }
        if sinceReference.end == nil { sinceReference.end = canvas.blankEnd(most: line - band.lowerBound) ?? (0, 0) }
        guard let found = sinceReference.end, found.lines > 0 else { return nil }
        return (found.color, found.lines, band, line)
    }

    /// The first line of `view`'s part that scrolls, from its start, that is not the color the picture ends in throughout
    /// between its ends, outside the columns that stay put; on the lines where the picture's end showed that color, what
    /// `other` shows at the same place too (a button fixed on screen) aside. The part's end when there is none.
    private func blankTop(_ view: Lines, besides other: Lines, end: (color: UInt32, lines: Int, band: Range<Int>, line: Int)) -> Int {
        guard let canvas else { return end.band.lowerBound }
        // Above where the picture's end is that color, the reference showed the content before the stretch: what stays
        // where it showed it is that content, not something fixed on screen.
        let fixed = end.line - end.lines
        let straddling = canvas.straddling(view.bands)
        var line = end.band.lowerBound
        while line < end.band.upperBound, isBlank(view, line: line, color: end.color, besides: line >= fixed ? other : nil, straddling: straddling) {
            line += 1
        }
        return line
    }

    /// Whether line `index` of `view` is `color` throughout between its ends, outside the columns that stay put, but where
    /// it shows what `other` shows at the same place. `straddling`: which bands are partly over such a column.
    private func isBlank(_ view: Lines, line index: Int, color: UInt32, besides other: Lines?, straddling: [Bool]) -> Bool {
        guard let canvas else { return false }
        // By the bands' hashes: one plain in the color, or alike in both views, says so without a look at the pixels.
        for (band, part) in view.bands.enumerated() {
            let slot = band * view.count + index
            if view.plain[slot], view.line(index).load(fromByteOffset: part.lowerBound * 4, as: UInt32.self) == color { continue }
            if let other, view.hashes[slot] == other.hashes[slot] { continue }
            // Partly over a column that stays put: the pixels outside it tell.
            guard straddling[band], canvas.isBlank(
                view.line(index), color: color, besides: other.map { UnsafeRawPointer($0.line(index)) }, within: part.lowerBound * 4 ..< part.upperBound * 4
            ) else { return false }
        }
        return true
    }

    /// Takes in what `view`, placed at `position`, shows past the content's end (or before its start), but what the
    /// bar at that end covers, as just come into view.
    private func extend(with view: Lines, sameRows old: Lines) {
        guard let canvas, let range = canvas.range else { return }
        let count = view.count
        let footer = min(tail.lines, count / 3)
        let header = min(head.lines, count / 3)
        if position + count - footer > range.upperBound {
            for line in max(range.upperBound - position, header) ..< count - footer {
                canvas.write(view.line(line), at: position + line, as: .arrived(sameRow: old.line(line), inward: nil))
            }
        }
        if position + header < range.lowerBound {
            for line in header ..< min(range.lowerBound - position, count - footer) {
                canvas.write(view.line(line), at: position + line, as: .arrived(sameRow: old.line(line), inward: nil))
            }
        }
    }

    /// Whether `line` of `view` is one color between its ends but for what `old` showed there too (a button fixed
    /// on screen): nothing on it that scrolls.
    private static func isBlank(_ view: Lines, line: Int, besides old: Lines) -> Bool {
        let pixels = UnsafeRawPointer(view.line(line)).assumingMemoryBound(to: UInt32.self)
        let same = UnsafeRawPointer(old.line(line)).assumingMemoryBound(to: UInt32.self)
        let range = view.inset ..< view.length - view.inset
        guard let color = range.first.map({ pixels[$0] }) else { return true }
        return range.allSatisfy { pixels[$0] == color || pixels[$0] == same[$0] }
    }

    /// Whether `lines` of `view` say something and stayed where `old` showed them: a bar the content scrolls under.
    private static func staysPut(_ view: Lines, _ old: Lines, lines: Range<Int>) -> Bool {
        var telling = 0
        var kept = 0
        for band in 0..<view.bands.count {
            for index in lines where !view.plain[band * view.count + index] {
                telling += 1
                if view.hashes[band * view.count + index] == old.hashes[band * view.count + index] { kept += 1 }
            }
        }
        return telling >= 8 && kept * 5 >= telling * 4
    }

    /// Whether the bars at the view's ends, which stayed put while the content scrolled, moved with it this time:
    /// the whole view pulled past the content's end (or start) and springing back, elastic overscroll, which shows
    /// nothing new and must not stretch the picture.
    private func overscrolled(_ match: Lines.Match, view: Lines, old: Lines) -> Bool {
        let count = view.count
        let offset = match.offset
        // Pulled past the end the content creeps a pixel or so at a time; a header hiding as the page scrolls down
        // moves with it as far as it scrolls.
        guard abs(offset) <= 3 || overscroll != nil else { return false }
        let ends = [0 ..< min(bars.head, count / 4), max(0, count - min(bars.tail, count / 4)) ..< count]
        for rows in ends where rows.count >= 8 {
            var moved = 0
            var stayed = 0
            for band in 0..<view.bands.count {
                for index in rows where !view.plain[band * count + index] {
                    let target = index + offset
                    guard target >= 0, target < count else { continue }
                    let hash = view.hashes[band * count + index]
                    let carried = hash == old.hashes[band * count + target]
                    let kept = hash == old.hashes[band * count + index]
                    // Pulled past the end, everything moves together: what stayed, or changed otherwise (a button
                    // fixed beside content that scrolled), says this is no bar pulled along.
                    if carried, !kept { moved += 1 } else if !carried { stayed += 1 }
                }
            }
            if moved >= 8, moved > stayed * 4 { return true }
        }
        return false
    }

    /// A view where nothing scrolled still counts for the ends of the lines it shows, where they are: those whose
    /// ends changed since `reference`, the last view that scrolled (an overlay knob fading once the scrolling stops).
    /// Only where a line of what scrolls tells it did not scroll: over rows alike at any offset (a sheet's empty
    /// cells) a view that scrolled shows between the ends what the last one did, and the ends it shows are other rows'.
    private func count(_ view: Lines, reference: Lines) {
        guard let canvas, let band else { return }
        let changed = band.filter { !canvas.endsAlike(view.line($0), reference.line($0)) }
        guard !changed.isEmpty, canvas.placed(view, by: reference, within: band) else { return }
        for line in changed {
            canvas.count(view.line(line), at: position + line)
        }
    }

    /// Takes in a view that scrolled: the content it confirms and the lines it brought into view. When those
    /// would make the picture longer than its limit, nothing is taken and the picture stays as it was.
    private func accept(_ match: Lines.Match, view: Lines, track: inout Track) -> Step {
        let old = track.reference
        let arrived = match.arrived
        let band = match.band
        let next = position + match.offset
        if let range = canvas?.range {
            let grown = min(range.lowerBound, next + band.lowerBound) ..< max(range.upperBound, next + band.upperBound)
            guard grown.count <= (axis == .horizontal ? maxLines.horizontal : maxLines.vertical) else {
                isFull = true
                track.spare = view
                return .full
            }
        }
        if canvas == nil {
            // The first scroll: the first view's part that scrolls starts the content, between its ends. What
            // stays put stays where it is, so that part is where this view's is.
            let canvas = Canvas(lineBytes: old.lineBytes, endBytes: old.inset * 4, bands: old.bands)
            self.canvas = canvas
            canvas.takeGround(from: old, lines: band)
            // A scroller inside the page left out since: this view shows it as it was left, not that one.
            let held = heldInner.map { held in
                let along = axis == .horizontal || preferredAxis == .horizontal ? held.minX ..< held.maxX : held.minY ..< held.maxY
                return Int((along.lowerBound * CGFloat(old.count)).rounded(.down)) ..< Int((along.upperBound * CGFloat(old.count)).rounded(.up))
            }
            for line in band where !(held?.contains(line) == true && band.contains(line - match.offset)) {
                canvas.write(old.line(line), at: line, as: .first, still: true,
                    quality: UInt8(clamping: min(line - band.lowerBound, band.upperBound - 1 - line) + 1))
            }
            head.keep(old, lines: 0 ..< band.lowerBound)
            headPosition = 0
            tail.keep(old, lines: band.upperBound ..< old.count)
            tailFrom = band.upperBound
        }
        guard let canvas, let span = canvas.range else { return .lost }
        // Elastic overscroll: the content creeps a pixel or so past its end (or start), what comes into view one plain
        // color, the page's background pulled out; then springs back. None of it is content.
        let blank = !arrived.isEmpty && arrived.allSatisfy { Self.isBlank(view, line: $0, besides: old) }
        let pastEnd = match.offset > 0 ? next + band.upperBound > span.upperBound : next + band.lowerBound < span.lowerBound
        // What stays put while the content scrolls (a header, the columns either side of it) goes along with it only
        // when the whole view is pulled: since before it crept, the part that scrolls starts nearer the view's start
        // (its end, pulled past the start), or more of the line moves with the content than did (as far as that is known).
        let start = creeping.map { ($0.band, $0.moving) } ?? (self.band, track.movingBands.count)
        let along = start.1 > 0 && match.movingBands.count > start.1
            || start.0.map { match.offset > 0 ? band.lowerBound < $0.lowerBound : band.upperBound > $0.upperBound } == true
        // Beside what stays put to the view's end (a rule down a column, a button fixed on screen), what the pull brings
        // into view lines up with nothing: the part that scrolls ends where the content does and draws back from the
        // view's end as far as it creeps. Slowly scrolling on through blank rows beside them looks just the same, but
        // for what goes along.
        let drawnBack = along && self.band.map { last in
            match.offset > 0
                ? band.upperBound < last.upperBound && next + band.upperBound + margin >= span.upperBound
                : band.lowerBound > last.lowerBound && next + band.lowerBound - margin <= span.lowerBound
        } == true
        // Pushed on, it creeps view after view: two in a row tell it from a slow step through blank rows.
        let creeps = isDriven && abs(match.offset) <= 3 && blank && (pastEnd || drawnBack)
        if creeps {
            creeping = (
                views: (creeping?.views ?? 0) + 1, line: creeping?.line ?? (match.offset > 0 ? span.upperBound : span.lowerBound),
                from: creeping?.from ?? position, band: start.0, moving: start.1
            )
        } else {
            creeping = nil
        }
        if let edge = overscroll {
            let backward = edge.towardEnd ? match.offset < 0 : match.offset > 0
            // Back at the end. Pulled along, back where the view was when the pull began, not where its part that
            // scrolls ends (beside a sidebar that part ends at the content's end, pulled out or not, long before the
            // content is back); and well past it, as springing back ends a pixel either side of it: scrolled back for real.
            let back = edge.along
                ? edge.towardEnd ? next <= edge.from - margin : next >= edge.from + margin
                : edge.towardEnd ? next + band.upperBound <= edge.line : next + band.lowerBound >= edge.line
            if backward, !edge.springing {
                // Springing back: what only the pull showed goes again.
                trimOverscroll()
                if back { overscroll = nil }
            } else if !creeps, back || !backward && !blank {
                // Back at the end; or something come into view past it: it scrolls on for real (slowly, through
                // blank rows), and what came before it stays. Still pulled on, a view that lags behind the pull
                // shows only more of the background.
                overscroll = nil
            }
        } else if let creeping, creeping.views >= 2 {
            overscroll = (creeping.line, match.offset > 0, false, creeping.from, along)
        }
        // Whether line `index` of the content lies past the end the content is springing back to.
        func pulledOut(_ index: Int) -> Bool {
            guard let edge = overscroll, edge.springing else { return false }
            return edge.towardEnd ? index >= edge.line : index < edge.line
        }
        guard let before = canvas.range else { return .lost }
        // Pulled on with what stays put otherwise, or springing back from such a pull, the view shows what the views
        // before it did, a few lines on, and what the pull brought into view; and bars and sidebars moving along would
        // say they scroll. It is placed, for the next view to line up with, and only what it shows past the content's
        // end is taken in; but for the ends of the lines it shows as the content has them, which count as a still
        // view's (an overlay knob gone as the pull began).
        let springsBack = overscroll.map { $0.along && $0.springing && ($0.towardEnd ? match.offset < 0 : match.offset > 0) } == true
        if creeps && along || springsBack {
            position = next
            for line in match.from..<match.to { canvas.count(view.line(line), at: position + line) }
            canvas.beginView(travel: abs(match.offset), lines: position + match.from ..< position + match.to)
            for line in arrived where !before.contains(position + line) && !pulledOut(position + line) {
                let inward = line - match.offset
                canvas.write(
                    view.line(line), at: position + line,
                    as: .arrived(sameRow: old.line(line), inward: inward >= 0 && inward < view.count ? view.line(inward) : nil)
                )
            }
            canvas.endView(fewestLines: 3 * margin)
            return place(match, view: view, old: old, band: band, track: &track)
        }
        canvas.noteColumns(new: view, old: old, offset: match.offset, lines: match.first ..< match.end, at: next)
        position = next
        // The lines both views show back, segment by segment, what moved with the content; what just came into
        // view is taken in but for what stays where it is on screen. A sidebar that never moves and an avatar
        // stuck while its post scrolls back nothing, so they never spread down the picture.
        canvas.settleTentative(view, at: position)
        canvas.beginView(travel: abs(match.offset), lines: position + match.from ..< position + match.to)
        let rows = (match.from..<match.to).filter { !pulledOut(position + $0) }
        canvas.noteChanges(view: view, old: old, offset: match.offset, rows: rows, at: position)
        canvas.noteDrifted(view: view, old: old, offset: match.offset, rows: rows, at: position)
        for line in match.from..<match.to where !pulledOut(position + line) {
            let confirmed = line >= match.first && line < match.end
            let atEdge = line - band.lowerBound < margin || band.upperBound - 1 - line < margin
            canvas.write(
                view.line(line), at: position + line,
                as: .agreeing(
                    previous: old.line(line + match.offset), sameRow: old.line(line), formerRow: view.line(line + match.offset),
                    confirmed: confirmed, atEdge: atEdge, belowStart: line - band.lowerBound < 3 * margin
                ), quality: UInt8(clamping: min(line - band.lowerBound, band.upperBound - 1 - line) + 1)
            )
        }
        for line in arrived where !pulledOut(position + line) {
            let inward = line - match.offset
            canvas.write(
                view.line(line), at: position + line,
                as: .arrived(sameRow: old.line(line), inward: inward >= 0 && inward < view.count ? view.line(inward) : nil)
            )
        }
        // What the view shows between the content's end and where its lines that agree begin (or, scrolling back,
        // between where they end and the content's start) followed something that did not line up: a video playing,
        // views found in the picture. It is taken in as just come into view, never left a hole.
        let bar = min(self.band?.lowerBound ?? 0, view.count / 3)
        if match.offset > 0, position + match.from > before.upperBound {
            for line in stride(from: max(before.upperBound - position, bar), to: match.from, by: 1) where !pulledOut(position + line) {
                canvas.write(view.line(line), at: position + line, as: .arrived(sameRow: old.line(line), inward: nil))
            }
        } else if match.offset < 0, position + match.to < before.lowerBound {
            for line in stride(from: match.to, to: min(before.lowerBound - position, view.count), by: 1) where !pulledOut(position + line) {
                canvas.write(view.line(line), at: position + line, as: .arrived(sameRow: old.line(line), inward: nil))
            }
        }
        canvas.endView(fewestLines: 3 * margin)
        canvas.writeRestless(view, band: band, at: position, inset: margin)
        // A view reaching as far as the content does keeps its ends too: when its part that scrolls was cut
        // short by plain lines, what it shows past that part still follows the content.
        if overscroll?.springing != true {
            if position + band.lowerBound <= before.lowerBound { keepHead(view, lines: 0 ..< band.lowerBound) }
            if let end = canvas.range?.upperBound {
                // The content grown into what the tail held: those lines are the content's now (and cut short, the
                // content has the tail follow it).
                if end > tailFrom { tail.dropFirst(end - tailFrom) }
                tailFrom = end
                // A view reaching as far as the picture does keeps what it shows past the content: past its part
                // that scrolls, or past where earlier views took the content to when that part fell short of it
                // (something playing at the page's end, a GIF or a ticker, that no two views agree on), unless all
                // it showed further is one color (the page's background pulled a pixel or two into view at its end).
                if position + view.count >= end + tail.lines {
                    let from = min(max(band.upperBound, end - position), view.count)
                    let further = max(from, end + tail.lines - position) ..< view.count
                    let says = further.contains { line in view.bands.indices.contains { !view.plain[$0 * view.count + line] } }
                    if position + band.upperBound >= end || says {
                        tail.keep(view, lines: from ..< view.count)
                    }
                }
            }
        }
        // A bar is what several views in a row showed staying put, as tall each time, while the content scrolled
        // under it; tiles a frame late stay put too, for a view or two, shrinking as they catch up.
        func seen(_ lines: Int, _ before: (views: Int, lines: Int)) -> (views: Int, lines: Int) {
            guard lines > 0 else { return (0, .max) }
            return abs(lines - before.lines) <= 2 ? (before.views + 1, min(before.lines, lines)) : (1, lines)
        }
        barsSeen = (
            seen(Self.staysPut(view, old, lines: 0 ..< band.lowerBound) ? band.lowerBound : 0, barsSeen.head),
            seen(Self.staysPut(view, old, lines: band.upperBound ..< view.count) ? view.count - band.upperBound : 0, barsSeen.tail)
        )
        return place(match, view: view, old: old, band: band, track: &track)
    }

    /// Makes `view`, whose part that scrolls is `band`, the reference the next view lines up with: the content moved
    /// `match.offset` lines from `old`.
    private func place(_ match: Lines.Match, view: Lines, old: Lines, band: Range<Int>, track: inout Track) -> Step {
        self.band = band
        // The scroller left out moves on with the page; the gesture's last moves may still scroll it a little.
        if let held = heldInner {
            let by = CGFloat(match.offset) / CGFloat(view.count)
            let moved = axis == .horizontal ? held.offsetBy(dx: -by, dy: 0) : held.offsetBy(dx: 0, dy: -by)
            heldInner = moved.intersects(CGRect(x: 0, y: 0, width: 1, height: 1)) ? moved : nil
        }
        movedTowardStart = match.offset < 0
        track.spare = old
        track.reference = view
        track.movingBands = match.movingBands
        track.lastOffset = match.offset
        track.lastVotes = match.votes
        sinceReference = (false, false, nil)
        return .scrolled(offset: match.offset)
    }

    /// Makes `view`'s `lines` before its part that scrolls the head. The old head's lines below them showed content no
    /// view since showed (a hero still loading when the first scroll came, a bar that turned out shorter): they go
    /// into the content first, where nothing else was written, so the picture's top keeps them.
    private func keepHead(_ view: Lines, lines: Range<Int>) {
        if let canvas, head.lines > lines.upperBound {
            for index in lines.upperBound ..< head.lines {
                if let line = head.line(index) { canvas.write(line, at: headPosition + index, as: .recovered) }
            }
        }
        head.keep(view, lines: lines)
        headPosition = position
    }

    /// The picture's lines in order: head, content, tail.
    private func segments(of reference: Lines) -> [Segment] {
        guard let canvas, let range = canvas.range else {
            return [Segment(count: reference.count) { UnsafeRawPointer(reference.line($0)) }]
        }
        let head = self.head, tail = self.tail
        return [
            Segment(count: head.lines) { head.line($0) },
            Segment(count: range.count) { canvas.line(range.lowerBound + $0) },
            Segment(count: tail.lines) { tail.line($0) },
        ]
    }

    private struct Segment {
        let count: Int
        let line: (Int) -> UnsafeRawPointer?
    }

    /// A picture of `lines` lines of `length` pixels in `buffer`, which it keeps alive: as they are, or, for
    /// columns that were turned a quarter clockwise into lines, turned back.
    private static func image(_ buffer: PageBuffer, lines: Int, length: Int, turned: Bool, colorSpace: CGColorSpace) -> CGImage? {
        guard turned else { return image(buffer, width: length, height: lines, colorSpace: colorSpace) }
        guard let back = PageBuffer(byteCount: lines * length * 4) else { return nil }
        var from = vImage_Buffer(data: buffer.baseAddress, height: vImagePixelCount(lines), width: vImagePixelCount(length), rowBytes: length * 4)
        var to = vImage_Buffer(data: back.baseAddress, height: vImagePixelCount(length), width: vImagePixelCount(lines), rowBytes: lines * 4)
        var clear: [UInt8] = [0, 0, 0, 0]
        vImageRotate90_ARGB8888(&from, &to, UInt8(kRotate90DegreesCounterClockwise), &clear, vImage_Flags(kvImageNoFlags))
        return image(back, width: lines, height: length, colorSpace: colorSpace)
    }

    /// A picture of the pixels in `buffer`, which it keeps alive.
    private static func image(_ buffer: PageBuffer, width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage? {
        let retained = Unmanaged.passRetained(buffer)
        guard let provider = CGDataProvider(
            dataInfo: retained.toOpaque(), data: buffer.baseAddress, size: width * height * 4,
            releaseData: { info, _, _ in
                if let info { Unmanaged<PageBuffer>.fromOpaque(info).release() }
            }
        ) else {
            retained.release()
            return nil
        }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// A picture of `lines` lines at `base`, which must outlive drawing it.
    private static func borrowedImage(_ base: UnsafeRawPointer, lines: Int, length: Int, colorSpace: CGColorSpace) -> CGImage? {
        guard let provider = CGDataProvider(dataInfo: nil, data: base, size: lines * length * 4, releaseData: { _, _, _ in }) else { return nil }
        return CGImage(
            width: length, height: lines, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: length * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

// MARK: - Views in line space

/// Lines kept from one view: the part before or after what scrolls.
nonisolated private struct Ends {
    private var buffer: PageBuffer?
    private var lineBytes = 0
    /// The buffer's first line that is still kept.
    private var first = 0
    private(set) var lines = 0

    mutating func keep(_ view: Lines, lines range: Range<Int>) {
        lineBytes = view.lineBytes
        guard !range.isEmpty, let buffer = PageBuffer(byteCount: range.count * view.lineBytes) else {
            buffer = nil
            lines = 0
            return
        }
        memcpy(buffer.baseAddress, view.line(range.lowerBound), range.count * view.lineBytes)
        self.buffer = buffer
        first = 0
        lines = range.count
    }

    func line(_ index: Int) -> UnsafeRawPointer? {
        buffer.map { UnsafeRawPointer($0.baseAddress + (first + index) * lineBytes) }
    }

    /// Lets go of the first `count` lines (as many as there are at most).
    mutating func dropFirst(_ count: Int) {
        let dropped = min(max(0, count), lines)
        first += dropped
        lines -= dropped
        if lines == 0 { buffer = nil; first = 0 }
    }
}

/// One direction's last view taken in, and a buffer for the next.
nonisolated private struct Track {
    var reference: Lines
    var spare: Lines?
    /// Bands known to have moved together in the last accepted view.
    var movingBands: [Int] = []
    /// How far the content moved when the last view was accepted.
    var lastOffset: Int?
    /// How many line parts found in the view before voted for that offset: a view where far fewer find themselves at
    /// any offset shows mostly something else.
    var lastVotes: Int?

    init?(_ reference: Lines?) {
        guard let reference else { return nil }
        self.reference = reference
    }

    /// The next view in this direction, in the spare buffer when there is one; nil when there is no memory
    /// for it.
    mutating func take(_ pixels: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int, turned: Bool, margin: Int) -> Lines? {
        guard let view = spare ?? Lines(count: reference.count, length: reference.length, margin: margin) else { return nil }
        spare = nil
        view.fill(pixels, bytesPerRow: bytesPerRow, width: width, height: height, turned: turned)
        return view
    }
}

/// A view in line space: its lines along the axis (rows, or columns turned a quarter clockwise), each `length`
/// BGRA pixels, packed; hashed in bands across the line.
nonisolated final class Lines {
    struct Match: Equatable {
        /// How far the content moved: line `i` of the new view is line `i + offset` of the old.
        var offset: Int
        /// The new view's lines that agree with the old one's, from the first that says something to the last:
        /// the part that surely scrolls.
        var first: Int
        var end: Int
        /// The same, reaching on through the plain lines that agree next to it: blank content, most likely,
        /// though a plain part of a bar would agree as well.
        var from: Int
        var to: Int
        var movingBands: [Int]
        /// How many line parts voted for the offset.
        var votes = 0

        /// The lines that came into view: after those that agree, or before them scrolling back.
        var arrived: Range<Int> { offset > 0 ? to ..< to + offset : from + offset ..< from }
        /// The view's part that scrolls: what agrees, and what came into view before or after it.
        var band: Range<Int> { min(arrived.lowerBound, from) ..< max(arrived.upperBound, to) }
    }

    enum Comparison: Equatable {
        case same
        case scrolled(Match)
        case lost
    }

    let count: Int
    let length: Int
    let bands: [Range<Int>]
    /// The pixels at each end of a line left out of the bands.
    let inset: Int
    let pixels: PageBuffer
    /// Each band's hash of each line's part: `hashes[band * count + line]`.
    let hashes: UnsafeMutablePointer<UInt32>
    /// Whether that part is one color throughout: it says nothing about where it is.
    let plain: UnsafeMutablePointer<Bool>
    /// Each band's lines by hash, made when first asked for.
    private var indexes: [LineIndex]?
    /// Whether each line is what the buffer held before the last fill, its hashes as they were; and whether there
    /// was a fill before.
    private let kept: UnsafeMutablePointer<Bool>
    private var filled = false

    var lineBytes: Int { length * 4 }

    init?(count: Int, length: Int, margin: Int) {
        guard count > 0, length > 0, let pixels = PageBuffer(byteCount: count * length * 4) else { return nil }
        self.count = count
        self.length = length
        self.pixels = pixels
        inset = Self.inset(length: length, margin: margin)
        bands = Self.bands(length: length, margin: margin)
        hashes = .allocate(capacity: bands.count * count)
        plain = .allocate(capacity: bands.count * count)
        kept = .allocate(capacity: count)
    }

    deinit {
        hashes.deallocate()
        plain.deallocate()
        kept.deallocate()
    }

    static func make(_ pixels: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int, turned: Bool, margin: Int) -> Lines? {
        guard let lines = Lines(count: turned ? width : height, length: turned ? height : width, margin: margin) else { return nil }
        lines.fill(pixels, bytesPerRow: bytesPerRow, width: width, height: height, turned: turned)
        return lines
    }

    /// The pixels left out at each end of a line: `margin`, where there is room.
    static func inset(length: Int, margin: Int) -> Int {
        length - 2 * margin >= 32 ? margin : 0
    }

    /// The parts of a line hashed apart: up to six, leaving out `margin` pixels at each end where there is room.
    static func bands(length: Int, margin: Int) -> [Range<Int>] {
        let inset = inset(length: length, margin: margin)
        let usable = length - 2 * inset
        let number = max(1, min(6, usable / 160))
        return (0..<number).map { band in
            inset + usable * band / number ..< inset + usable * (band + 1) / number
        }
    }

    func line(_ index: Int) -> UnsafeMutableRawPointer {
        pixels.baseAddress + index * lineBytes
    }

    /// Takes a view of `width` × `height` pixels as these lines: its rows, or its columns turned a quarter
    /// clockwise (each column then reads from the bottom up).
    func fill(_ source: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int, turned: Bool) {
        if turned {
            var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
            var to = vImage_Buffer(data: pixels.baseAddress, height: vImagePixelCount(count), width: vImagePixelCount(length), rowBytes: lineBytes)
            var clear: [UInt8] = [0, 0, 0, 0]
            vImageRotate90_ARGB8888(&from, &to, UInt8(kRotate90DegreesClockwise), &clear, vImage_Flags(kvImageNoFlags))
            kept.update(repeating: false, count: count)
        } else {
            // A line the same as the buffer held keeps its hashes: a view where only a little changed since (a
            // spinner, a video) costs a comparison, not a copy and a hash.
            for row in 0..<count {
                let from = source + row * bytesPerRow
                kept[row] = filled && memcmp(line(row), from, lineBytes) == 0
                if !kept[row] { memcpy(line(row), from, lineBytes) }
            }
        }
        filled = true
        for (band, range) in bands.enumerated() {
            let bytes = range.count * 4
            for index in 0..<count where !kept[index] {
                let start = line(index) + range.lowerBound * 4
                hashes[band * count + index] = UInt32(truncatingIfNeeded: crc32(0, start.assumingMemoryBound(to: UInt8.self), uInt(bytes)))
                plain[band * count + index] = bytes <= 4 || memcmp(start, start + 4, bytes - 4) == 0
            }
        }
        indexes = nil
    }

    /// The line of `band` with `hash`, when exactly one line that is not plain has it.
    func line(band: Int, hash: UInt32) -> Int? {
        if indexes == nil { indexes = makeIndexes() }
        return indexes?[band].line(of: hash)
    }

    /// Whether a line of `band` that is not plain has `hash`, one line or several.
    func holds(band: Int, hash: UInt32) -> Bool {
        if indexes == nil { indexes = makeIndexes() }
        return indexes?[band].holds(hash) ?? false
    }

    private func makeIndexes() -> [LineIndex] {
        bands.indices.map { band in LineIndex(hashes: hashes + band * count, plain: plain + band * count, count: count) }
    }

    /// How many of `lines` show something in a band that `other` does not show at the same place: not one color, nor
    /// what stayed put.
    func lines(saying lines: Range<Int>, besides other: Lines) -> Int {
        lines.count { line in
            bands.indices.contains { band in
                let slot = band * count + line
                return !plain[slot] && hashes[slot] != other.hashes[slot]
            }
        }
    }

    /// How many of `lines` show something in a band that `other` shows nowhere.
    func lines(newIn lines: Range<Int>, to other: Lines) -> Int {
        lines.count { line in
            bands.indices.contains { band in
                let slot = band * count + line
                return !plain[slot] && hashes[slot] != other.hashes[slot] && !other.holds(band: band, hash: hashes[slot])
            }
        }
    }

    /// How a new view lines up with an old one of the same size; `why` says what was found when it lines up
    /// with nothing, for the log. `expected`: how far the content moved the last time, which an offset nearly as
    /// good as the best wins with (content repeating down the page lines up a period off as well); `previousVotes`:
    /// how many line parts voted for it.
    static func compare(
        _ new: Lines, with old: Lines, movingBands: [Int] = [], content: Range<Int>? = nil, expected: Int? = nil,
        previousVotes: Int? = nil, avoiding: ((Match) -> Bool)? = nil, why: inout String
    ) -> Comparison {
        let count = new.count
        let bandCount = new.bands.count
        if memcmp(new.hashes, old.hashes, bandCount * count * 4) == 0 { return .same }
        // Each line that is not plain votes for the offset it is found at.
        let reach = count - minimumOverlap(count)
        guard reach > 0 else { return still(new, old, offset: 0) ? .same : .lost }
        var votes = [Int32](repeating: 0, count: 2 * count + 1)
        // Votes for moving at all: lines that stayed put (bars, a sidebar) say nothing about how far.
        var moved = 0
        for band in 0..<bandCount {
            for index in 0..<count where !new.plain[band * count + index] {
                guard let found = old.line(band: band, hash: new.hashes[band * count + index]) else { continue }
                votes[found - index + count] += 1
                if found != index { moved += 1 }
            }
        }
        var best = 0
        var most: Int32 = 0
        for offset in -reach...reach where offset != 0 && votes[offset + count] > most {
            best = offset
            most = votes[offset + count]
        }
        // Far fewer line parts find themselves at any offset than did when the content last scrolled: the view shows
        // mostly something else, jumped further than the view or changed.
        let collapsed = previousVotes.map { $0 >= 64 && Int(most) * 8 < $0 } ?? false
        // The offsets worth verifying: the best voted; a runner-up nearly as well voted (a sidebar that starts to
        // stick moves otherwise than the page, and can outvote it); and the voted one nearest the last offset.
        var candidates: [Int] = []
        if best != 0, most >= 6, Int(most) * 10 >= moved {
            candidates.append(best)
            var runnerUp = 0
            var second: Int32 = 0
            for offset in -reach...reach where offset != 0 && abs(offset - best) > 8 && votes[offset + count] > second {
                runnerUp = offset
                second = votes[offset + count]
            }
            if second >= 6, second * 2 >= most { candidates.append(runnerUp) }
            if let expected, expected != 0, abs(expected) <= reach {
                let window = max(8, abs(expected) / 2)
                var near = 0
                var nearVotes: Int32 = 0
                for offset in max(-reach, expected - window)...min(reach, expected + window) where offset != 0 && votes[offset + count] > nearVotes {
                    near = offset
                    nearVotes = votes[offset + count]
                }
                if nearVotes >= 6, nearVotes * 4 >= most, !candidates.contains(where: { abs($0 - near) <= 2 }) { candidates.append(near) }
            }
        }
        var held: [(match: Match, score: Int)] = []
        var failure: String?
        var behind: String?
        for candidate in candidates {
            switch verify(new, old, offset: candidate, previouslyMoving: movingBands, content: content, expected: expected, collapsed: collapsed) {
            case .holds(let match, let score): held.append((match, score))
            case .failed(let reason): failure = failure ?? "offset \(candidate) \(reason)"
            case .behind(let reason): behind = behind ?? "offset \(candidate) \(reason)"
            case .unmoved: break
            }
        }
        // Nothing voted for (content repeating down the view, a grid of cards alike, leaves no line unique): offsets
        // near the last one are tried as they are, nearest first.
        if held.isEmpty, failure == nil, behind == nil, let expected, expected != 0, most < 6 {
            let window = max(4, abs(expected) / 4)
            for distance in 0...window {
                for offset in distance == 0 ? [expected] : [expected - distance, expected + distance] where offset != 0 && abs(offset) <= reach {
                    if case .holds(var match, _) = verify(
                        new, old, offset: offset, previouslyMoving: movingBands, content: content, expected: expected, collapsed: collapsed
                    ) {
                        match.votes = Int(votes[offset + count])
                        return .scrolled(match)
                    }
                }
            }
        }
        // A scroller inside the page that took the gesture making the app scroll moves on its own: the page around
        // it is chosen before it whenever that lines up too.
        if let avoiding, var chosen = choose(held.filter { !avoiding($0.match) }, expected: expected) {
            chosen.votes = Int(votes[chosen.offset + count])
            return .scrolled(chosen)
        }
        if var chosen = choose(held, expected: expected) {
            chosen.votes = Int(votes[chosen.offset + count])
            return .scrolled(chosen)
        }
        let isStill = still(new, old, offset: best)
        let tellingNew = (0..<bandCount * count).count { !new.plain[$0] }
        let tellingOld = (0..<bandCount * count).count { !old.plain[$0] }
        why = "best offset \(best) with \(most) votes of \(moved) for moving, \(failure ?? behind ?? "verified false"), still \(isStill); telling line parts \(tellingNew) new, \(tellingOld) old"
        // Bands moved by an offset that then failed to line up: something scrolled, which is never still.
        if failure != nil { return .lost }
        return isStill ? .same : .lost
    }

    /// The offset that holds best, by how many lines that say something agree in how many bands; or one nearly as
    /// good nearer the last offset. With no last offset to go by (the first scroll), one that moved further the same
    /// way, holding at least half as well, wins: what sticks once a banner above it has gone (a header, the sidebars
    /// beside an article) moves only partway on the scroll that starts it, and a parallax picture less than the page,
    /// while the page itself moves furthest; the bands that sticks across can outscore the page's own.
    private static func choose(_ held: [(match: Match, score: Int)], expected: Int?) -> Match? {
        guard let top = held.max(by: { $0.score < $1.score }) else { return nil }
        guard let expected else {
            let further = held.filter {
                ($0.match.offset > 0) == (top.match.offset > 0) && abs($0.match.offset) > abs(top.match.offset) && $0.score * 2 >= top.score
            }
            return (further.max { abs($0.match.offset) < abs($1.match.offset) } ?? top).match
        }
        let near = held.filter { $0.score * 5 >= top.score * 4 }.min { abs($0.match.offset - expected) < abs($1.match.offset - expected) }
        return (near ?? top).match
    }

    /// The fewest lines two views must share for their offset to be trusted.
    static func minimumOverlap(_ count: Int) -> Int {
        min(count, max(16, count / 10))
    }

    /// Whether what changed did not move: more of the lines that say anything are where they were than where
    /// `offset` (the best voted) or any other offset would have them, and a good share are where they were. Lines
    /// alike both ways (a rule through blank rows) say nothing; lines new to the view (something changed in place)
    /// count only against a view where little stayed where it was, which scrolled too far to tell.
    private static func still(_ new: Lines, _ old: Lines, offset: Int) -> Bool {
        let count = new.count
        var telling = 0
        var kept = 0
        var moved = 0
        for band in 0..<new.bands.count {
            for index in 0..<count where !new.plain[band * count + index] || !old.plain[band * count + index] {
                let hash = new.hashes[band * count + index]
                let isKept = hash == old.hashes[band * count + index]
                let target = index + offset
                let carried = offset != 0 && target >= 0 && target < count && hash == old.hashes[band * count + target]
                if isKept, carried { continue }
                telling += 1
                if isKept {
                    kept += 1
                } else if carried {
                    moved += 1
                } else if !new.plain[band * count + index], let found = old.line(band: band, hash: hash), found != index {
                    moved += 1
                }
            }
        }
        return telling == 0 || (kept >= moved && kept * 5 >= telling)
    }

    /// What verifying an offset found.
    enum Verification {
        /// It holds: the lines that agree, and how many of them say something times the square of the bands that
        /// moved, for weighing offsets against each other.
        case holds(Match, score: Int)
        /// No band moved by it: nothing says the content moved that way.
        case unmoved
        /// Bands moved by it, but too little of the view lined up: something scrolled.
        case failed(String)
        /// Some bands moved by it while bands that moved before, or lines at an end, stayed where they were: a
        /// view partly repainted, or something moving inside a still one. Whether it is still tells which.
        case behind(String)
    }

    /// The lines that agree at `offset`, when enough do: the bands that move with it (a good share of their lines
    /// that testify agree), then the lines that agree in most of those bands, from the first run of them that says
    /// something to the last. Lines that changed in place (a playing video, an image loading, a band straddling a
    /// column that stays put and one that scrolls) say nothing either way; lines that stayed where they were, or
    /// moved otherwise, speak against it. `collapsed`: far fewer line parts found themselves than when the content
    /// last scrolled.
    private static func verify(
        _ new: Lines, _ old: Lines, offset: Int, previouslyMoving: [Int], content: Range<Int>?, expected: Int? = nil,
        collapsed: Bool = false
    ) -> Verification {
        let count = new.count
        let lower = max(0, -offset)
        let upper = min(count, count - offset)
        guard upper - lower >= minimumOverlap(count) else { return .unmoved }
        var moving: [Int] = []
        var conflicts = 0
        for band in 0..<new.bands.count {
            var agree = 0
            var stationary = 0
            var otherwise = 0
            for index in lower..<upper where !new.plain[band * count + index] {
                let hash = new.hashes[band * count + index]
                let carried = hash == old.hashes[band * count + index + offset]
                let kept = hash == old.hashes[band * count + index]
                // Repeating stationary patterns do not support either motion hypothesis.
                if carried, !kept {
                    agree += 1
                } else if kept, !carried {
                    if content?.contains(index) ?? true { stationary += 1 }
                } else if !carried, !kept, let found = old.line(band: band, hash: hash), found != index {
                    otherwise += 1
                }
            }
            // A small animation surrounded by unmoving text must not become the page's motion.
            if agree >= 4, agree * 5 >= agree + stationary + otherwise, agree > stationary { moving.append(band) }
            if previouslyMoving.contains(band), stationary >= max(16, (upper - lower) / 8), stationary > agree * 2 {
                conflicts += 1
            }
        }
        guard !moving.isEmpty else { return .unmoved }
        // A jump far from the last offset, after which what would have come into view is mostly just where it was:
        // nothing moved that far, something in the view changed to look like what was further on (a carousel's next
        // slide, the same picture elsewhere on the page).
        let jump = abs(offset) * 4 >= count && expected.map { abs(offset - $0) > max(8, abs($0) / 2) } ?? true
        var arriving = 0
        var stayed = 0
        for index in jump ? (offset > 0 ? upper ..< count : 0 ..< lower) : 0 ..< 0 where content?.contains(index) ?? true {
            for band in moving where !new.plain[band * count + index] {
                arriving += 1
                if new.hashes[band * count + index] == old.hashes[band * count + index] { stayed += 1 }
            }
        }
        if arriving >= 16, stayed * 2 >= arriving { return .unmoved }
        // Browser tiles can arrive at different offsets. Once several bands have moved together, do not
        // accept a frame in which half of them still show the previous offset. Wait for the repaint.
        guard conflicts < 2 || conflicts * 2 < previouslyMoving.count else { return .behind("left bands behind") }
        let needed = (moving.count * 2 + 2) / 3
        // 0: disagrees, 1: agrees, 2: agrees and says something, 3: says nothing either way.
        var agreement = [UInt8](repeating: 0, count: count)
        // Lines that stayed where they were in most bands that moved: tiles a frame late, from either end of the
        // part that scrolled before.
        var behind = [Bool](repeating: false, count: count)
        for index in lower..<upper {
            var agreeing = 0
            var telling = false
            var carriedTelling = 0
            var alikeTelling = 0
            var keptOnly = 0
            var against = 0
            var changed = 0
            for band in moving {
                let slot = band * count + index
                let hash = new.hashes[slot]
                let carried = hash == old.hashes[slot + offset]
                let isKept = hash == old.hashes[slot]
                if carried {
                    agreeing += 1
                    if !new.plain[slot] {
                        telling = true
                        carriedTelling += 1
                        if isKept { alikeTelling += 1 }
                    }
                } else if new.plain[slot], !old.plain[slot + offset] {
                    // Blank where the content would have moved to: it did not move there.
                    against += 1
                }
                if isKept {
                    if !carried, !new.plain[slot] { keptOnly += 1 }
                } else if !carried, !new.plain[slot] {
                    if let found = old.line(band: band, hash: hash), found != index { against += 1 } else { changed += 1 }
                }
            }
            behind[index] = keptOnly >= needed
            // Parts that changed in place (a crossfading image beside tiles that scrolled) testify to nothing: the
            // line agrees when most of the rest does.
            let testifying = moving.count - changed
            let neededHere = (testifying * 2 + 2) / 3
            if telling, alikeTelling == carriedTelling {
                // What it shows is alike where it was and where it moved to: a rule through blank rows, or a bar
                // whose pattern repeats at the scroll's distance. It says nothing, and is no part of what surely
                // scrolls.
                agreement[index] = 3
            } else if testifying > 0, agreeing >= neededHere {
                agreement[index] = telling ? 2 : 1
            } else if keptOnly == 0, against == 0 {
                // Changed in place, as far as anything here tells.
                agreement[index] = 3
            }
        }
        // Where the view shows mostly something else, what repeats on a page (a phrase, a reply link, the cards of a
        // grid) still lines up somewhere, with blank lines around it. An offset that half as many lines speak against
        // as say something for it is no scroll (where the content scrolled, a fifth as many at most).
        if collapsed {
            var against = 0
            var telling = 0
            for index in lower..<upper {
                if agreement[index] == 0 { against += 1 } else if agreement[index] == 2 { telling += 1 }
            }
            if against * 2 >= telling { return .failed("too little agrees for the votes lost") }
        }
        if let content {
            let limit = max(16, (upper - lower) / 8)
            var top = max(lower, content.lowerBound)
            while top < min(upper, content.upperBound), behind[top] { top += 1 }
            var bottom = min(upper, content.upperBound)
            while bottom > max(lower, content.lowerBound), behind[bottom - 1] { bottom -= 1 }
            if top - max(lower, content.lowerBound) >= limit || min(upper, content.upperBound) - bottom >= limit { return .behind("tiles left behind") }
        }
        func agrees(_ index: Int) -> Bool { agreement[index] == 1 || agreement[index] == 2 }
        // A run begins where a window of lines mostly agrees, some of them saying something.
        let window = min(8, max(2, (upper - lower) / 8))
        func solid(_ start: Int) -> Bool {
            var agreeing = 0
            var telling = 0
            for index in start..<start + window {
                if agrees(index) { agreeing += 1 }
                if agreement[index] == 2 { telling += 1 }
            }
            return agreeing * 4 >= window * 3 && telling >= min(2, window)
        }
        var first: Int?
        var start = lower
        while start + window <= upper {
            if solid(start) { first = start; break }
            start += 1
        }
        guard var begin = first else { return .failed("no run lines up") }
        while agreement[begin] != 2 { begin += 1 }
        var last: Int?
        var end = upper - window
        while end >= begin {
            if solid(end) { last = end + window; break }
            end -= 1
        }
        guard var finish = last else { return .failed("no run lines up") }
        while finish > begin, agreement[finish - 1] != 2 { finish -= 1 }
        var agreeing = 0
        var silent = 0
        for index in begin..<finish {
            if agrees(index) { agreeing += 1 } else if agreement[index] == 3 { silent += 1 }
        }
        guard finish - begin >= window, agreeing * 2 >= finish - begin - silent else { return .failed("too few lines agree") }
        var from = begin
        while from > lower, agrees(from - 1) { from -= 1 }
        var to = finish
        while to < upper, agrees(to) { to += 1 }
        guard to - from >= minimumOverlap(count) else { return .failed("too short a run agrees") }
        // The page scrolls across more of the view than a sidebar that sticks, however dense the sidebar's text.
        let telling = (from..<to).count { agreement[$0] == 2 }
        return .holds(Match(offset: offset, first: begin, end: finish, from: from, to: to, movingBands: moving), score: telling * moving.count * moving.count)
    }
}

/// One band's lines by hash, for the lines that are not plain; a hash more than one line has finds none.
nonisolated private struct LineIndex {
    private var keys: [UInt32]
    /// The line, -1 for an empty slot, -2 for a hash several lines share.
    private var lines: [Int32]
    private let mask: Int

    init(hashes: UnsafePointer<UInt32>, plain: UnsafePointer<Bool>, count: Int) {
        var size = 16
        while size < count * 2 { size <<= 1 }
        mask = size - 1
        keys = [UInt32](repeating: 0, count: size)
        lines = [Int32](repeating: -1, count: size)
        for index in 0..<count where !plain[index] {
            let hash = hashes[index]
            var slot = Int(hash) & mask
            while lines[slot] != -1, keys[slot] != hash { slot = (slot + 1) & mask }
            if lines[slot] == -1 {
                keys[slot] = hash
                lines[slot] = Int32(index)
            } else {
                lines[slot] = -2
            }
        }
    }

    func line(of hash: UInt32) -> Int? {
        var slot = Int(hash) & mask
        while lines[slot] != -1 {
            if keys[slot] == hash { return lines[slot] >= 0 ? Int(lines[slot]) : nil }
            slot = (slot + 1) & mask
        }
        return nil
    }

    /// Whether any line has `hash`, one or several.
    func holds(_ hash: UInt32) -> Bool {
        var slot = Int(hash) & mask
        while lines[slot] != -1 {
            if keys[slot] == hash { return true }
            slot = (slot + 1) & mask
        }
        return false
    }
}

// MARK: - The picture's lines

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
nonisolated private final class Canvas {
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
                if Self.isPlain(pixels, bytes) { plain.append(pixels.load(as: UInt32.self)) }
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
                guard !Self.isPlain(shown + start, bytes) || ground.map({ memcmp(shown + start, $0.baseAddress + start, bytes) != 0 }) == true else { continue }
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
            if quiet || (between || byTheEdge) && (segment..<end).allSatisfy({ !moves[$0] }) {
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
                    return Self.isPlain(row + start, bytes) ? (row + start).load(as: UInt32.self) : nil
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

    /// Whether `length` bytes of pixels are one color throughout.
    private static func isPlain(_ bytes: UnsafeRawPointer, _ length: Int) -> Bool {
        length <= 4 || memcmp(bytes, bytes + 4, length - 4) == 0
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
            let weighed = weigh(
                source, into: target, support: support, previous: previous, sameRow: sameRow, formerRow: formerRow,
                held: state == 2, atEdge: atEdge, belowStart: belowStart, qualities: chunk.quality + slot * segments, loose: loose, changes: changes,
                quality: quality,
                firstRow: firstRow, calm: &chunk.calm[slot], restless: &chunk.restless[slot]
            )
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
                    guard !Self.nearlyAlike(source + start, previous + start, length), !Self.isPlain(source + start, length),
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
                while abs(next - row) <= reach, next >= 0, next < view.count, Self.isPlain(view.line(next) + start, length) {
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
                if !Self.isPlain(source + start, end - start), memcmp(source + start, sameRow + start, end - start) == 0 { continue }
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
            if Self.isPlain(source + lower, length) {
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
        if !Self.isPlain(source + start, length) { return true }
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
                } else if Self.isPlain(source + start, end - start), memcmp(source + start, sameRow + start, end - start) == 0,
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
        firstRow: UnsafeRawPointer?, calm: UnsafeMutablePointer<UInt8>, restless: UnsafeMutablePointer<UInt8>
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
                    if Self.isPlain(source + start, end - start), memcmp(source + start, target + start, end - start) == 0 {
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
                if held, !Self.isPlain(source + from, to - from), memcmp(source + from, sameRow + from, to - from) == 0 {
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
                    if drifted, loose[segment] == 0 { continue }
                    // Repeated passes close to a sticky edge cannot overrule a clearer interior observation; but where
                    // the line still holds what the first view showed, changed once or twice since, and three views in
                    // a row now show it alike and otherwise, the page changed there after the first view (a picture
                    // loaded, a skeleton filled in, a highlight gone). Away from the bars, what they show takes its
                    // place, once the view is all in and where lines enough in a row give way (`endView`): a video or
                    // an animation that follows the scrolling, changing on and on, keeps its first frame, and nothing
                    // changes a line or two at a time.
                    if quality < qualities[segment] {
                        guard calm.pointee >= 2, restless.pointee <= 2, !atEdge, !belowStart, Self.nearlyAlike(source + start, previous + start, length),
                              let firstRow, memcmp(target + start, firstRow + start, length) == 0,
                              // What stayed where it was on screen is over the content; but a plain stretch over one (a
                              // placeholder's color, a blank row of the picture that replaced it) looks alike everywhere.
                              memcmp(source + start, sameRow + start, length) != 0
                                  || Self.isPlain(source + start, length) && Self.isPlain(target + start, length) else { continue }
                        stale.append(start)
                        continue
                    }
                    if Self.nearlyAlike(source + start, previous + start, length) {
                        // What a column stuck there shows past the last line it was seen to move over is not the line's.
                        if drifted, pastReach(segment) { continue }
                        let plain = Self.isPlain(source + start, length)
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

    /// The line's hash in each band, for finding views in the picture, after it changed.
    private func rehash(_ line: UnsafeMutableRawPointer, chunk: Chunk, slot: Int) {
        for (band, part) in bands.enumerated() {
            let start = line + part.lowerBound * 4, bytes = part.count * 4
            chunk.hashes[slot * bands.count + band] = UInt32(truncatingIfNeeded: crc32(0, start.assumingMemoryBound(to: UInt8.self), uInt(bytes)))
            chunk.plain[slot * bands.count + band] = Self.isPlain(start, bytes)
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
                if plain { plain = Self.isPlain(line + part.lowerBound, part.count) && (line + part.lowerBound).load(as: UInt32.self) == color }
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
