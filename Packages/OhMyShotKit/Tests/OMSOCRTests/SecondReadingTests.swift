import CoreGraphics
import Testing
@testable import OMSOCR

/// L2 read beside L1 (SecondReading): which lines take L2's text, which lines L2 adds, and how L2's text is written.
struct SecondReadingTests {
    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat = 30, confidence: Float = 0.5,
                      direction: OCRLine.Direction? = nil, wraps: Bool? = nil) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: x, y: y, width: width, height: height), confidence: confidence, direction: direction, wrapsToNextLine: wraps)
    }

    // MARK: When

    @Test func onlyTextWithHanOrKanaIsReadAgain() {
        #expect(!SecondReading.wanted([line("Press Copy to put the capture on the clipboard.", 0, 0, 500)]))
        #expect(!SecondReading.wanted([line("저장하려면 저장 버튼을 누르세요.", 0, 0, 300)]))
        // A lone misread glyph on an English page is no reason.
        #expect(!SecondReading.wanted([line("首 Home", 0, 0, 100)]))
        #expect(SecondReading.wanted([line("打开 Settings", 0, 0, 200)]))
        #expect(SecondReading.wanted([line("保存したい", 0, 0, 200)]))
    }

    // MARK: Which lines

    @Test func aChineseLineTakesTheSecondReadingAndKeepsItsPlace() {
        let first = [line("答：识别结果会按语言规则自动整理标点与问距。", 45, 232, 562, 37, confidence: 0.5, wraps: true)]
        let second = [line("答：识别结果会按语言规则自动整理标点与间距。", 45, 229, 557, 37, confidence: 0.99)]
        let merged = SecondReading.merged(first, with: second)
        #expect(merged.map(\.text) == ["答：识别结果会按语言规则自动整理标点与间距。"])
        #expect(merged[0].box == first[0].box)
        #expect(merged[0].wrapsToNextLine == true)
        #expect(merged[0].confidence == 0.99)
    }

    @Test func linesInLatinScriptAloneAndKoreanKeepTheFirstReading() {
        let first = [
            line("if (!live || stop) return;", 40, 10, 300),
            line("저장하려면 저장 버튼을", 40, 60, 226),
        ]
        let second = [
            line("if (!live Il stop) return;", 40, 10, 300, confidence: 0.98),
            line("저장하려면", 40, 60, 120, confidence: 0.9),
        ]
        #expect(SecondReading.merged(first, with: second).map(\.text) == first.map(\.text))
    }

    @Test func chineseTheFirstReadingMadeHangulOfTakesAConfidentSecondReading() {
        // Small gray type L1's Korean pass filled in; a real Korean line, which L2 reads unsure or not at all, stays.
        let first = [line("1 화유]", 40, 10, 86, 18), line("저장하려면 저장 버튼을", 40, 60, 226)]
        let second = [line("左腿骨膜损伤", 40, 10, 86, 18, confidence: 1), line("对正面", 40, 60, 120, confidence: 0.6)]
        let merged = SecondReading.merged(first, with: second)
        #expect(merged.map(\.text) == ["左腿骨膜损伤", "저장하려면 저장 버튼을"])
        #expect(!SecondReading.isMisreadAsHangul("1 화유]", second: "左腿", confidence: 0.85))
        #expect(!SecondReading.isMisreadAsHangul("1 화유]", second: "ab", confidence: 1))
    }

    @Test func aSecondLineThatCoversTwoFirstLinesChangesNeither() {
        // A name and the time beside it, which L1 reads as two lines and L2 as one.
        let first = [line("浮世绘《", 15, 11, 129, 35), line("@shmily7・2小时", 157, 11, 238, 37)]
        let second = [line("浮世绘@shmily7·2小时", 12, 5, 383, 43, confidence: 1)]
        #expect(SecondReading.merged(first, with: second).map(\.text) == first.map(\.text))
    }

    @Test func aSecondReadingThatMissesPartOfTheLineIsNotTaken() {
        let first = [line("国庆7天都在干四个简单的功能模块", 0, 0, 600)]
        let second = [line("国庆7天都在干", 0, 0, 260, confidence: 1)]
        #expect(SecondReading.merged(first, with: second).map(\.text) == first.map(\.text))
    }

    @Test func piecesOfOneLineAreReadSideBySide() {
        let first = [line("文件 名称 大小", 0, 0, 400)]
        let second = [line("大小", 300, 0, 100, confidence: 1), line("文件", 0, 0, 100, confidence: 0.97), line("名称", 150, 0, 100, confidence: 1)]
        let merged = SecondReading.merged(first, with: second)
        // Spaced as the first reading spaced them; assembling the text takes the spaces between Han out.
        #expect(merged.map(\.text) == ["文件 名称 大小"])
        #expect(merged[0].confidence == 0.97)
    }

    @Test func aVerticalLineReadsItsPiecesTopToBottom() {
        let first = [line("春风吹过小城", 543, 61, 40, 211, direction: .topToBottom)]
        let second = [line("小城", 540, 180, 47, 90, confidence: 1), line("春风吹过", 540, 55, 47, 120, confidence: 1)]
        #expect(SecondReading.merged(first, with: second).map(\.text) == ["春风吹过小城"])
    }

    // MARK: Lines only the second reading found

    @Test func confidentChineseLinesTheFirstReadingMissedAreAdded() {
        let first = [line("话题", 40, 10, 60), line("开发调优", 40, 110, 100)]
        let second = [
            line("话题", 40, 10, 60, confidence: 1),
            line("读书成诗", 40, 60, 100, confidence: 1),
            line("开发调优", 40, 110, 100, confidence: 1),
        ]
        #expect(SecondReading.merged(first, with: second).map(\.text) == ["话题", "读书成诗", "开发调优"])
    }

    @Test func iconsAndLatinTextOnlyTheSecondReadingFoundAreLeftOut() {
        let first = [line("文件传输助手", 80, 10, 200)]
        let second = [
            line("文件传输助手", 80, 10, 200, confidence: 1),
            line("凶", 300, 10, 30, confidence: 0.29),
            line("益而网", 10, 60, 90, confidence: 0.54),
            line("Oct 00:04", 80, 110, 120, confidence: 0.96),
            line("日", 10, 160, 30, confidence: 1),
        ]
        #expect(SecondReading.merged(first, with: second).map(\.text) == ["文件传输助手"])
    }

    @Test func aLineThatPartlyLiesOverAFirstLineIsNotAdded() {
        let first = [line("回复", 0, 0, 60)]
        // Two fifths of it over the first line: the same words read again, a little apart.
        let second = [line("回复我们", 20, 0, 100, confidence: 1)]
        #expect(SecondReading.merged(first, with: second).map(\.text) == ["回复"])
    }

    // MARK: How the text is written

    @Test func punctuationTakesTheWidthTheFirstReadingSaw() {
        #expect(SecondReading.dressed("常见问题：为什么中文里会出现多余的空格?", like: "常见问题：为什么中文里会出现多余空格？") == "常见问题：为什么中文里会出现多余的空格？")
        #expect(SecondReading.dressed("明日の打ち合わせは午後２時からです。", like: "明日の打ち合わせは午後2時からです。") == "明日の打ち合わせは午後2時からです。")
    }

    @Test func spacesBesideHanFollowTheInkTheFirstReadingMeasured() {
        #expect(SecondReading.dressed("新版本把截图延迟降到了10 ms以内", like: "新版本把截图延迟降到了 10 ms 以内") == "新版本把截图延迟降到了 10 ms 以内")
        #expect(SecondReading.dressed("请在iPhone或iPad上打开 App Store。", like: "请在iPhone或iPad上打开App Store。") == "请在iPhone或iPad上打开App Store。")
    }

    @Test func aSpaceEitherReadingSawElsewhereIsKept() {
        #expect(SecondReading.dressed("- 已全额支付", like: "-已全额支付") == "- 已全额支付")
    }

    @Test func aMarkReadTwiceIsReadOnce() {
        #expect(SecondReading.dressed("字号 13 px: ：截图里的小字", like: "字号 13 px：截图里的小字") == "字号 13 px：截图里的小字")
    }

    @Test func threeDotsAreTheEllipsisTheFirstReadingSaw() {
        #expect(SecondReading.dressed("蓝点网：微软发布新AI笔记本...", like: "蓝点网：微软发布新AI 笔记本…") == "蓝点网：微软发布新AI 笔记本…")
    }

    @Test func anIconReadAsTwoDifferentSymbolsGoes() {
        #expect(SecondReading.dressed("<>开发调优", like: "$ 开发调优") == "开发调优")
        // Both read the same mark: it is the text's.
        #expect(SecondReading.dressed("#话题", like: "#话题") == "#话题")
        // Nothing before the text in the first reading: what the second reads there stays.
        #expect(SecondReading.dressed("$开发调优", like: "开发调优") == "$开发调优")
    }
}
