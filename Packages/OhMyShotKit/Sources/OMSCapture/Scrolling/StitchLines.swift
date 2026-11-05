import Accelerate
import Foundation
import OMSCore
import zlib

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

    static func make(_ pixels: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int, turned: Bool, margin: Int, corners: ViewCorners?) -> Lines? {
        guard let lines = Lines(count: turned ? width : height, length: turned ? height : width, margin: margin) else { return nil }
        lines.fill(pixels, bytesPerRow: bytesPerRow, width: width, height: height, turned: turned, corners: corners)
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
    /// clockwise (each column then reads from the bottom up); past a window's rounded `corners`, filled.
    func fill(_ source: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int, turned: Bool, corners: ViewCorners? = nil) {
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
        if let corners, !corners.isEmpty {
            corners.fill(width: width, height: height) { x, y in turned ? line(x) + (height - 1 - y) * 4 : line(y) + x * 4 }
            // Filled from the lines further in, which may have changed: hashed again.
            if !turned {
                let rows = corners.rows
                for row in 0 ..< min(rows.top, count) { kept[row] = false }
                for row in max(0, count - rows.bottom) ..< count { kept[row] = false }
            }
        }
        filled = true
        for (band, range) in bands.enumerated() {
            for index in 0..<count where !kept[index] {
                (hashes[band * count + index], plain[band * count + index]) = Self.hash(line(index), band: range)
            }
        }
        indexes = nil
    }

    /// The hash of `band` (pixels across) of `line`, and whether that part is one color throughout. A view's lines are
    /// hashed by it, and so are the picture's (`Canvas`, after a line changes): a view is found in the picture by
    /// looking its hashes up among the picture's, so the two must agree bit for bit, and one function makes them.
    static func hash(_ line: UnsafeRawPointer, band: Range<Int>) -> (hash: UInt32, plain: Bool) {
        let start = line + band.lowerBound * 4, bytes = band.count * 4
        return (UInt32(truncatingIfNeeded: crc32(0, start.assumingMemoryBound(to: UInt8.self), uInt(bytes))), isPlain(start, bytes))
    }

    /// Whether `length` bytes of pixels are one color throughout.
    static func isPlain(_ bytes: UnsafeRawPointer, _ length: Int) -> Bool {
        length <= 4 || memcmp(bytes, bytes + 4, length - 4) == 0
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
nonisolated struct LineIndex {
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
