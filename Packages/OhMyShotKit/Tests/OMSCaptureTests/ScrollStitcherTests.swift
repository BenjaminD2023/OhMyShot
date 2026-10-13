import CoreGraphics
import Foundation
import Testing
@testable import OMSCapture

/// Scrolling capture's stitching, on made-up pages scrolled as a person would: the picture must be the page
/// itself, pixel for pixel, with what stays put on screen kept once.
struct ScrollStitcherTests {
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let white: UInt32 = 0xFFFF_FFFF

    /// A page of made-up text: lines of word-like marks on white, each row a little different, blank rows
    /// between the lines. Pixels are BGRA in memory, 0xAARRGGBB as numbers.
    private struct Page {
        let width: Int
        let height: Int
        var pixels: [UInt32]

        init(width: Int, height: Int, seed: UInt64 = 7) {
            self.width = width
            self.height = height
            pixels = [UInt32](repeating: ScrollStitcherTests.white, count: width * height)
            var state = seed
            func random(_ range: ClosedRange<Int>) -> Int {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return range.lowerBound + Int((state >> 33) % UInt64(range.count))
            }
            var top = 6
            while top + 14 < height {
                var x = random(4...24)
                while x < width - 8 {
                    let word = min(random(8...60), width - 4 - x)
                    let ink = UInt32(random(0x20...0x70))
                    let color = 0xFF00_0000 | ink << 16 | ink << 8 | UInt32(random(0x20...0x90))
                    let from = top + random(0...3), to = top + 14 - random(0...3)
                    for y in from..<to {
                        for column in x..<x + word where random(0...9) < 7 {
                            pixels[y * width + column] = color
                        }
                    }
                    x += word + random(4...10)
                }
                top += random(18...26)
            }
        }

        func row(_ y: Int) -> ArraySlice<UInt32> {
            pixels[y * width ..< (y + 1) * width]
        }

        func column(_ x: Int, from: Int, to: Int) -> [UInt32] {
            (from..<to).map { pixels[$0 * width + x] }
        }
    }

    /// A view of `page` scrolled to `offset` (rows, or columns when `sideways`), `size` long along the
    /// scroll, with bars that stay put over its ends and anything else drawn over it.
    private static func view(
        _ page: Page, at offset: Int, size: Int, sideways: Bool = false, header: Int = 0, footer: Int = 0,
        draw: ((inout [UInt32], Int, Int) -> Void)? = nil
    ) -> [UInt32] {
        let width = sideways ? size : page.width
        let height = sideways ? page.height : size
        var pixels = [UInt32](repeating: white, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = sideways ? page.pixels[y * page.width + offset + x] : page.pixels[(offset + y) * page.width + x]
            }
        }
        // Bars: a colored band with a pattern that never moves.
        let along = sideways ? width : height
        for position in 0..<along {
            let inHeader = position < header
            let inFooter = position >= along - footer
            guard inHeader || inFooter else { continue }
            let across = sideways ? height : width
            for other in 0..<across {
                let color: UInt32 = inHeader ? 0xFF33_66CC ^ UInt32((other * 7 + position * 3) % 31) : 0xFF2A_2A2A ^ UInt32((other * 5 + position) % 17)
                if sideways { pixels[other * width + position] = color } else { pixels[position * width + other] = color }
            }
        }
        draw?(&pixels, width, height)
        return pixels
    }

    private static func stitcher(width: Int, height: Int, maxLength: Int = 50_000) -> ScrollStitcher {
        ScrollStitcher(width: width, height: height, pixelsPerPoint: 1, colorSpace: space, maxLength: maxLength)
    }

    @discardableResult
    private static func add(_ view: [UInt32], to stitcher: ScrollStitcher) -> ScrollStitcher.Step {
        view.withUnsafeBytes { stitcher.add($0.baseAddress!, bytesPerRow: stitcher.width * 4) }
    }

    /// The picture's pixels, BGRA, as numbers.
    private static func pixels(of image: CGImage) -> [UInt32] {
        var pixels = [UInt32](repeating: 0, count: image.width * image.height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    /// The rows of a picture `width` wide that differ from `expected`, ignoring the columns in `skipping`.
    private static func differingRows(_ pixels: [UInt32], _ expected: [UInt32], width: Int, skipping: Range<Int>? = nil) -> [Int] {
        guard pixels.count == expected.count else { return [-1] }
        return (0..<pixels.count / width).filter { y in
            (0..<width).contains { x in
                skipping?.contains(x) != true && pixels[y * width + x] != expected[y * width + x]
            }
        }
    }

    // MARK: - Down and up

    @Test func scrollingDownGivesThePage() throws {
        let page = Page(width: 400, height: 2400)
        let stitcher = Self.stitcher(width: 400, height: 300)
        var offset = 0
        #expect(Self.add(Self.view(page, at: offset, size: 300), to: stitcher) == .started)
        for step in [5, 40, 120, 1, 77, 260, 64, 3, 150] {
            offset += step
            #expect(Self.add(Self.view(page, at: offset, size: 300), to: stitcher) == .scrolled(offset: step), "step \(step)")
        }
        #expect(stitcher.axis == .vertical)
        let picture = try #require(stitcher.picture())
        #expect(picture.width == 400 && picture.height == offset + 300)
        let expected = Array(page.pixels[0 ..< (offset + 300) * 400])
        #expect(Self.differingRows(Self.pixels(of: picture), expected, width: 400).isEmpty, "\(stitcher.summary)")
    }

    @Test func scrollingUpGrowsThePictureAtTheTop() throws {
        let page = Page(width: 360, height: 2400)
        let stitcher = Self.stitcher(width: 360, height: 280)
        var offset = 1500
        Self.add(Self.view(page, at: offset, size: 280), to: stitcher)
        for step in [30, 200, 9, 111, 250, 2, 90] {
            offset -= step
            #expect(Self.add(Self.view(page, at: offset, size: 280), to: stitcher) == .scrolled(offset: -step), "step \(step)")
        }
        let picture = try #require(stitcher.picture())
        #expect(picture.height == 1500 + 280 - offset)
        let expected = Array(page.pixels[offset * 360 ..< (1500 + 280) * 360])
        #expect(Self.differingRows(Self.pixels(of: picture), expected, width: 360).isEmpty, "\(stitcher.summary)")
    }

    @Test func downThenUpThenDownKeepsOnePicture() throws {
        let page = Page(width: 300, height: 2400)
        let stitcher = Self.stitcher(width: 300, height: 260)
        var offset = 600
        Self.add(Self.view(page, at: offset, size: 260), to: stitcher)
        for step in [100, 100, -150, -200, -180, 90, 200, 200, 50] {
            offset += step
            #expect(Self.add(Self.view(page, at: offset, size: 260), to: stitcher) == .scrolled(offset: step), "step \(step)")
        }
        let picture = try #require(stitcher.picture())
        // From the highest view's top (600 - 330) to the lowest view's bottom (offset).
        let top = 600 + 200 - 530
        #expect(picture.height == offset + 260 - top, "\(picture.height) vs \(offset + 260 - top): \(stitcher.summary)")
        let expected = Array(page.pixels[top * 300 ..< (offset + 260) * 300])
        let rows = Self.differingRows(Self.pixels(of: picture), expected, width: 300)
        #expect(rows.isEmpty, "\(rows.prefix(5)) of \(rows.count): \(stitcher.summary)")
    }

    // MARK: - What stays put

    @Test func barsThatStayPutAreKeptOnce() throws {
        let page = Page(width: 400, height: 2400)
        let stitcher = Self.stitcher(width: 400, height: 320)
        var offset = 0
        let first = Self.view(page, at: offset, size: 320, header: 44, footer: 36)
        Self.add(first, to: stitcher)
        var last = first
        for step in [60, 13, 140, 90, 200, 7] {
            offset += step
            last = Self.view(page, at: offset, size: 320, header: 44, footer: 36)
            #expect(Self.add(last, to: stitcher) == .scrolled(offset: step), "step \(step)")
        }
        let picture = try #require(stitcher.picture())
        // The header as it was, the page that scrolled under the bars, the footer as it is.
        let expected = Array(first[0 ..< 44 * 400]) + Array(page.pixels[44 * 400 ..< (offset + 320 - 36) * 400]) + Array(last[(320 - 36) * 400 ..< 320 * 400])
        #expect(picture.height == expected.count / 400, "\(stitcher.summary)")
        #expect(Self.differingRows(Self.pixels(of: picture), expected, width: 400).isEmpty, "\(stitcher.summary)")
    }

    @Test func aBarWithPlainBandsIsNeverTakenForContent() throws {
        let page = Page(width: 600, height: 3000)
        let stitcher = Self.stitcher(width: 600, height: 400)
        // A bar as a toolbar is: one color, a title in its middle rows, plain rows above and below it.
        func bar(_ pixels: inout [UInt32], _ width: Int, _ height: Int) {
            for y in 0..<88 {
                for x in 0..<width { pixels[y * width + x] = 0xFF41_69C6 }
            }
            for y in 28..<60 {
                for x in 24..<220 where (x / 3 + y / 2) % 3 == 0 { pixels[y * width + x] = 0xFFFF_FFFF }
            }
        }
        var offset = 0
        let first = Self.view(page, at: offset, size: 400, draw: bar)
        Self.add(first, to: stitcher)
        // Steady steps, then a shorter last one, as at the end of a page.
        for step in [74, 74, 74, 74, 74, 64, 30, 10] {
            offset += step
            #expect(Self.add(Self.view(page, at: offset, size: 400, draw: bar), to: stitcher) == .scrolled(offset: step), "step \(step)")
        }
        let picture = try #require(stitcher.picture())
        let expected = Array(first[0 ..< 88 * 600]) + Array(page.pixels[88 * 600 ..< (offset + 400) * 600])
        #expect(picture.height == offset + 400, "\(stitcher.summary)")
        let rows = Self.differingRows(Self.pixels(of: picture), expected, width: 600)
        #expect(rows.isEmpty, "\(rows.count) rows from \(rows.first ?? -1): \(stitcher.summary)")
    }

    @Test func aBarWhosePatternRepeatsIsNeverTakenForContent() throws {
        // A bar the window server dithers: a pattern that repeats every 64 rows, as the capture showed one do.
        let page = Page(width: 600, height: 3000)
        let stitcher = Self.stitcher(width: 600, height: 400)
        func bar(_ pixels: inout [UInt32], _ width: Int, _ height: Int) {
            for y in 0..<88 {
                for x in 0..<width { pixels[y * width + x] = 0xFF41_69C6 &+ UInt32((x * 7 + (y % 64) * 13) % 3) }
            }
        }
        var offset = 0
        let first = Self.view(page, at: offset, size: 400, draw: bar)
        Self.add(first, to: stitcher)
        for step in [74, 74, 64, 74, 64] {
            offset += step
            #expect(Self.add(Self.view(page, at: offset, size: 400, draw: bar), to: stitcher) == .scrolled(offset: step), "step \(step)")
        }
        let picture = try #require(stitcher.picture())
        let expected = Array(first[0 ..< 88 * 600]) + Array(page.pixels[88 * 600 ..< (offset + 400) * 600])
        #expect(picture.height == offset + 400, "\(stitcher.summary)")
        let rows = Self.differingRows(Self.pixels(of: picture), expected, width: 600)
        #expect(rows.isEmpty, "\(rows.count) rows from \(rows.first ?? -1): \(stitcher.summary)")
    }

    /// A view of a page in a layout as a forum's: a sidebar on the left that never moves, the page beside it,
    /// and a badge stuck to the top of the page's part as a post's avatar sticks while the post scrolls.
    private static func forumView(_ page: Page, at offset: Int, height: Int, sidebar: Int) -> [UInt32] {
        let width = sidebar + page.width
        var pixels = [UInt32](repeating: white, count: width * height)
        for y in 0..<height {
            // The sidebar: items every 40 rows, the same in every view.
            if y % 40 >= 12 && y % 40 < 26 {
                for x in 16..<(sidebar - 24 - (y / 40 % 3) * 14) { pixels[y * width + x] = 0xFF5A_5A5A &+ UInt32((x + y) % 5) }
            }
            for x in 0..<page.width { pixels[y * width + sidebar + x] = page.pixels[(offset + y) * page.width + x] }
        }
        // The badge, stuck where it is.
        for y in 6..<40 {
            for x in sidebar + 10..<sidebar + 44 { pixels[y * width + x] = 0xFF2E_8B57 &+ UInt32((x * 3 + y) % 7) }
        }
        return pixels
    }

    @Test func aSidebarAndAStuckBadgeAppearOnce() throws {
        let page = Page(width: 400, height: 2400, seed: 11)
        let sidebar = 120, width = 520, height = 300
        let stitcher = Self.stitcher(width: width, height: height)
        var offset = 0
        let first = Self.forumView(page, at: offset, height: height, sidebar: sidebar)
        Self.add(first, to: stitcher)
        for step in [40, 75, 30, 120, 90, 60, 150, 25, 110] {
            offset += step
            #expect(Self.add(Self.forumView(page, at: offset, height: height, sidebar: sidebar), to: stitcher) == .scrolled(offset: step), "step \(step)")
        }
        let picture = try #require(stitcher.picture())
        #expect(picture.width == width && picture.height == offset + height, "\(stitcher.summary)")
        // The first view as it was; below it the sidebar's ground and the page, nothing of the badge.
        var expected = first
        for y in height..<offset + height {
            expected += [UInt32](repeating: Self.white, count: sidebar)
            expected += page.row(y)
        }
        let rows = Self.differingRows(Self.pixels(of: picture), expected, width: width)
        #expect(rows.isEmpty, "\(rows.count) rows from \(rows.first ?? -1): \(stitcher.summary)")
    }

    @Test func aSidebarOfSolidIconsKeepsAWhiteGround() throws {
        // Items every 12 rows, a solid icon in each: rows that fall in step with them would all show the icon.
        let page = Page(width: 400, height: 2400, seed: 13)
        let sidebar = 120, width = 520, height = 300
        func view(at offset: Int) -> [UInt32] {
            var pixels = [UInt32](repeating: Self.white, count: width * height)
            for y in 0..<height {
                if y % 12 < 4 {
                    for x in 16..<32 { pixels[y * width + x] = 0xFF59_5966 }
                    for x in 40..<(60 + y / 12 % 4 * 9) { pixels[y * width + x] = 0xFF40_4040 &+ UInt32((x * 3 + y) % 7) }
                }
                for x in 0..<page.width { pixels[y * width + sidebar + x] = page.pixels[(offset + y) * page.width + x] }
            }
            return pixels
        }
        let stitcher = Self.stitcher(width: width, height: height)
        var offset = 0
        let first = view(at: offset)
        Self.add(first, to: stitcher)
        for step in [26, 41, 19, 57, 33, 22, 48, 37, 29, 61] {
            offset += step
            #expect(Self.add(view(at: offset), to: stitcher) == .scrolled(offset: step), "step \(step)")
        }
        let picture = try #require(stitcher.picture())
        var expected = first
        for y in height..<offset + height {
            expected += [UInt32](repeating: Self.white, count: sidebar)
            expected += page.row(y)
        }
        let rows = Self.differingRows(Self.pixels(of: picture), expected, width: width)
        #expect(rows.isEmpty, "\(rows.count) rows from \(rows.first ?? -1): \(stitcher.summary)")
    }

    @Test func aStickyCardWithABlankInsideLeavesNoStripDownThePicture() throws {
        // A white card stuck over a gray sidebar, most of the view tall: labels down its left, a border around it,
        // nothing between the labels and its right edge; at the view's left edge a pixel a shade off the gray. Below
        // the first view the sidebar is the page's gray.
        let page = Page(width: 400, height: 2400, seed: 17)
        let sidebar = 120, width = 520, height = 300
        let gray: UInt32 = 0xFFF4_F5F7, border: UInt32 = 0xFFE3_E5E8
        func view(at offset: Int) -> [UInt32] {
            var pixels = [UInt32](repeating: gray, count: width * height)
            for y in 0..<height { pixels[y * width] = 0xFFF5_F6F8 }
            for y in 12...239 {
                for x in 8..<sidebar {
                    pixels[y * width + x] = y == 12 || y == 239 || x == 8 || x == sidebar - 1 ? border : Self.white
                }
                guard y >= 24, y < 228, (y - 24) % 18 < 10 else { continue }
                for x in 20..<(48 + (y - 24) / 18 % 3 * 7) where (x * 3 + y) % 5 < 3 { pixels[y * width + x] = 0xFF3A_3F47 }
            }
            for y in 0..<height {
                for x in 0..<page.width { pixels[y * width + sidebar + x] = page.pixels[(offset + y) * page.width + x] }
            }
            return pixels
        }
        let stitcher = Self.stitcher(width: width, height: height)
        var offset = 0
        let first = view(at: offset)
        Self.add(first, to: stitcher)
        for step in [31, 44, 18, 52, 27, 39, 23, 46, 35, 21, 58, 30] {
            offset += step
            #expect(Self.add(view(at: offset), to: stitcher) == .scrolled(offset: step), "step \(step)")
        }
        let picture = try #require(stitcher.picture())
        var expected = first
        for y in height..<offset + height {
            expected += [UInt32](repeating: gray, count: sidebar)
            expected += page.row(y)
        }
        let rows = Self.differingRows(Self.pixels(of: picture), expected, width: width, skipping: 0..<8)
        #expect(rows.isEmpty, "\(rows.count) rows from \(rows.first ?? -1): \(stitcher.summary)")
    }

    @Test func aSidebarHeldByItsFootLeavesNothingDownThePicture() throws {
        // A sidebar taller than the view, beside the posts, scrolls with them until its foot meets the view's, then
        // stays there, as a timeline's does: cards down it, a flat avatar on each, one color inside. Below its foot
        // the picture shows the page's white beside the posts, not pieces of the last avatars again and again.
        let page = Page(width: 400, height: 3000, seed: 23)
        let sidebar = 160, width = 560, height = 300, sidebarHeight = 520
        var panel = [UInt32](repeating: Self.white, count: sidebar * sidebarHeight)
        for card in 0..<8 {
            let top = 12 + card * 63
            for y in top ..< top + 40 {
                for x in 12..<44 where (x - 28) * (x - 28) + (y - top - 20) * (y - top - 20) <= 256 { panel[y * sidebar + x] = 0xFF33_33CC &+ UInt32(card * 0x1100) }
                guard y < top + 30, (y - top) % 10 < 7 else { continue }
                for x in 56..<(120 + card * 3) where (x * 7 + y * 3 + card) % 5 < 3 { panel[y * sidebar + x] = 0xFF22_2833 }
            }
        }
        func view(at offset: Int) -> [UInt32] {
            let top = min(offset, sidebarHeight - height)
            var pixels = [UInt32](repeating: Self.white, count: width * height)
            for y in 0..<height {
                for x in 0..<page.width { pixels[y * width + x] = page.pixels[(offset + y) * page.width + x] }
                for x in 0..<sidebar { pixels[y * width + page.width + x] = panel[(top + y) * sidebar + x] }
            }
            return pixels
        }
        let stitcher = Self.stitcher(width: width, height: height)
        var offset = 0
        let first = view(at: offset)
        Self.add(first, to: stitcher)
        for step in Array(repeating: [17, 23, 19, 26, 21], count: 21).joined() where offset < 2200 {
            offset += step
            #expect(Self.add(view(at: offset), to: stitcher) == .scrolled(offset: step), "step \(step) to \(offset)")
        }
        let picture = try #require(stitcher.picture())
        #expect(picture.height == offset + height)
        let pixels = Self.pixels(of: picture)
        // The posts are the page's throughout; the first view is as it was.
        let posts = (0..<picture.height).filter { y in (0..<page.width).contains { pixels[y * width + $0] != page.pixels[y * page.width + $0] } }
        #expect(posts.isEmpty, "\(posts.count) rows of posts off, from \(posts.first ?? -1)")
        #expect(Array(pixels[0 ..< height * width]) == first)
        // The sidebar as it scrolled, once: the view where it stopped partway through the scroll and the views it stayed
        // put in leave no avatar or name of it a little off where it was, nor down its cards.
        let sidebarOff = (0..<sidebarHeight).filter { y in (0..<sidebar).contains { pixels[y * width + page.width + $0] != panel[y * sidebar + $0] } }
        #expect(sidebarOff.isEmpty, "\(sidebarOff.count) rows of the sidebar off, from \(sidebarOff.first ?? -1)")
        // Below the sidebar's foot, nothing of it.
        let below = (sidebarHeight..<picture.height).filter { y in (page.width..<width).contains { pixels[y * width + $0] != Self.white } }
        #expect(below.isEmpty, "\(below.count) rows below the sidebar show some of it, from \(below.first ?? -1): \(stitcher.summary)")
    }

    @Test func aNavigationColumnKeepsItsButtonAsTheFirstViewShowedIt() throws {
        // A navigation column down the whole view beside the posts, as an X-like site has: dark, its labels never moving,
        // a flat pill-shaped button low among them. It is no button floating over the page: the picture shows it whole,
        // as the first view did, however many lines scrolled past it.
        let page = Page(width: 400, height: 2400, seed: 31)
        let left = 40, nav = 160, width = 600, height = 300
        let light: UInt32 = 0xFFEF_F3F4
        var column = [UInt32](repeating: 0xFF00_0000, count: nav * height)
        for item in 0..<6 {
            let top = 12 + item * 36
            for y in top ..< top + 14 {
                for x in 24 ..< 70 + item * 9 where (x * 7 + y * 3 + item) % 5 < 3 { column[y * nav + x] = 0xFFE7_E9EA }
            }
        }
        for y in 236..<268 {
            for x in 12..<150 {
                let dx = max(0, x - 134), dy = abs(2 * y - 503) / 2
                if dx * dx + dy * dy <= 16 * 16 { column[y * nav + x] = light }
            }
        }
        func view(at offset: Int) -> [UInt32] {
            var pixels = [UInt32](repeating: Self.white, count: width * height)
            for y in 0..<height {
                for x in 0..<nav { pixels[y * width + left + x] = column[y * nav + x] }
                for x in 0..<page.width { pixels[y * width + left + nav + x] = page.pixels[(offset + y) * page.width + x] }
            }
            return pixels
        }
        let stitcher = Self.stitcher(width: width, height: height)
        var offset = 0
        let first = view(at: offset)
        Self.add(first, to: stitcher)
        for step in Array(repeating: [11, 13, 9, 12], count: 30).joined() where offset < 1200 {
            offset += step
            #expect(Self.add(view(at: offset), to: stitcher) == .scrolled(offset: step), "step \(step) to \(offset)")
        }
        let picture = try #require(stitcher.picture())
        let pixels = Self.pixels(of: picture)
        let button = (236..<268).filter { y in (left ..< left + nav).contains { pixels[y * width + $0] != first[y * width + $0] } }
        #expect(button.isEmpty, "\(button.count) rows of the button off, from \(button.first ?? -1): \(stitcher.summary)")
    }

    @Test func aStuckTabIsNeverTakenIntoAStretchAlikeAllDownPassingUnderIt() throws {
        // A gray block, shaded left to right and alike all down (a stretch of a photo), in a page of text; above it a
        // purple tab, part of the page until it sticks a little below the view's top, as a site's tab bar does.
        // Passing under the tab the block's lines look the same where they were on screen; still, the picture shows
        // the block, never the tab.
        let width = 400, height = 300
        var page = Page(width: width, height: 2400, seed: 29)
        let purple: UInt32 = 0xFF4B_09F5
        func shade(_ x: Int) -> UInt32 { 0xFF00_0000 | UInt32(0xA8 + x % 16) * 0x010101 }
        for y in 700..<900 {
            for x in 60..<340 { page.pixels[y * width + x] = shade(x) }
        }
        func view(at offset: Int) -> [UInt32] {
            Self.view(page, at: offset, size: height) { pixels, width, height in
                let top = max(40, 240 - offset)
                for y in top ..< min(height, top + 40) {
                    for x in 150..<250 { pixels[y * width + x] = purple }
                }
            }
        }
        let stitcher = Self.stitcher(width: width, height: height)
        var offset = 0
        Self.add(view(at: offset), to: stitcher)
        for step in Array(repeating: [23, 17, 29, 21], count: 18).joined() where offset < 1300 {
            offset += step
            #expect(Self.add(view(at: offset), to: stitcher) == .scrolled(offset: step), "step \(step) to \(offset)")
        }
        let picture = try #require(stitcher.picture())
        let pixels = Self.pixels(of: picture)
        let tabbed = (700..<900).filter { y in (60..<340).contains { pixels[y * width + $0] != shade($0) } }
        #expect(tabbed.isEmpty, "\(tabbed.count) rows of the block show something else, from \(tabbed.first ?? -1): \(stitcher.summary)")
    }

    @Test func aBannerThatPopsUpLaterEndsUpOnlyAtTheEnd() throws {
        let page = Page(width: 400, height: 2400)
        let stitcher = Self.stitcher(width: 400, height: 300)
        var offset = 0
        Self.add(Self.view(page, at: offset, size: 300), to: stitcher)
        var last: [UInt32] = []
        for (index, step) in [40, 70, 30, 25, 120, 160, 90].enumerated() {
            offset += step
            // The banner covers the bottom 50 rows from the fourth view on.
            last = Self.view(page, at: offset, size: 300, footer: index >= 2 ? 50 : 0)
            #expect(Self.add(last, to: stitcher) == .scrolled(offset: step), "step \(step)")
        }
        let picture = try #require(stitcher.picture())
        let expected = Array(page.pixels[0 ..< (offset + 250) * 400]) + Array(last[250 * 400 ..< 300 * 400])
        #expect(picture.height == offset + 300, "\(stitcher.summary)")
        let rows = Self.differingRows(Self.pixels(of: picture), expected, width: 400)
        #expect(rows.isEmpty, "\(rows.count) rows: \(rows.prefix(3)) … \(rows.suffix(3)) of \(picture.height): \(stitcher.summary)")
    }

    /// A forum's topic as a forum lays it out: a header and a sidebar that never move, and posts whose avatars
    /// move with their post until they reach the header, stick below it while the post scrolls on, and are
    /// pushed out by the post's end. Every other avatar is a picture, the rest a plain disc with a letter.
    private struct Forum {
        static let avatarSize = 40
        static let header = 30
        static let sidebar = 100
        let page: Page
        /// The content rows of each post.
        let posts: [Range<Int>]
        var width: Int { Self.sidebar + page.width }

        init(height: Int = 2200) {
            var page = Page(width: 560, height: height, seed: 5)
            // The avatars' column is the posts' margin.
            for y in 0..<height {
                for x in 0..<56 { page.pixels[y * 560 + x] = ScrollStitcherTests.white }
            }
            self.page = page
            posts = [40 ..< 760, 780 ..< 900, 920 ..< 1700, 1720 ..< 1860, 1880 ..< height]
        }

        /// Where post `index`'s avatar is, on screen, with the content at `offset`.
        private func avatarTop(_ index: Int, at offset: Int) -> Int {
            let post = posts[index]
            return min(max(post.lowerBound + 8 - offset, Self.header + 6), post.upperBound - offset - Self.avatarSize)
        }

        /// Whether post `index`'s avatar shows whole where its post begins, with the content at `offset`.
        func avatarAtRest(_ index: Int, at offset: Int, height: Int) -> Bool {
            let top = avatarTop(index, at: offset)
            return top == posts[index].lowerBound + 8 - offset && top + Self.avatarSize <= height
        }

        /// Draws post `index`'s avatar with its top at row `top` of `pixels`, `width` wide, its left at `left`.
        private static func drawAvatar(_ index: Int, top: Int, left: Int, into pixels: inout [UInt32], width: Int, height: Int) {
            let size = avatarSize, radius = Double(size) / 2
            guard top < height, top + size > 0 else { return }
            for y in max(top, 0) ..< min(top + size, height) {
                for x in 0..<size {
                    let dx = Double(x) + 0.5 - radius, dy = Double(y - top) + 0.5 - radius
                    guard dx * dx + dy * dy <= radius * radius else { continue }
                    let color: UInt32
                    if index.isMultiple(of: 2) {
                        color = 0xFF00_0000 | UInt32((x * 37 + (y - top) * 91 + index * 53) % 0xFF) << 16 | UInt32((x * 13 + (y - top) * 7) % 0xFF) << 8 | 0x60
                    } else {
                        // A letter in a plain disc.
                        let letter = x >= 14 && x < 26 && y - top >= 10 && y - top < 30 && (x < 17 || y - top < 13)
                        color = letter ? ScrollStitcherTests.white : 0xFF3A_7BD5 &+ UInt32(index)
                    }
                    pixels[y * width + left + 8 + x] = color
                }
            }
        }

        /// The page as it is, each avatar where its post begins.
        func content() -> Page {
            var page = self.page
            for index in posts.indices {
                Self.drawAvatar(index, top: posts[index].lowerBound + 8, left: 0, into: &page.pixels, width: page.width, height: page.height)
            }
            return page
        }

        /// The view with the content at `offset`, `height` tall.
        func view(at offset: Int, height: Int) -> [UInt32] {
            let width = self.width
            var pixels = [UInt32](repeating: ScrollStitcherTests.white, count: width * height)
            for y in 0..<height {
                for x in 0..<page.width { pixels[y * width + Self.sidebar + x] = page.pixels[(offset + y) * page.width + x] }
            }
            for index in posts.indices {
                Self.drawAvatar(index, top: avatarTop(index, at: offset), left: Self.sidebar, into: &pixels, width: width, height: height)
            }
            for y in 0..<height {
                if y < Self.header {
                    for x in 0..<width { pixels[y * width + x] = 0xFF22_4488 ^ UInt32((x * 7 + y * 3) % 31) }
                } else if y % 36 >= 10 && y % 36 < 24 {
                    // The sidebar: the same item over and over.
                    for x in 14..<Self.sidebar - 20 { pixels[y * width + x] = 0xFF5A_5A5A &+ UInt32((x + y) % 5) }
                }
            }
            return pixels
        }

        /// The picture a capture from `first` that reached the page's top should make, `rows` long: the header,
        /// the first view's own rows, and below and above them the sidebar's ground beside the page as it is.
        func picture(first: Int, from start: Int, rows: Int, height: Int) -> [UInt32] {
            let width = self.width
            let content = content()
            let firstView = view(at: first, height: height)
            var expected: [UInt32] = []
            for row in 0..<rows {
                let y = start + row
                if row < Self.header {
                    expected += firstView[row * width ..< (row + 1) * width]
                } else if y >= first + Self.header, y < first + height {
                    expected += firstView[(y - first) * width ..< (y - first + 1) * width]
                } else {
                    expected += [UInt32](repeating: ScrollStitcherTests.white, count: Self.sidebar)
                    expected += content.row(y)
                }
            }
            return expected
        }
    }

    @Test func stickyAvatarsAppearOnceWherePostsBegin() throws {
        let forum = Forum()
        let height = 300
        let stitcher = Self.stitcher(width: forum.width, height: height)
        var offset = 0
        Self.add(forum.view(at: offset, height: height), to: stitcher)
        let steps = [12, 30, 25, 41, 18, 63, 35, 22, 51, 15, 70, 28, 45, 33, 20, 57, 9, 38]
        var index = 0
        while offset + height < forum.page.height {
            let step = min(steps[index % steps.count], forum.page.height - height - offset)
            index += 1
            offset += step
            let result = Self.add(forum.view(at: offset, height: height), to: stitcher)
            #expect(result == .scrolled(offset: step), "step \(step) to \(offset): \(result), \(stitcher.lostBecause)")
        }
        let picture = try #require(stitcher.picture())
        #expect(picture.width == forum.width && picture.height == offset + height, "\(stitcher.summary)")
        let expected = forum.picture(first: 0, from: 0, rows: offset + height, height: height)
        let rows = Self.differingRows(Self.pixels(of: picture), expected, width: forum.width)
        #expect(rows.isEmpty, "\(rows.count) rows: \(rows.prefix(4)) … \(rows.suffix(4)): \(stitcher.summary)")
    }

    @Test func takingThePictureMovesItOutWhole() throws {
        let forum = Forum()
        let height = 300
        let stitcher = Self.stitcher(width: forum.width, height: height)
        var offset = 0
        Self.add(forum.view(at: offset, height: height), to: stitcher)
        for step in [31, 54, 22, 68, 40, 17, 59, 36, 47, 25, 63, 38] {
            offset += step
            Self.add(forum.view(at: offset, height: height), to: stitcher)
        }
        let copied = try #require(stitcher.picture())
        let taken = try #require(stitcher.takePicture())
        #expect(taken.width == copied.width && taken.height == copied.height)
        #expect(Self.pixels(of: taken) == Self.pixels(of: copied))
        // Nothing more is taken in.
        #expect(Self.add(forum.view(at: offset + 30, height: height), to: stitcher) == .full)
    }

    @Test func scrollingUpIntoAStuckAvatar() throws {
        let forum = Forum()
        let height = 300
        let stitcher = Self.stitcher(width: forum.width, height: height)
        // Starts with the first post's avatar stuck below the header, then scrolls up to the top.
        let first = 520
        var offset = first
        Self.add(forum.view(at: offset, height: height), to: stitcher)
        for step in [14, 33, 27, 45, 19, 52, 31, 24, 61, 17, 40, 36, 29, 48, 22, 43] where offset > 0 {
            let moved = min(step, offset)
            offset -= moved
            #expect(Self.add(forum.view(at: offset, height: height), to: stitcher) == .scrolled(offset: -moved), "step \(moved) to \(offset)")
        }
        let picture = try #require(stitcher.picture())
        #expect(picture.width == forum.width && picture.height == first + height, "\(stitcher.summary)")
        let pixels = Self.pixels(of: picture)
        let expected = forum.picture(first: first, from: 0, rows: first + height, height: height)
        // The first view's own rows are as it showed them, stuck avatar and all; everything above them is the page.
        let rows = Self.differingRows(pixels, expected, width: forum.width).filter { $0 < first + Forum.header }
        #expect(rows.isEmpty, "\(rows.count) rows: \(rows.prefix(4)) … \(rows.suffix(4)): \(stitcher.summary)")
    }

    @Test func downThenUpThroughStickyAvatarsKeepsOnePicture() throws {
        let forum = Forum()
        let height = 300
        let stitcher = Self.stitcher(width: forum.width, height: height)
        var offset = 0
        Self.add(forum.view(at: offset, height: height), to: stitcher)
        for step in [23, 41, 17, 56, 30, 12, 64, 38, 26, 47, 19, 33, 58, 21, 44, 29, 36, 52, 15, 40, -27, -44, -18, -60, -33, -25, -51, -16, 39, 22, 47, 31] {
            offset += step
            #expect(Self.add(forum.view(at: offset, height: height), to: stitcher) == .scrolled(offset: step), "step \(step) to \(offset)")
        }
        let picture = try #require(stitcher.picture())
        let expected = forum.picture(first: 0, from: 0, rows: picture.height, height: height)
        // What the furthest view showed past its part that scrolls ends the picture as that view showed it.
        let rows = Self.differingRows(Self.pixels(of: picture), expected, width: forum.width).filter { $0 < picture.height - stitcher.tailLines }
        #expect(rows.isEmpty, "\(rows.count) rows: \(rows.prefix(4)) … \(rows.suffix(4)): \(stitcher.summary)")
    }

    @Test func tableEdgesKeepTheirLinesToTheEnd() throws {
        var page = Page(width: 400, height: 2400, seed: 3)
        // A table: edges down the whole page, and a rule every 24 rows.
        for y in 0..<page.height {
            for x in [40, 41, 210, 398] { page.pixels[y * 400 + x] = 0xFF30_3030 }
            if y % 24 == 0 { for x in 40..<399 { page.pixels[y * 400 + x] = 0xFFC0_C0C0 } }
        }
        let stitcher = Self.stitcher(width: 400, height: 300)
        var offset = 0
        Self.add(Self.view(page, at: offset, size: 300), to: stitcher)
        // Down, a little way back up (what last came into view at the bottom leaves the view unseen again), and
        // down again, ending a step short of a full view.
        for step in [24, 37, 48, 19, 72, 33, 24, 51, -36, -22, -48, 30, 66, 24, 41, 48] {
            offset += step
            #expect(Self.add(Self.view(page, at: offset, size: 300), to: stitcher) == .scrolled(offset: step), "step \(step)")
        }
        let picture = try #require(stitcher.picture())
        #expect(picture.height == offset + 300, "\(stitcher.summary)")
        let rows = Self.differingRows(Self.pixels(of: picture), Array(page.pixels[0 ..< (offset + 300) * 400]), width: 400)
        #expect(rows.isEmpty, "\(rows.count) rows: \(rows.prefix(4)) … \(rows.suffix(4)): \(stitcher.summary)")
    }

    @Test func aChatButtonInTheCornerIsLeftOut() throws {
        let page = Page(width: 400, height: 2400, seed: 9)
        let stitcher = Self.stitcher(width: 400, height: 300)
        // A round button fixed in the bottom right corner: a plain disc with a mark.
        func button(_ pixels: inout [UInt32], _ width: Int, _ height: Int) {
            for y in height - 64 ..< height - 16 {
                for x in width - 72 ..< width - 24 {
                    let dx = Double(x - (width - 48)) + 0.5, dy = Double(y - (height - 40)) + 0.5
                    guard dx * dx + dy * dy <= 24 * 24 else { continue }
                    pixels[y * width + x] = abs(dx) < 8 && abs(dy) < 3 ? ScrollStitcherTests.white : 0xFF1F_A35C
                }
            }
        }
        var offset = 0
        Self.add(Self.view(page, at: offset, size: 300, draw: button), to: stitcher)
        for step in [21, 34, 47, 18, 29, 55, 26, 38, 13, 44, 31, 60, 23, 36, 49, 27, 17, 42] {
            offset += step
            #expect(Self.add(Self.view(page, at: offset, size: 300, draw: button), to: stitcher) == .scrolled(offset: step), "step \(step)")
        }
        let picture = try #require(stitcher.picture())
        #expect(picture.height == offset + 300, "\(stitcher.summary)")
        // Between the first view's rows and the last view's, the page alone.
        let pixels = Self.pixels(of: picture)
        let rows = Self.differingRows(pixels, Array(page.pixels[0 ..< (offset + 300) * 400]), width: 400).filter { $0 >= 300 && $0 < offset }
        #expect(rows.isEmpty, "\(rows.count) rows: \(rows.prefix(4)) … \(rows.suffix(4)): \(stitcher.summary)")
    }

    @Test(arguments: 1...12) func forumScrolledEveryWhichWay(seed: Int) throws {
        let off = try Self.scrollAround(seed: seed, backAndForth: false)
        #expect(off == 0, "seed \(seed): \(off) rows off")
    }

    @Test(arguments: [8, 54, 72, 98, 102, 120]) func revisitingStickyAvatarsDoesNotLeaveFragments(seed: Int) throws {
        #expect(try Self.scrollAround(seed: seed, backAndForth: true) == 0)
    }

    /// A hundred and twenty more ways, going back four times in ten, for when the stitching changes:
    /// OMS_STITCH_SWEEP=1 swift test --filter manyMoreWays. Every visible avatar must survive without fragments.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMS_STITCH_SWEEP"] != nil))
    func manyMoreWays() throws {
        let off = try (1...120).map { ($0, try Self.scrollAround(seed: $0, backAndForth: true)) }.filter { $0.1 > 0 }
        print("Of 120 ways back and forth, \(off.count) left rows off: \(off.map { "seed \($0.0), \($0.1) rows" })")
        #expect(off.isEmpty, "seeds with rows off, and how many: \(off)")
    }

    /// Scrolls the forum about as `seed` says: down from its top, or up from inside a post (every third seed),
    /// going back now and then (`backAndForth`: four times in ten); in steps a trackpad makes, or in jumps (every
    /// other seed). The picture must be the page but for the first view's own rows, as that view showed them,
    /// the rows past the content at the end, as the furthest view showed them, and avatars never seen at rest,
    /// which nothing showed where they belong. How many rows are otherwise.
    private static func scrollAround(seed: Int, backAndForth: Bool) throws -> Int {
        let forum = Forum()
        let height = 300
        var state = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15
        func random(_ range: ClosedRange<Int>) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Int((state >> 33) % UInt64(range.count))
        }
        let upward = seed.isMultiple(of: 3), jumps = seed.isMultiple(of: 2)
        let stitcher = Self.stitcher(width: forum.width, height: height)
        let start = upward ? random(100...900) : 0
        var offset = start, top = start
        var visited = [start]
        Self.add(forum.view(at: offset, height: height), to: stitcher)
        for _ in 0 ..< (jumps ? 70 : 200) {
            let back = random(0...9) < (backAndForth ? 4 : 2)
            let up = upward != back
            let step = jumps ? random(3...80) : random(2...24)
            let next = up ? max(0, offset - step) : min(forum.page.height - height, offset + step)
            guard next != offset else { continue }
            let result = Self.add(forum.view(at: next, height: height), to: stitcher)
            guard result == .scrolled(offset: next - offset) else {
                Issue.record("seed \(seed): \(result) for \(next - offset) at \(offset)")
                return .max
            }
            offset = next
            top = min(top, offset)
            visited.append(offset)
        }
        let picture = try #require(stitcher.picture())
        let expected = forum.picture(first: start, from: top, rows: picture.height, height: height)
        let unseen = forum.posts.indices.filter { index in
            !visited.contains { forum.avatarAtRest(index, at: $0, height: height) }
        }.map { forum.posts[$0].lowerBound + 8 ..< forum.posts[$0].lowerBound + 8 + Forum.avatarSize }
        let pixels = Self.pixels(of: picture)
        let rows = Self.differingRows(pixels, expected, width: forum.width).filter { row in
            let y = top + row
            return row >= Forum.header && !(y >= start + Forum.header && y < start + height) && row < picture.height - stitcher.tailLines
                && !unseen.contains { $0.contains(y) }
        }
        return rows.count
    }

    // MARK: - What moves on its own

    @Test func anAnimatedImageDoesNotMoveTheWholePage() throws {
        let page = Page(width: 1200, height: 1600)
        let stitcher = Self.stitcher(width: 1200, height: 400)
        let image = Page(width: 400, height: 300, seed: 99)
        func frame(_ phase: Int) -> [UInt32] {
            Self.view(page, at: 0, size: 400) { pixels, width, _ in
                // A moving picture spanning two hash bands, surrounded by stationary forum text.
                for y in 130..<250 {
                    for x in 400..<800 { pixels[y * width + x] = image.pixels[(y - 130 + phase) * 400 + x - 400] }
                }
            }
        }
        Self.add(frame(0), to: stitcher)
        for phase in [5, 12, 21, 35] {
            #expect(Self.add(frame(phase), to: stitcher) == .unchanged)
        }
        #expect(stitcher.axis == nil)
        #expect(try #require(stitcher.picture()).height == 400)
    }

    @Test func aTimelineWithAMovingHandleDoesNotRepeatDownThePicture() throws {
        let width = 1200, height = 500
        var page = Page(width: width, height: 3000)
        for y in 0..<page.height {
            for x in 1040..<width { page.pixels[y * width + x] = Self.white }
        }
        func frame(_ offset: Int) -> [UInt32] {
            Self.view(page, at: offset, size: height) { pixels, width, _ in
                for y in 70..<420 {
                    for x in 1118..<1122 { pixels[y * width + x] = 0xFFDD_DDDD }
                }
                let start = 85 + offset / 16
                for y in start..<start + 150 {
                    for x in 1116..<1124 { pixels[y * width + x] = 0xFF67_ABDE }
                }
            }
        }
        let stitcher = Self.stitcher(width: width, height: height)
        let first = frame(0)
        Self.add(first, to: stitcher)
        var offset = 0
        for step in Array(repeating: [43, 87, 35, 120, 62, 19], count: 4).joined() {
            offset += step
            #expect(Self.add(frame(offset), to: stitcher) == .scrolled(offset: step))
        }
        let picture = try #require(stitcher.picture())
        let expected = first + Array(page.pixels[height * width ..< (offset + height) * width])
        #expect(Self.differingRows(Self.pixels(of: picture), expected, width: width).isEmpty)
    }

    @Test func flatBordersInAFixedSidebarDoNotLeaveHorizontalFragments() throws {
        let width = 1200, height = 500
        var page = Page(width: width, height: 2600)
        let black: UInt32 = 0xFF00_0000
        for y in 0..<page.height {
            for x in 0..<width {
                if x < 220 || x >= 880 || page.pixels[y * width + x] == Self.white { page.pixels[y * width + x] = black }
            }
        }
        func frame(_ offset: Int) -> [UInt32] {
            Self.view(page, at: offset, size: height) { pixels, width, _ in
                // X-like cards: long one-pixel borders across mostly blank columns, with short labels.
                for top in [36, 232] {
                    let bottom = top + 180
                    for y in top...bottom {
                        for x in 914...1180 where y == top || y == bottom || x == 914 || x == 1180 {
                            pixels[y * width + x] = 0xFF2F_3336
                        }
                    }
                    for y in top + 20 ..< top + 32 {
                        for x in 938..<1010 where (x + y) % 5 < 3 { pixels[y * width + x] = 0xFF99_AABB }
                    }
                }
            }
        }
        let first = frame(0)
        let stitcher = Self.stitcher(width: width, height: height)
        Self.add(first, to: stitcher)
        var offset = 0
        for step in Array(repeating: [14, 48, 96, 31, 73, 42], count: 4).joined() {
            offset += step
            #expect(Self.add(frame(offset), to: stitcher) == .scrolled(offset: step))
        }
        let picture = try #require(stitcher.picture())
        let expected = first + Array(page.pixels[height * width ..< (offset + height) * width])
        #expect(Self.differingRows(Self.pixels(of: picture), expected, width: width).isEmpty)
    }

    @Test func aTemporaryShadowAtTheFirstViewportEdgeIsRepaired() throws {
        let page = Page(width: 600, height: 1600)
        let stitcher = Self.stitcher(width: 600, height: 300)
        let first = Self.view(page, at: 0, size: 300) { pixels, width, _ in
            for y in 225..<270 {
                for x in 100..<500 {
                    let color = pixels[y * width + x]
                    pixels[y * width + x] = 0xFF00_0000 | ((color >> 16 & 255) * 3 / 4) << 16
                        | ((color >> 8 & 255) * 3 / 4) << 8 | (color & 255) * 3 / 4
                }
            }
        }
        Self.add(first, to: stitcher)
        var offset = 0
        for step in [30, 24, 41, 17, 35, 29] {
            offset += step
            #expect(Self.add(Self.view(page, at: offset, size: 300), to: stitcher) == .scrolled(offset: step))
        }
        let picture = try #require(stitcher.picture())
        #expect(Self.differingRows(Self.pixels(of: picture), Array(page.pixels.prefix((offset + 300) * 600)), width: 600).isEmpty)
    }

    @Test func aWhiteImageLoadingOnADarkPageDoesNotAcquireBlackNotches() throws {
        var page = Page(width: 600, height: 1200)
        for index in page.pixels.indices where page.pixels[index] == Self.white { page.pixels[index] = 0xFF00_0000 }
        for y in 210..<800 { for x in 180..<420 { page.pixels[y * 600 + x] = Self.white } }
        let first = Self.view(page, at: 0, size: 300)
        // The image's text finishes loading between two frames, while its white surface stays visible.
        for y in 258..<276 { for x in 220..<380 { page.pixels[y * 600 + x] = 0xFF00_0000 } }
        let stitcher = Self.stitcher(width: 600, height: 300)
        Self.add(first, to: stitcher)
        #expect(Self.add(Self.view(page, at: 30, size: 300), to: stitcher) == .scrolled(offset: 30))
        let picture = try #require(stitcher.picture())
        #expect(Self.differingRows(Self.pixels(of: picture), Array(page.pixels.prefix(330 * 600)), width: 600).isEmpty)
    }

    @Test func aPartlyRepaintedFrameDoesNotBecomeTheScrollReference() throws {
        let page = Page(width: 1200, height: 1600)
        let stitcher = Self.stitcher(width: 1200, height: 400)
        let first = Self.view(page, at: 0, size: 400)
        Self.add(first, to: stitcher)
        let previous = Self.view(page, at: 20, size: 400)
        #expect(Self.add(previous, to: stitcher) == .scrolled(offset: 20))
        var torn = Self.view(page, at: 50, size: 400)
        // Some browser tiles still show the old offset, others the next offset: neither is a full view.
        for y in 0..<400 {
            for x in 600..<1200 { torn[y * 1200 + x] = previous[y * 1200 + x] }
        }
        let step = Self.add(torn, to: stitcher)
        #expect(step == .lost || step == .unchanged)
        #expect(Self.add(Self.view(page, at: 50, size: 400), to: stitcher) == .scrolled(offset: 30))
        let picture = try #require(stitcher.picture())
        #expect(picture.height == 450)
        #expect(Self.differingRows(Self.pixels(of: picture), Array(page.pixels.prefix(450 * 1200)), width: 1200).isEmpty)
    }

    @Test func somethingAnimatingInTheViewDoesNotStopIt() throws {
        let page = Page(width: 400, height: 2400)
        let stitcher = Self.stitcher(width: 400, height: 300)
        var offset = 0
        var frame = 0
        // A spinner fixed on screen, a new picture in every view; and a caret blinking in the content.
        func spinning(_ pixels: inout [UInt32], _ width: Int, _ height: Int) {
            frame += 1
            for y in 120..<160 {
                for x in 180..<220 { pixels[y * width + x] = 0xFF00_0000 | UInt32((x * 31 + y * 17 + frame * 97) % 0xFFFFFF) }
            }
        }
        Self.add(Self.view(page, at: offset, size: 300, draw: spinning), to: stitcher)
        for step in [50, 80, 33, 120, 75, 200] {
            offset += step
            #expect(Self.add(Self.view(page, at: offset, size: 300, draw: spinning), to: stitcher) == .scrolled(offset: step), "step \(step)")
        }
        let picture = try #require(stitcher.picture())
        #expect(picture.height == offset + 300, "\(stitcher.summary)")
        let pixels = Self.pixels(of: picture)
        let expected = Array(page.pixels[0 ..< (offset + 300) * 400])
        // Only the spinner's columns may differ.
        #expect(Self.differingRows(pixels, expected, width: 400, skipping: 180..<220).isEmpty, "\(stitcher.summary)")
    }

    @Test func anOverlayScrollBarIsLeftOutOfThePicture() throws {
        let page = Page(width: 400, height: 2400)
        let stitcher = Self.stitcher(width: 400, height: 300)
        var offset = 0
        // The knob shows once the scrolling starts, where the scroll has got to, and fades once it stops.
        func knob(at offset: Int) -> (inout [UInt32], Int, Int) -> Void {
            { pixels, width, height in
                let top = offset * (height - 40) / 2100
                for y in top..<top + 40 {
                    for x in width - 14..<width - 3 { pixels[y * width + x] = 0xFF80_8080 }
                }
            }
        }
        Self.add(Self.view(page, at: offset, size: 300), to: stitcher)
        while offset < 1400 {
            offset += 23
            #expect(Self.add(Self.view(page, at: offset, size: 300, draw: knob(at: offset)), to: stitcher) == .scrolled(offset: 23))
        }
        // Faded: only the ends of the lines changed.
        #expect(Self.add(Self.view(page, at: offset, size: 300), to: stitcher) == .unchanged)
        let picture = try #require(stitcher.picture())
        #expect(picture.height == offset + 300)
        let expected = Array(page.pixels[0 ..< (offset + 300) * 400])
        let rows = Self.differingRows(Self.pixels(of: picture), expected, width: 400)
        #expect(rows.isEmpty, "\(rows.count) rows with the knob, from \(rows.first ?? -1): \(stitcher.summary)")
    }

    @Test(arguments: [false, true]) func rowNumbersStayWithTheirRowsWhereTheCellsAreAlike(besideASidebar: Bool) throws {
        // A sheet: words down its first rows, then empty cells alike every 20 rows; down the line's left end, each
        // row's number. Among the empty cells a view 40 rows on shows between the ends just what the last one did,
        // and beside a sidebar that stays put, a line of its own on every row, so does the whole of it there.
        let width = 400, height = 300
        var page = Page(width: width, height: 2400, seed: 19)
        for y in 0..<page.height {
            for x in 0..<width {
                if y >= 700 { page.pixels[y * width + x] = y % 20 == 0 || x % 50 == 25 ? 0xFFD0_D4D8 : Self.white }
                if x < 16 { page.pixels[y * width + x] = (2..<14).contains(x) ? 0xFF00_0000 | UInt32(y & 0xFF) << 8 | UInt32(y >> 8) : Self.white }
            }
        }
        func view(at offset: Int) -> [UInt32] {
            Self.view(page, at: offset, size: height) { pixels, width, height in
                guard besideASidebar else { return }
                for y in 0..<height {
                    for x in 24..<104 { pixels[y * width + x] = (x + y) % 3 == 0 ? 0xFF40_0000 | UInt32(y) : 0xFFF2_F3F5 }
                }
            }
        }
        let stitcher = Self.stitcher(width: width, height: height)
        Self.add(view(at: 0), to: stitcher)
        for offset in stride(from: 40, through: 1400, by: 40) {
            Self.add(view(at: offset), to: stitcher)
        }
        // However far the picture got, what it has is the page's, numbers and all (the sidebar aside).
        let picture = try #require(stitcher.picture())
        #expect(picture.height > 700)
        let expected = Array(page.pixels[0 ..< picture.height * width])
        let rows = Self.differingRows(Self.pixels(of: picture), expected, width: width, skipping: besideASidebar ? 16..<width : nil)
        #expect(rows.isEmpty, "\(rows.count) rows from \(rows.first ?? -1): \(stitcher.summary)")
    }

    // MARK: - Lost and still

    @Test func scrollingTooFarAtOnceIsLostUntilTheViewComesBack() throws {
        let page = Page(width: 400, height: 2400)
        let stitcher = Self.stitcher(width: 400, height: 300)
        Self.add(Self.view(page, at: 0, size: 300), to: stitcher)
        #expect(Self.add(Self.view(page, at: 50, size: 300), to: stitcher) == .scrolled(offset: 50))
        #expect(Self.add(Self.view(page, at: 1500, size: 300), to: stitcher) == .lost)
        #expect(Self.add(Self.view(page, at: 900, size: 300), to: stitcher) == .lost)
        // Back where it overlaps the last view taken in.
        #expect(Self.add(Self.view(page, at: 200, size: 300), to: stitcher) == .scrolled(offset: 150))
        #expect(Self.add(Self.view(page, at: 400, size: 300), to: stitcher) == .scrolled(offset: 200))
        let picture = try #require(stitcher.picture())
        let expected = Array(page.pixels[0 ..< 700 * 400])
        #expect(Self.differingRows(Self.pixels(of: picture), expected, width: 400).isEmpty, "\(stitcher.summary)")
    }

    @Test func scrollingBackToWhatWasCapturedPicksUpThere() throws {
        let page = Page(width: 400, height: 2400)
        let stitcher = Self.stitcher(width: 400, height: 300)
        var offset = 0
        Self.add(Self.view(page, at: offset, size: 300), to: stitcher)
        while offset < 1200 {
            offset += 100
            Self.add(Self.view(page, at: offset, size: 300), to: stitcher)
        }
        // Back up past the last view, to a part taken in long before: found there.
        #expect(Self.add(Self.view(page, at: 400, size: 300), to: stitcher) == .scrolled(offset: -800))
        // Nowhere it has been: lost.
        #expect(Self.add(Self.view(page, at: 2000, size: 300), to: stitcher) == .lost)
        #expect(Self.add(Self.view(page, at: 480, size: 300), to: stitcher) == .scrolled(offset: 80))
        let picture = try #require(stitcher.picture())
        let expected = Array(page.pixels[0 ..< 1500 * 400])
        #expect(picture.height == 1500, "\(stitcher.summary)")
        #expect(Self.differingRows(Self.pixels(of: picture), expected, width: 400).isEmpty, "\(stitcher.summary)")
    }

    @Test func aViewThatDidNotScrollIsUnchanged() throws {
        let page = Page(width: 400, height: 1200)
        let stitcher = Self.stitcher(width: 400, height: 300)
        let view = Self.view(page, at: 100, size: 300)
        Self.add(view, to: stitcher)
        #expect(Self.add(view, to: stitcher) == .unchanged)
        // A caret blinks; a button lights up under the pointer: nothing moved.
        let caret = Self.view(page, at: 100, size: 300) { pixels, width, _ in
            for y in 50..<66 { pixels[y * width + 200] = 0xFF00_0000 }
        }
        #expect(Self.add(caret, to: stitcher) == .unchanged)
        let hover = Self.view(page, at: 100, size: 300) { pixels, width, _ in
            for y in 200..<236 { for x in 40..<160 { pixels[y * width + x] = 0xFFDD_E8FF } }
        }
        #expect(Self.add(hover, to: stitcher) == .unchanged)
        #expect(stitcher.axis == nil)
        // Nothing scrolled: the picture is the first view.
        let picture = try #require(stitcher.picture())
        #expect(picture.height == 300 && Self.pixels(of: picture) == view)
    }

    // MARK: - Pages that move on their own

    @Test func aPlayingVideoDoesNotStopTheCapture() throws {
        // A video 240 rows tall in the page, a new picture in every view: more than half the view as it passes.
        let page = Page(width: 1200, height: 2400)
        let video = 900..<1140
        let stitcher = Self.stitcher(width: 1200, height: 400)
        var frame = 0
        func playing(at offset: Int) -> (inout [UInt32], Int, Int) -> Void {
            { pixels, width, height in
                frame += 1
                for y in 0..<height where video.contains(offset + y) {
                    for x in 60..<1140 {
                        pixels[y * width + x] = 0xFF00_0000 | UInt32(truncatingIfNeeded: (x &* 7919 &+ (offset + y) &* 104_729 &+ frame &* 97) % 0xFF_FFFF)
                    }
                }
            }
        }
        var offset = 0
        Self.add(Self.view(page, at: offset, size: 400, draw: playing(at: offset)), to: stitcher)
        while offset < 1900 {
            offset += 25
            #expect(Self.add(Self.view(page, at: offset, size: 400, draw: playing(at: offset)), to: stitcher) == .scrolled(offset: 25), "at \(offset)")
        }
        let picture = try #require(stitcher.picture())
        #expect(picture.height == offset + 400, "\(stitcher.summary)")
        // Above and below the video, the page as it is.
        let rows = Self.differingRows(Self.pixels(of: picture), Array(page.pixels[0 ..< (offset + 400) * 1200]), width: 1200).filter { !video.contains($0) }
        #expect(rows.isEmpty, "\(rows.count) rows from \(rows.first ?? -1): \(stitcher.summary)")
    }

    /// The view at the page's end, the content pulled `pull` rows on past it under a bar 30 rows tall, itself pulled
    /// `bar` rows along: the page's background shows below it, as a browser's elastic overscroll shows it (pulled
    /// far enough, a sticky header goes along).
    private static func pulled(_ page: Page, at offset: Int, size: Int, by pull: Int, bar: Int = 0) -> [UInt32] {
        view(page, at: offset, size: size) { pixels, width, height in
            for y in 0..<height {
                let row = offset + y + pull
                let position = y + bar
                for x in 0..<width {
                    pixels[y * width + x] = position < 30 ? 0xFF33_66CC ^ UInt32((x * 7 + position * 3) % 31)
                        : row < page.height ? page.pixels[row * page.width + x] : white
                }
            }
        }
    }

    @Test func pullingPastTheEndLeavesNothingBehind() throws {
        let page = Page(width: 600, height: 1000)
        let stitcher = Self.stitcher(width: 600, height: 300)
        Self.add(Self.view(page, at: 0, size: 300, header: 30), to: stitcher)
        var offset = 0
        while offset < 700 {
            offset = min(700, offset + 40)
            Self.add(Self.view(page, at: offset, size: 300, header: 30), to: stitcher)
        }
        let settled = stitcher.pictureSize.height
        #expect(settled == 1000, "\(stitcher.summary)")
        // Pushed on by Auto-scroll: pulled on a pixel or two at a time, then springing back.
        stitcher.isDriven = true
        for pull in [1, 2, 3, 4, 6, 8, 10, 12, 13, 14, 9, 5, 2, 0] {
            Self.add(Self.pulled(page, at: 700, size: 300, by: pull), to: stitcher)
        }
        let picture = try #require(stitcher.picture())
        #expect(picture.height == settled, "\(stitcher.summary)")
        let rows = Self.differingRows(Self.pixels(of: picture), Array(page.pixels.prefix(1000 * 600)), width: 600).filter { $0 >= 30 }
        #expect(rows.isEmpty, "\(rows.count) rows from \(rows.first ?? -1): \(stitcher.summary)")
    }

    @Test func pullingPastTheEndThenTrimmedLeavesNothingBehind() throws {
        // Still pulled when the capture ends, as Auto-scroll leaves it when it finds the end: trimmed.
        let page = Page(width: 600, height: 1000)
        let stitcher = Self.stitcher(width: 600, height: 300)
        Self.add(Self.view(page, at: 0, size: 300, header: 30), to: stitcher)
        var offset = 0
        while offset < 700 {
            offset = min(700, offset + 40)
            Self.add(Self.view(page, at: offset, size: 300, header: 30), to: stitcher)
        }
        stitcher.isDriven = true
        for pull in 1...12 { Self.add(Self.pulled(page, at: 700, size: 300, by: pull), to: stitcher) }
        #expect(stitcher.isPulled)
        #expect(stitcher.settledLength == 1000, "\(stitcher.summary)")
        stitcher.trimOverscroll()
        #expect(try #require(stitcher.picture()).height == 1000, "\(stitcher.summary)")
    }

    @Test func aTrimmedPullDoesNotComeBackWithALaggingView() throws {
        // Pulled on, the header goes along with the content: views no longer taken in, the last one taken in left
        // further and further behind. Auto-scroll stops there and the pull is trimmed; a view pulled on still, against
        // that old one, must not take the background back into the picture, nor the views springing back.
        let page = Page(width: 600, height: 1000)
        let stitcher = Self.stitcher(width: 600, height: 300)
        Self.add(Self.view(page, at: 0, size: 300, header: 30), to: stitcher)
        var offset = 0
        while offset < 700 {
            offset = min(700, offset + 40)
            Self.add(Self.view(page, at: offset, size: 300, header: 30), to: stitcher)
        }
        stitcher.isDriven = true
        for pull in 1...12 { Self.add(Self.pulled(page, at: 700, size: 300, by: pull), to: stitcher) }
        for pull in 13...40 { Self.add(Self.pulled(page, at: 700, size: 300, by: pull, bar: pull - 12), to: stitcher) }
        #expect(stitcher.isPulled)
        stitcher.trimOverscroll()
        stitcher.isDriven = false
        #expect(stitcher.pictureSize.height == 1000, "\(stitcher.summary)")
        Self.add(Self.pulled(page, at: 700, size: 300, by: 41, bar: 29), to: stitcher)
        #expect(stitcher.pictureSize.height == 1000, "\(stitcher.summary)")
        for pull in [30, 20, 12, 6, 2, 0] { Self.add(Self.pulled(page, at: 700, size: 300, by: pull, bar: max(0, pull - 12)), to: stitcher) }
        let picture = try #require(stitcher.picture())
        #expect(picture.height == 1000, "\(stitcher.summary)")
        let rows = Self.differingRows(Self.pixels(of: picture), Array(page.pixels.prefix(1000 * 600)), width: 600).filter { $0 >= 30 }
        #expect(rows.isEmpty, "\(rows.count) rows from \(rows.first ?? -1): \(stitcher.summary)")
        // Taken in again afterwards, scrolling back up.
        #expect(Self.add(Self.view(page, at: 600, size: 300, header: 30), to: stitcher) == .scrolled(offset: -100))
    }

    @Test func slowlyScrollingThroughBlankRowsKeepsThem() throws {
        // Two rows at a time into the blank end of a page, as the slowest Auto-scroll or a careful hand scrolls.
        var page = Page(width: 600, height: 1200)
        for y in 800..<1200 {
            for x in 0..<600 { page.pixels[y * 600 + x] = Self.white }
        }
        let stitcher = Self.stitcher(width: 600, height: 300)
        var offset = 0
        Self.add(Self.view(page, at: offset, size: 300), to: stitcher)
        while offset < 700 {
            offset += 2
            Self.add(Self.view(page, at: offset, size: 300), to: stitcher)
        }
        let picture = try #require(stitcher.picture())
        #expect(picture.height == 1000, "\(stitcher.summary)")
        #expect(Self.differingRows(Self.pixels(of: picture), Array(page.pixels.prefix(1000 * 600)), width: 600).isEmpty, "\(stitcher.summary)")
    }

    /// A page with a code block 240 rows tall at rows 400 to 640, scrolled `inner` rows within itself: its lines
    /// dense, every row unlike the others, as code is beside the page's text.
    private static func withCodeBlock(_ page: Page, at offset: Int, inner: Int) -> [UInt32] {
        view(page, at: offset, size: 500) { pixels, width, height in
            for y in 0..<height where (400..<640).contains(offset + y) {
                let row = offset + y - 400 + inner
                for x in 0..<width {
                    pixels[y * width + x] = x < 40 || x >= 760 ? white : 0xFF00_0000 | UInt32(truncatingIfNeeded: (x / 3 &* 7919 &+ row &* 104_729) % 0xFF_FFFF)
                }
            }
        }
    }

    @Test func aScrollerInsideThePageIsLeftOutWhileAutoScrollPushesIt() throws {
        // Auto-scroll's gesture lands on the code block: it scrolls alone, beside text that stays put. Left out; then
        // the gesture moves above it and the page scrolls, the block as it was left.
        let page = Page(width: 800, height: 2000)
        let stitcher = Self.stitcher(width: 800, height: 500)
        stitcher.isDriven = true
        stitcher.drivenAt = CGPoint(x: 0.5, y: 0.5)
        #expect(Self.add(Self.withCodeBlock(page, at: 270, inner: 0), to: stitcher) == .started)
        for inner in stride(from: 20, through: 80, by: 20) {
            #expect(Self.add(Self.withCodeBlock(page, at: 270, inner: inner), to: stitcher) == .unchanged, "inner \(inner)")
            let part = try #require(stitcher.innerPart, "inner \(inner)")
            #expect(part.contains(CGPoint(x: 0.5, y: 0.5)) && part.minY > 0.2 && part.maxY < 0.8, "\(part)")
        }
        #expect(stitcher.pictureSize.height == 500)
        // The block takes the gesture's last moves as the page starts to scroll: against the view from before, it
        // moves further than the page, and must not be taken for it.
        stitcher.drivenAt = CGPoint(x: 0.5, y: 0.13)
        var scrolled = 0
        for offset in stride(from: 290, through: 1490, by: 20) {
            let step = Self.add(Self.withCodeBlock(page, at: offset, inner: min(120, 80 + (offset - 270))), to: stitcher)
            if case .scrolled(let by) = step { scrolled += by } else { #expect(step == .unchanged && offset <= 330, "at \(offset): \(step)") }
        }
        #expect(scrolled == 1490 - 270)
        let picture = try #require(stitcher.picture())
        #expect(picture.height == 1490 - 270 + 500, "\(stitcher.summary)")
        // Beside the block, the page as it is: nothing of the text above it twice.
        let rows = Self.differingRows(Self.pixels(of: picture), Array(page.pixels[270 * 800 ..< 1990 * 800]), width: 800)
            .filter { !(130..<370).contains($0) }
        #expect(rows.isEmpty, "\(rows.count) rows from \(rows.first ?? -1): \(stitcher.summary)")
    }

    @Test func aScrollerInsideThePageScrollingOnceMoreAfterTheGestureMovedIsLeftOut() throws {
        // The gesture's last move reaches the block after it moved above it: the block alone, once more.
        let page = Page(width: 800, height: 2000)
        let stitcher = Self.stitcher(width: 800, height: 500)
        stitcher.isDriven = true
        stitcher.drivenAt = CGPoint(x: 0.5, y: 0.5)
        Self.add(Self.withCodeBlock(page, at: 270, inner: 0), to: stitcher)
        for inner in [20, 40] { #expect(Self.add(Self.withCodeBlock(page, at: 270, inner: inner), to: stitcher) == .unchanged) }
        stitcher.drivenAt = CGPoint(x: 0.5, y: 0.13)
        #expect(Self.add(Self.withCodeBlock(page, at: 270, inner: 60), to: stitcher) == .unchanged)
        var scrolled = 0
        for offset in stride(from: 290, through: 990, by: 20) {
            if case .scrolled(let by) = Self.add(Self.withCodeBlock(page, at: offset, inner: 60), to: stitcher) { scrolled += by }
        }
        #expect(scrolled == 990 - 270)
        let picture = try #require(stitcher.picture())
        #expect(picture.height == 990 - 270 + 500, "\(stitcher.summary)")
        let rows = Self.differingRows(Self.pixels(of: picture), Array(page.pixels[270 * 800 ..< 1490 * 800]), width: 800)
            .filter { !(130..<370).contains($0) }
        #expect(rows.isEmpty, "\(rows.count) rows from \(rows.first ?? -1): \(stitcher.summary)")
    }

    @Test func aShortMiddleBetweenBarsIsTakenInOnceTheGestureMovedOntoABar() throws {
        // A header and a footer that stay put leave less than three quarters of the view to the page: under the
        // gesture, it looks like a scroller inside the page at first. On the header, the page goes on scrolling, and
        // all of it is taken in.
        let page = Page(width: 800, height: 2400)
        let stitcher = Self.stitcher(width: 800, height: 500)
        stitcher.isDriven = true
        stitcher.drivenAt = CGPoint(x: 0.5, y: 0.5)
        Self.add(Self.view(page, at: 0, size: 500, header: 70, footer: 80), to: stitcher)
        #expect(Self.add(Self.view(page, at: 20, size: 500, header: 70, footer: 80), to: stitcher) == .unchanged)
        #expect(stitcher.innerPart != nil)
        stitcher.drivenAt = CGPoint(x: 0.5, y: 0.07)
        var offset = 20
        while offset < 1500 {
            offset += 20
            Self.add(Self.view(page, at: offset, size: 500, header: 70, footer: 80), to: stitcher)
        }
        let picture = try #require(stitcher.picture())
        #expect(picture.height == offset + 500, "\(stitcher.summary)")
        let pixels = Self.pixels(of: picture)
        let content = Array(pixels[70 * 800 ..< (picture.height - 80) * 800])
        let rows = Self.differingRows(content, Array(page.pixels[70 * 800 ..< (offset + 420) * 800]), width: 800)
        #expect(rows.isEmpty, "\(rows.count) rows from \(rows.first ?? -1): \(stitcher.summary)")
    }

    @Test func aScrollerInsideThePageIsTakenInWhenNothingElseScrolls() throws {
        // Without a place the gesture lands, or by hand, what scrolls is what there is to capture.
        let page = Page(width: 800, height: 2000)
        let stitcher = Self.stitcher(width: 800, height: 500)
        stitcher.isDriven = true
        Self.add(Self.withCodeBlock(page, at: 270, inner: 0), to: stitcher)
        #expect(Self.add(Self.withCodeBlock(page, at: 270, inner: 20), to: stitcher) == .scrolled(offset: 20))
        #expect(stitcher.innerPart == nil)
    }

    @Test func aGradientDitheredOnScreenIsNotTakenForSomethingFixed() throws {
        // A picture shaded left to right, every row alike but for the GPU's dither, which belongs to the screen, not
        // the page: at the same place on screen it is the same in every view. It must come out whole, never with
        // pieces of the background where it looked fixed.
        let page = Page(width: 800, height: 2400)
        let image = 800..<1000
        func shade(_ x: Int) -> UInt32 { UInt32(0x30 + x * 0x90 / 800) }
        func view(at offset: Int) -> [UInt32] {
            Self.view(page, at: offset, size: 500) { pixels, width, height in
                for y in 0..<height where image.contains(offset + y) {
                    for x in 60..<740 {
                        // A pattern of the screen's own, 64 rows tall, as the GPU's dither is.
                        let dither = UInt32(truncatingIfNeeded: ((x &* 2_654_435_761) ^ ((y % 64) &* 40_503)) >> 7) % 3
                        let level = shade(x) + dither
                        pixels[y * width + x] = 0xFF00_0000 | level << 16 | (level / 2 + 0x40) << 8 | (0xC0 - level / 2)
                    }
                }
            }
        }
        let stitcher = Self.stitcher(width: 800, height: 500)
        stitcher.isDriven = true
        var offset = 0
        Self.add(view(at: offset), to: stitcher)
        while offset < 1500 {
            offset += 18
            #expect(Self.add(view(at: offset), to: stitcher) == .scrolled(offset: 18), "at \(offset)")
        }
        let picture = try #require(stitcher.picture())
        #expect(picture.height == offset + 500, "\(stitcher.summary)")
        let pixels = Self.pixels(of: picture)
        var holes = 0
        for y in image {
            for x in 60..<740 {
                let red = (pixels[y * 800 + x] >> 16) & 0xFF
                if red + 4 < shade(x) || red > shade(x) + 6 { holes += 1 }
            }
        }
        #expect(holes == 0, "\(holes) pixels of the picture are something else: \(stitcher.summary)")
    }

    @Test func somethingPlayingAtThePageEndIsKept() throws {
        // The last screen holds a banner that changes in every view (a GIF, a ticker), then a footer of text: the
        // picture must end as the page does, the banner as some view showed it and the text under it whole.
        let page = Page(width: 800, height: 1400)
        let banner = 1300..<1400
        var frame = 0
        func view(at offset: Int) -> [UInt32] {
            frame += 1
            return Self.view(page, at: offset, size: 500) { pixels, width, height in
                for y in 0..<height where banner.contains(offset + y) {
                    for x in 40..<760 {
                        pixels[y * width + x] = 0xFF00_0000 | UInt32(truncatingIfNeeded: ((x / 24 + (offset + y) / 12 + frame) % 7) &* 0x24_1E_30 + 0x30_30_30)
                    }
                }
            }
        }
        let stitcher = Self.stitcher(width: 800, height: 500)
        var offset = 0
        Self.add(view(at: offset), to: stitcher)
        // Slowing down at the end, as scrolling does.
        for step in Array(repeating: 20, count: 43) + [14, 10, 8, 4, 2, 2] {
            offset += step
            Self.add(view(at: offset), to: stitcher)
        }
        for _ in 0..<6 { Self.add(view(at: 900), to: stitcher) }
        let picture = try #require(stitcher.picture())
        #expect(picture.height == 1400, "\(stitcher.summary)")
        let rows = Self.differingRows(Self.pixels(of: picture), page.pixels, width: 800).filter { !banner.contains($0) }
        #expect(rows.isEmpty, "\(rows.count) rows from \(rows.first ?? -1): \(stitcher.summary)")
        let pixels = Self.pixels(of: picture)
        let blank = banner.filter { y in (40..<760).allSatisfy { pixels[y * 800 + $0] == pixels[y * 800 + 40] } }
        #expect(blank.isEmpty, "\(blank.count) banner rows blank from \(blank.first ?? -1)")
    }

    @Test func aPictureThatLoadsOnceScrollingStartsIsTakenEndsAndAll() throws {
        // A hero across the whole width shows a placeholder until the page first scrolls, then its picture: every
        // row of it is seen loaded in many views after that, away from where bars stick, so it must come out loaded
        // to its very ends. (Rows seen loaded only right below the view's top, where sticky things are pushed out,
        // keep what the first view showed.)
        let page = Page(width: 800, height: 2400)
        let hero = Page(width: 800, height: 300, seed: 51)
        let rows = 120..<420
        func view(at offset: Int, loaded: Bool) -> [UInt32] {
            Self.view(page, at: offset, size: 500) { pixels, width, height in
                for y in 0..<height where rows.contains(offset + y) {
                    for x in 0..<width {
                        pixels[y * width + x] = loaded ? hero.pixels[(offset + y - rows.lowerBound) * 800 + x] | 0xFF20_0000 : 0xFFE5_E7EB
                    }
                }
            }
        }
        let stitcher = Self.stitcher(width: 800, height: 500)
        Self.add(view(at: 0, loaded: false), to: stitcher)
        var offset = 0
        while offset < 1200 {
            offset += 20
            Self.add(view(at: offset, loaded: true), to: stitcher)
        }
        let picture = try #require(stitcher.picture())
        #expect(picture.height == offset + 500, "\(stitcher.summary)")
        let pixels = Self.pixels(of: picture)
        var placeholder = 0
        for y in rows {
            for x in 0..<800 where pixels[y * 800 + x] == 0xFFE5_E7EB { placeholder += 1 }
        }
        #expect(placeholder == 0, "\(placeholder) pixels of the placeholder left: \(stitcher.summary)")
    }

    @Test func aCarouselSlidingDoesNotTurnThePageSideways() throws {
        // Before the page first scrolls, a hero half the view tall slides to its next picture.
        let page = Page(width: 800, height: 2000)
        let slides = (Page(width: 800, height: 200, seed: 31), Page(width: 800, height: 200, seed: 32))
        let hero = 100..<300
        func view(at offset: Int, slide: Int) -> [UInt32] {
            Self.view(page, at: offset, size: 400) { pixels, width, height in
                for y in 0..<height where hero.contains(offset + y) {
                    let row = offset + y - hero.lowerBound
                    for x in 0..<width {
                        let at = x + slide
                        pixels[y * width + x] = at < 800 ? slides.0.pixels[row * 800 + at] : slides.1.pixels[row * 800 + at - 800]
                    }
                }
            }
        }
        let stitcher = Self.stitcher(width: 800, height: 400)
        Self.add(view(at: 0, slide: 0), to: stitcher)
        for slide in stride(from: 40, through: 800, by: 40) { Self.add(view(at: 0, slide: slide), to: stitcher) }
        #expect(stitcher.axis != .horizontal)
        var offset = 0
        for _ in 0..<12 {
            offset += 30
            #expect(Self.add(view(at: offset, slide: 800), to: stitcher) == .scrolled(offset: 30), "at \(offset)")
        }
        #expect(stitcher.axis == .vertical)
        #expect(try #require(stitcher.picture()).height == offset + 400)
    }

    @Test func aViewFoundAgainIsPlacedByWhatScrollsNotBySidebars() throws {
        // A sidebar that never moves left of the page, its items each unlike the others; far back to a part long
        // captured. The sidebar, kept as the first view showed it, would place the view at the top.
        let page = Page(width: 900, height: 3000)
        func view(at offset: Int) -> [UInt32] {
            Self.view(page, at: offset, size: 400) { pixels, width, height in
                for y in 0..<height {
                    for x in 0..<300 {
                        let item = y / 40
                        pixels[y * width + x] = y % 40 < 22 && x > 20 && x < 120 + item * 13 && (x + item) % 5 < 3 ? 0xFF50_5560 &+ UInt32(item) : Self.white
                    }
                }
            }
        }
        let stitcher = Self.stitcher(width: 900, height: 400)
        var offset = 0
        Self.add(view(at: offset), to: stitcher)
        while offset < 1600 {
            offset += 100
            #expect(Self.add(view(at: offset), to: stitcher) == .scrolled(offset: 100), "at \(offset)")
        }
        #expect(Self.add(view(at: 600), to: stitcher) == .scrolled(offset: -1000))
        #expect(Self.add(view(at: 680), to: stitcher) == .scrolled(offset: 80))
        let picture = try #require(stitcher.picture())
        #expect(picture.height == 2000, "\(stitcher.summary)")
        // Right of the sidebar, the page as it is.
        let pixels = Self.pixels(of: picture)
        let rows = Self.differingRows(pixels, Array(page.pixels[0 ..< 2000 * 900]), width: 900, skipping: 0..<300)
        #expect(rows.isEmpty, "\(rows.count) rows from \(rows.first ?? -1): \(stitcher.summary)")
    }

    // MARK: - Sideways

    @Test func scrollingSidewaysGivesTheWidePage() throws {
        // A wide page: the made-up text turned on its side, so its columns differ as rows do.
        let tall = Page(width: 240, height: 2400)
        var wide = Page(width: 2400, height: 240)
        for y in 0..<240 {
            for x in 0..<2400 { wide.pixels[y * 2400 + x] = tall.pixels[x * 240 + y] }
        }
        let stitcher = Self.stitcher(width: 360, height: 240)
        var offset = 0
        #expect(Self.add(Self.view(wide, at: offset, size: 360, sideways: true), to: stitcher) == .started)
        for step in [30, 100, 7, 250, 64, 180] {
            offset += step
            #expect(Self.add(Self.view(wide, at: offset, size: 360, sideways: true), to: stitcher) == .scrolled(offset: step), "step \(step)")
        }
        #expect(stitcher.axis == .horizontal)
        let picture = try #require(stitcher.picture())
        #expect(picture.width == offset + 360 && picture.height == 240)
        var expected: [UInt32] = []
        for y in 0..<240 { expected += wide.pixels[y * 2400 ..< y * 2400 + offset + 360] }
        #expect(Self.differingRows(Self.pixels(of: picture), expected, width: offset + 360).isEmpty, "\(stitcher.summary)")
    }

    @Test func sidewaysWithAColumnThatStaysPut() throws {
        let tall = Page(width: 240, height: 2400, seed: 3)
        var wide = Page(width: 2400, height: 240)
        for y in 0..<240 {
            for x in 0..<2400 { wide.pixels[y * 2400 + x] = tall.pixels[x * 240 + y] }
        }
        // A frozen first column, as a spreadsheet keeps its row titles.
        let stitcher = Self.stitcher(width: 360, height: 240)
        var offset = 0
        let first = Self.view(wide, at: offset, size: 360, sideways: true, header: 50)
        Self.add(first, to: stitcher)
        for step in [40, 120, 33, 200] {
            offset += step
            #expect(Self.add(Self.view(wide, at: offset, size: 360, sideways: true, header: 50), to: stitcher) == .scrolled(offset: step), "step \(step)")
        }
        let picture = try #require(stitcher.picture())
        #expect(picture.width == offset + 360)
        var expected: [UInt32] = []
        for y in 0..<240 {
            let row = y * 360, source = y * 2400
            expected += first[row ..< row + 50]
            expected += wide.pixels[source + 50 ..< source + offset + 360]
        }
        #expect(Self.differingRows(Self.pixels(of: picture), expected, width: offset + 360).isEmpty, "\(stitcher.summary)")
    }

    // MARK: - Limits and previews

    @Test func thePictureStopsAtItsLongest() throws {
        let page = Page(width: 300, height: 2400)
        let stitcher = Self.stitcher(width: 300, height: 200, maxLength: 900)
        var offset = 0
        Self.add(Self.view(page, at: offset, size: 200), to: stitcher)
        var steps: [ScrollStitcher.Step] = []
        while offset < 1500 {
            offset += 100
            steps.append(Self.add(Self.view(page, at: offset, size: 200), to: stitcher))
        }
        #expect(steps.contains(.full) && stitcher.isFull)
        let picture = try #require(stitcher.picture())
        #expect(picture.height <= 900)
        // What it holds is the page from its top, whole.
        let expected = Array(page.pixels[0 ..< picture.height * 300])
        #expect(Self.differingRows(Self.pixels(of: picture), expected, width: 300).isEmpty, "\(stitcher.summary)")
    }

    @Test func thePreviewFollowsTheViewUpward() throws {
        // A page whose rows are each a color of their own, so the preview's colors say which rows it shows.
        let width = 200, height = 2000
        var page = Page(width: width, height: height)
        for y in 0..<height { for x in 0..<width where (x / 7) % 2 == 0 { page.pixels[y * width + x] = 0xFF00_0000 | (UInt32(y) &* 2654435761) & 0xFFFFFF } }
        let stitcher = Self.stitcher(width: width, height: 200)
        var offset = 1200
        Self.add(Self.view(page, at: offset, size: 200), to: stitcher)
        for _ in 0..<10 {
            offset -= 100
            Self.add(Self.view(page, at: offset, size: 200), to: stitcher)
        }
        // 1200 rows taken in, 400 shown at full size: the top 400, where the view is now.
        let preview = try #require(stitcher.preview(across: width, along: 400))
        #expect(preview.height == 400)
        let pixels = Self.pixels(of: preview)
        let expected = Array(page.pixels[offset * width ..< (offset + 400) * width])
        #expect(Self.differingRows(pixels, expected, width: width).isEmpty)
    }

    @Test func thePreviewShowsTheNewestEnd() throws {
        let page = Page(width: 400, height: 2400)
        let stitcher = Self.stitcher(width: 400, height: 300)
        var offset = 0
        Self.add(Self.view(page, at: offset, size: 300), to: stitcher)
        for _ in 0..<8 {
            offset += 150
            Self.add(Self.view(page, at: offset, size: 300), to: stitcher)
        }
        // Half size, at most 400 pixels long: the last 800 rows of the page.
        let preview = try #require(stitcher.preview(across: 200, along: 400))
        #expect(preview.width == 200 && preview.height == 400)
        let sideways = Self.stitcher(width: 300, height: 200)
        let tall = Page(width: 200, height: 1600)
        var wide = Page(width: 1600, height: 200)
        for y in 0..<200 { for x in 0..<1600 { wide.pixels[y * 1600 + x] = tall.pixels[x * 200 + y] } }
        Self.add(Self.view(wide, at: 0, size: 300, sideways: true), to: sideways)
        Self.add(Self.view(wide, at: 120, size: 300, sideways: true), to: sideways)
        let widePreview = try #require(sideways.preview(across: 100, along: 600))
        // 420 columns at half size, as wide as it is.
        #expect(widePreview.width == 210 && widePreview.height == 100)
    }
}
