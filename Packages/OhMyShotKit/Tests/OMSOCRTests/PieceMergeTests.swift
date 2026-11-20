import CoreGraphics
import Testing
@testable import OMSOCR

struct PieceMergeTests {
    private func line(_ text: String, x: CGFloat = 100, y: CGFloat, width: CGFloat = 300, height: CGFloat = 20) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: height), confidence: 1)
    }

    /// The readings of the pieces of a `width` × `height` picture, in whole-picture coordinates, as one.
    private func merge(_ readings: [[OCRLine]], width: Int, height: Int) -> [OCRLine] {
        PieceMerge.merged(readings, pieces: PictureText.pieces(width: width, height: height), size: CGSize(width: width, height: height))
    }

    // A 4000-pixel-tall picture is read in three bands: 0–2048, 1792–3840, 3584–4000. The first overlap, 1792–2048,
    // is cut at 1920.

    @Test func theCoresTileThePicture() {
        for (width, height) in [(4112, 9000), (3346, 47_500), (10_989, 2880), (30_000, 2400), (4112, 2658)] {
            let size = CGSize(width: width, height: height)
            let pieces = PictureText.pieces(width: width, height: height)
            let cores = PieceMerge.cores(of: pieces, in: size)
            #expect(cores.reduce(0) { $0 + $1.width * $1.height } == CGFloat(width * height))
            for (index, core) in cores.enumerated() {
                for other in cores[(index + 1)...] { #expect(core.intersection(other).isEmpty) }
                #expect(pieces[index].contains(core))
            }
        }
    }

    @Test func aLineBothBandsReadIsKeptOnceFromTheBandThatOwnsIt() {
        // Its middle is above the cut at 1920: the first band's.
        let merged = merge([[line("from the first", y: 1890)], [line("from the second", y: 1890)], []], width: 2000, height: 4000)
        #expect(merged.map(\.text) == ["from the first"])
        // Below it: the second's.
        let below = merge([[line("from the first", y: 1930)], [line("from the second", y: 1930)], []], width: 2000, height: 4000)
        #expect(below.map(\.text) == ["from the second"])
    }

    @Test func aLineCutByABandsEdgeIsTakenWholeFromTheNextBand() {
        // 2040…2060 straddles the first band's bottom edge, 2048: it reads cut off there and whole in the second.
        let cut = line("Cut off", y: 2040, height: 8)
        let whole = line("A whole line", y: 2040)
        #expect(merge([[cut], [whole], []], width: 2000, height: 4000) == [whole])
        // The same at the second band's top edge, 1792: whole in the first, cut off in the second.
        let topCut = line("Cut", y: 1792, height: 6)
        let topWhole = line("A whole line", y: 1786)
        #expect(merge([[topWhole], [topCut], []], width: 2000, height: 4000) == [topWhole])
    }

    @Test func whatTheOwnerMissedIsKeptFromTheOtherBand() {
        let cut = line("Cut off", y: 2040, height: 8)
        #expect(merge([[cut], [], []], width: 2000, height: 4000) == [cut])
    }

    @Test func aLineReadAPixelEitherSideOfACutIsKeptOnce() {
        // Middles at 1919 and 1921, so each band owns its own reading of the line.
        let merged = merge([[line("The same line", y: 1909)], [line("The same line", y: 1911)], []], width: 2000, height: 4000)
        #expect(merged.count == 1)
        // Different text is not a repeat.
        let two = merge([[line("One line", y: 1909)], [line("Another line", y: 1911)], []], width: 2000, height: 4000)
        #expect(two.count == 2)
    }

    @Test func linesAwayFromTheSeamsAreKeptAndAReadingOverOneIsReplaced() {
        let readings = [
            [line("a", y: 100), line("b", y: 1000), line("c", y: 2000)],
            [line("c again", y: 2000), line("d", y: 2500)],
            [line("e", y: 3700)],
        ]
        // "c" lies in the second band's core (below 1920), where the second band read "c again" over it.
        #expect(merge(readings, width: 2000, height: 4000).map(\.text).sorted() == ["a", "b", "c again", "d", "e"])
    }

    @Test func lineAtTheSameHeightButAnotherColumnIsNotARepeat() {
        let merged = merge([[line("Left", x: 100, y: 1900), line("Right", x: 1200, y: 1900)], [line("Left", x: 100, y: 1900)], []], width: 2000, height: 4000)
        #expect(merged.map(\.text).sorted() == ["Left", "Right"])
    }

    @Test func aVeryWidePictureIsMergedAcrossItsColumnsToo() {
        // 10 989 × 2880: two bands of five columns each, the first column 0–2880, the next from 2624.
        let pieces = PictureText.pieces(width: 10_989, height: 2880)
        #expect(pieces[1].minX == 2624)
        // A short line at the first column cut (x 2752), read whole by both columns; and one of the first band's
        // that the second band's overlap strip (1792–2048) reads again.
        let readings = pieces.indices.map { index -> [OCRLine] in
            var lines: [OCRLine] = []
            if index == 0 || index == 1 { lines.append(line("cell", x: 2700, y: 400, width: 100)) }
            if index == 0 || index == 5 { lines.append(line("row", x: 300, y: 1900, width: 100)) }
            return lines
        }
        let merged = PieceMerge.merged(readings, pieces: pieces, size: CGSize(width: 10_989, height: 2880))
        #expect(merged.map(\.text).sorted() == ["cell", "row"])
    }

    // A 10 989 × 2880 picture's columns: 0–2880, 2624–5504, 5248–8128, …; the first cut's overlap is 2624–2880.

    @Test func theTwoPiecesOfALineAColumnCutWentThroughAreFound() {
        let pieces = PictureText.pieces(width: 10_989, height: 2880)
        let left = line("A line that runs", x: 2278, y: 1045, width: 597, height: 59)
        let right = line("runs on across the cut", x: 2623, y: 1045, width: 982, height: 59)
        let elsewhere = line("Another row", x: 300, y: 1045, width: 400, height: 59)
        #expect(PieceMerge.crossings(in: [elsewhere, right, left], pieces: pieces) == [[2, 1]])
        // A line that ends at the cut with nothing starting beside it is its own.
        #expect(PieceMerge.crossings(in: [left, line("Not at the edge", x: 2800, y: 1045, width: 300, height: 59)], pieces: pieces).isEmpty)
        // Nor are two lines on different rows.
        #expect(PieceMerge.crossings(in: [left, line("Below", x: 2623, y: 1300, width: 982, height: 59)], pieces: pieces).isEmpty)
    }

    @Test func aLineCutWithNothingBeyondTheCutIsReadOnPastIt() {
        let pieces = PictureText.pieces(width: 10_989, height: 2880)
        // The second column read the end of a line from its left edge (2624), and the first read nothing of it.
        let end = line("es the narrow orchard near the old mill", x: 2624, y: 1045, width: 900, height: 24)
        let above = line("Another row", x: 300, y: 900, width: 400, height: 24)
        var cuts = PieceMerge.loneCuts(in: [above, end], pieces: pieces)
        // As much of the row as makes a column's width with the line (2880).
        #expect(cuts.map(\.line) == [1])
        #expect(cuts[0].stretch == CGRect(x: 644, y: 1045, width: 2880, height: 24))
        // Up to a line the first column did read on that row, further left.
        let before = line("Margin", x: 700, y: 1047, width: 200, height: 24)
        cuts = PieceMerge.loneCuts(in: [above, end, before], pieces: pieces)
        #expect(cuts.map(\.line) == [1])
        #expect(cuts[0].stretch == CGRect(x: 900, y: 1045, width: 2624, height: 24))
        // The start of a line, cut at the first column's right edge (2880) with nothing after it.
        let start = line("28. The gentle lantern cross", x: 2300, y: 1045, width: 578, height: 24)
        cuts = PieceMerge.loneCuts(in: [start, above], pieces: pieces)
        #expect(cuts.map(\.line) == [0])
        #expect(cuts[0].stretch == CGRect(x: 2300, y: 1045, width: 2880, height: 24))
        // The two pieces of a line read on both sides of the cut are joined as before, and a line clear of the cut is whole.
        let left = line("A line that runs", x: 2278, y: 1045, width: 597, height: 59)
        let right = line("runs on across the cut", x: 2623, y: 1045, width: 982, height: 59)
        #expect(PieceMerge.loneCuts(in: [left, right, above], pieces: pieces).isEmpty)
    }

    @Test func aLetterOrTwoPastTheCutCompletesTheLine() {
        let pieces = PictureText.pieces(width: 10_989, height: 2880)
        // The first column (to 2880) read a line up to its last two letters, which lie past the cut.
        let start = line("28. The gentle lantern cross", x: 2300, y: 1045, width: 578, height: 24)
        #expect(PieceMerge.loneCuts(in: [start], pieces: pieces).map(\.after) == [2880])
        let read = CGRect(x: 2300, y: 1045, width: 600, height: 24)
        #expect(PieceMerge.completes(start, text: "28. The gentle lantern crosses", box: read, before: nil, after: 2880))
        // The cut went through the last letter the column read, "c" for an "o".
        let clipped = line("28. The gentle lantern crc", x: 2300, y: 1045, width: 578, height: 24)
        #expect(PieceMerge.completes(clipped, text: "28. The gentle lantern crosses", box: read, before: nil, after: 2880))
        // Not past the cut, no longer, or another line's text: the line stays as it was.
        #expect(!PieceMerge.completes(start, text: "28. The gentle lantern crosses", box: CGRect(x: 2300, y: 1045, width: 583, height: 24), before: nil, after: 2880))
        #expect(!PieceMerge.completes(start, text: "28. The gentle lantern cross", box: read, before: nil, after: 2880))
        #expect(!PieceMerge.completes(start, text: "29. The plain compass crosses on", box: read, before: nil, after: 2880))
        // The end of a line, whose start lies before the second column's left edge (2624).
        let end = line("es the narrow orchard near the old mill", x: 2624, y: 1045, width: 900, height: 24)
        #expect(PieceMerge.loneCuts(in: [end], pieces: pieces).map(\.before) == [2624])
        let whole = CGRect(x: 2570, y: 1045, width: 954, height: 24)
        #expect(PieceMerge.completes(end, text: "crosses the narrow orchard near the old mill", box: whole, before: 2624, after: nil))
        #expect(!PieceMerge.completes(end, text: "crosses the narrow orchard near the old mill", box: whole, before: nil, after: 3840))
        // Two readings of one line differ by a letter: "moring" in the column's, "morning" in the stretch's.
        let misread = line("es the narrow orchard until the moring bell.", x: 2624, y: 1045, width: 900, height: 24)
        #expect(PieceMerge.completes(misread, text: "crosses the narrow orchard until the morning bell.", box: whole, before: 2624, after: nil))
    }

    @Test func whatAReadingAddsPastTheCutDoesNotPayForWhatItLostAtTheOtherEnd() {
        // The stretch's reading goes on past the cut (2880) and has lost the line's number, at the end no cut touched.
        let start = line("28. The gentle lantern cross", x: 2300, y: 1045, width: 578, height: 24)
        let past = CGRect(x: 2300, y: 1045, width: 980, height: 24)
        #expect(!PieceMerge.completes(start, text: "The gentle lantern crosses the narrow orchard", box: past, before: nil, after: 2880))
        #expect(PieceMerge.completes(start, text: "28. The gentle lantern crosses the narrow orchard", box: past, before: nil, after: 2880))
        // A line cut at its start (2624), and a reading that has its start and has lost its last word.
        let end = line("es the narrow orchard near the old mill", x: 2624, y: 1045, width: 900, height: 24)
        let whole = CGRect(x: 2570, y: 1045, width: 954, height: 24)
        #expect(!PieceMerge.completes(end, text: "crosses the narrow orchard near the old", box: whole, before: 2624, after: nil))
        // What the other reading has more of at that end, a period the column missed, is no loss.
        let plain = line("es the narrow orchard near the old mill", x: 2624, y: 1045, width: 900, height: 24)
        #expect(PieceMerge.completes(plain, text: "crosses the narrow orchard near the old mill.", box: whole, before: 2624, after: nil))
    }

    @Test func aLineNoCutIsNearIsNotReadAgain() {
        // Its right edge less its left is more than its width, by rounding: (300.3 + 400.4) - 300.3 > 400.4.
        let pieces = PictureText.pieces(width: 10_989, height: 2880)
        let clear = line("Another row", x: 300.3, y: 900, width: 400.4, height: 24)
        #expect(clear.box.maxX - clear.box.minX > clear.box.width)
        #expect(PieceMerge.loneCuts(in: [clear], pieces: pieces).isEmpty)
    }

    @Test func aFragmentOfALineReadWholeIsDropped() {
        // A piece's passes left the start of a line a second time, over the line itself.
        let whole = line("21. The quiet harbor crosses the plain compass near the old mill", x: 1100, y: 820, width: 946)
        let fragment = line("21. The quiet l", x: 1092, y: 821, width: 114)
        #expect(merge([[fragment, whole], [], []], width: 2000, height: 4000) == [whole])
        #expect(merge([[whole, fragment], [], []], width: 2000, height: 4000) == [whole])
        // A short line beside a long one, or on another row, is a line of its own; so is one about as long.
        let beside = line("Page 21", x: 100, y: 820, width: 90)
        let below = line("21. The quiet l", x: 1092, y: 850, width: 114)
        let other = line("An altogether different reading of that same row", x: 1100, y: 821, width: 900)
        #expect(merge([[whole, beside, below], [], []], width: 2000, height: 4000).count == 3)
        #expect(merge([[whole, other], [], []], width: 2000, height: 4000).count == 2)
    }

    @Test func aLineAcrossTwoCutsIsOneGroup() {
        let pieces = PictureText.pieces(width: 10_989, height: 2880)
        let first = line("first", x: 2000, y: 400, width: 875, height: 40)
        let middle = line("middle", x: 2623, y: 400, width: 2876, height: 40)
        let last = line("last", x: 5248, y: 400, width: 900, height: 40)
        #expect(PieceMerge.crossings(in: [last, first, middle], pieces: pieces) == [[1, 2, 0]])
    }

    @Test func aWholeReadingIsAboutAsLongAsItsPiecesLessTheirOverlap() {
        // Ten characters each; the second's first 40% lies under the first's last part.
        let parts = [line("abcdefghij", x: 0, y: 0, width: 100), line("ghijklmnop", x: 60, y: 0, width: 100)]
        #expect(PieceMerge.isWhole("abcdefghijklmnop", of: parts))
        #expect(PieceMerge.isWhole("abcdefghi jklmnopq", of: parts))
        #expect(!PieceMerge.isWhole("abcdef", of: parts))
        #expect(!PieceMerge.isWhole("abcdefghijghijklmnopqrst", of: parts))
    }

    @Test func aReadingIsMovedIntoThePictureWithItsOwnBox() {
        let moved = line("text", x: 10, y: 20, width: 30, height: 8).moved(by: CGPoint(x: 100, y: 1792))
        #expect(moved.box == CGRect(x: 110, y: 1812, width: 30, height: 8))
        #expect(moved.text == "text")
    }

    @Test func aRepeatIgnoresSpaces() {
        #expect(line("a b  c", y: 0).repeats(line("abc", y: 0)))
        #expect(!line("abc", y: 0).repeats(line("abd", y: 0)))
    }

    @Test func manyCutLinesAreReadInSeveralStrips() {
        // Rows of 50 pixels and a 30-pixel gap each: 25 fit under 2048 pixels with the margins.
        let crops = (0..<60).map { CGRect(x: 0, y: CGFloat($0) * 100, width: 3000, height: 50) }
        #expect(LineStrip.batches(of: crops) == [0..<25, 25..<50, 50..<60])
        #expect(LineStrip.batches(of: []).isEmpty)
        #expect(LineStrip.batches(of: [CGRect(x: 0, y: 0, width: 10, height: 5000)]) == [0..<1])
    }
}
