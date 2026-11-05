import CoreGraphics
import Foundation
import ImageIO
import OMSCore

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
        canvas?.beginFrame()
        innerPart = nil
        viewsSinceMoved += 1
        guard !isFull, taken == nil else { return .full }
        guard vertical != nil || horizontal != nil else {
            vertical = Track(Lines.make(pixels, bytesPerRow: bytesPerRow, width: width, height: height, turned: false, margin: margin, corners: corners))
            horizontal = Track(Lines.make(pixels, bytesPerRow: bytesPerRow, width: width, height: height, turned: true, margin: margin, corners: corners))
            return .started
        }
        // Down or up first; sideways while the axis is not known and the rows lined up with nothing, or once the
        // content is known to scroll that way.
        var verticalReason: String?
        if axis != .horizontal, preferredAxis != .horizontal, let track = vertical {
            if let step = take(pixels, bytesPerRow: bytesPerRow, along: track, turned: false, verticalReason: nil) { return step }
            verticalReason = lostBecause
        }
        guard preferredAxis != .vertical, let track = horizontal else { return .lost }
        return take(pixels, bytesPerRow: bytesPerRow, along: track, turned: true, verticalReason: verticalReason) ?? .lost
    }

    /// Lines the view up with `track`'s last view, as its rows or (`turned`) its columns, and takes it in as that
    /// finds. Nil when it lined up with nothing while the axis is not known, what was found in `lostBecause`: after
    /// the rows, the columns are tried, told `verticalReason`, what the rows found.
    private func take(_ pixels: UnsafeRawPointer, bytesPerRow: Int, along track: Track, turned: Bool, verticalReason: String?) -> Step? {
        let kept: ReferenceWritableKeyPath<ScrollStitcher, Track?> = turned ? \.horizontal : \.vertical
        var track = track
        guard let view = track.take(pixels, bytesPerRow: bytesPerRow, width: width, height: height, turned: turned, margin: margin, corners: corners) else {
            return .lost
        }
        var why = ""
        let reference = track.reference
        switch Lines.compare(
            view, with: reference, movingBands: track.movingBands, content: band, expected: track.lastOffset, previousVotes: track.lastVotes,
            avoiding: isDriven && drivenAt != nil ? { [unowned self] in innerScroller($0, view: view, old: reference, turned: turned) != nil } : nil,
            why: &why
        ) {
        case .same:
            count(view, reference: track.reference)
            noteBlank(view, reference: track.reference)
            track.spare = view
            self[keyPath: kept] = track
            return .unchanged
        case .scrolled(let match):
            if axis != nil, overscrolled(match, view: view, old: track.reference) {
                track.spare = view
                self[keyPath: kept] = track
                return .unchanged
            }
            if let inner = innerScroller(match, view: view, old: track.reference, turned: turned) {
                innerPart = inner.part
                if inner.underGesture { heldInner = inner.part }
                track.spare = view
                self[keyPath: kept] = track
                return .unchanged
            }
            // Before the axis is known, only the whole view moving sideways says the content scrolls sideways: a
            // carousel's slide, or a hero's, moves only some of it, and must never turn a page on its side.
            let bands = track.reference.bands.count
            if turned, axis == nil, match.movingBands.count < max(1, bands - 1, (bands * 3 + 3) / 4) {
                track.spare = view
                self[keyPath: kept] = track
                lostBecause = "\(verticalReason ?? why); sideways only \(match.movingBands.count) of \(bands) bands moved"
                return .lost
            }
            axis = turned ? .horizontal : .vertical
            if turned { vertical = nil } else { horizontal = nil }
            let step = accept(match, view: view, track: &track)
            self[keyPath: kept] = track
            return step
        case .lost:
            if axis != nil, let step = pastBlank(view, track: &track) ?? relocate(view, track: &track) {
                self[keyPath: kept] = track
                return step
            }
            track.spare = view
            self[keyPath: kept] = track
            // Before the axis is known the vertical comparison's reason is the one that tells most.
            lostBecause = verticalReason.map { "\($0); sideways: \(why)" } ?? why
            return axis == nil ? nil : .lost
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

    /// The rounded corners of a window the area shares with it, filled in each view as it is taken in. Set before the
    /// first view.
    public var corners: ViewCorners?

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
    /// since showed that could not be placed: that is no blank stretch going by. A view of nothing but the stretch, of
    /// the content before it leaving and the stretch, or of the stretch and a line or two of what follows, shows nothing
    /// to line up or take in, and nothing scrolled as far as anything tells: unchanged, as it is under a header that
    /// stays put, not lost.
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
        let overlap = Lines.minimumOverlap(view.count)
        // The content before the stretch leaving the view: a few of its last lines at the view's start, too few to line
        // up with, and the stretch after them. Nothing comes into view but the stretch, however many views show it (the
        // page may stand still between them): unchanged, the stretch begun.
        if !movedTowardStart, top == band.lowerBound {
            let blankFrom = blankBottom(view, besides: reference, end: end)
            if blankFrom - band.lowerBound < overlap, view.lines(newIn: band.lowerBound ..< blankFrom, to: reference) == 0 {
                sinceReference.blank = true
                track.spare = view
                return .unchanged
            }
        }
        // Too little of the stretch above what came in to tell it from a view that scrolled too far at once: what it
        // shows that the reference shows nowhere was not placed.
        guard top - band.lowerBound >= overlap else {
            if view.lines(newIn: band, to: reference) >= 16 { sinceReference.unplaced = true }
            return nil
        }
        // Enough of the stretch at the picture's end, and of what came in for the next view to line up with: a line or
        // two is waited out as the stretch going on, nothing scrolled as far as anything tells, however many views show
        // it (the page may stand still between them while something else on screen changes).
        guard sinceReference.blank, !sinceReference.unplaced, end.lines >= overlap else { return nil }
        guard view.lines(saying: top ..< band.upperBound, besides: reference) >= 16 else {
            track.spare = view
            return .unchanged
        }
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

    /// The first line of `view`'s part that scrolls from which on to its end every line is the color the picture ends in,
    /// as `blankTop` tells it line by line. The part's start when it is that color throughout.
    private func blankBottom(_ view: Lines, besides other: Lines, end: (color: UInt32, lines: Int, band: Range<Int>, line: Int)) -> Int {
        guard let canvas else { return end.band.upperBound }
        let fixed = end.line - end.lines
        let straddling = canvas.straddling(view.bands)
        var line = end.band.upperBound
        while line > end.band.lowerBound, isBlank(view, line: line - 1, color: end.color, besides: line - 1 >= fixed ? other : nil, straddling: straddling) {
            line -= 1
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
        canvas.noteFixedOverlays(view, old: old, offset: match.offset, rows: match.from..<match.to)
        position = next
        // The lines both views show back, segment by segment, what moved with the content; what just came into
        // view is taken in but for what stays where it is on screen. A sidebar that never moves and an avatar
        // stuck while its post scrolls back nothing, so they never spread down the picture.
        canvas.settleTentative(view, at: position)
        canvas.beginView(travel: abs(match.offset), lines: position + match.from ..< position + match.to)
        // A freshly changed image can shorten the matching band although its page position is known
        // from the surrounding text. Count its changes across the previously confirmed scrolling area,
        // not only inside the rows that still match this particular frame.
        let previouslyScrolling = self.band ?? band
        let overlapStart = max(0, -match.offset, min(band.lowerBound, previouslyScrolling.lowerBound))
        let overlapEnd = min(view.count, old.count - match.offset, max(band.upperBound, previouslyScrolling.upperBound))
        let rows = (overlapStart..<max(overlapStart, overlapEnd)).filter { !pulledOut(position + $0) }
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
    mutating func take(_ pixels: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int, turned: Bool, margin: Int, corners: ViewCorners?) -> Lines? {
        guard let view = spare ?? Lines(count: reference.count, length: reference.length, margin: margin) else { return nil }
        spare = nil
        view.fill(pixels, bytesPerRow: bytesPerRow, width: width, height: height, turned: turned, corners: corners)
        return view
    }
}
