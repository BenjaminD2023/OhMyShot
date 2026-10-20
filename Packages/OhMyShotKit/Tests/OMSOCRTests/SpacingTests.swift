import CoreGraphics
import Foundation
import Testing
@testable import OMSOCR

struct SpacingTests {
    /// Synthetic glyph bounds with independently specified empty pixel columns at each boundary.
    /// Gaps below are the measured 36 pt mixed-image gaps, not generated from the spacing rule.
    private func restore(_ text: String, gaps: [String: Int], em: CGFloat = 36.712576) -> String {
        let visible = text.indices.filter { !text[$0].isWhitespace }
        var columns = [Bool](repeating: true, count: (visible.count + 1) * 80)
        var ends: [String.Index: CGFloat] = [:]
        for (offset, index) in visible.enumerated() {
            let end = (offset + 1) * 80
            ends[index] = CGFloat(end)
            guard offset + 1 < visible.count else { continue }
            let pair = String(text[index]) + String(text[visible[offset + 1]])
            let width = gaps[pair] ?? 2
            for column in (end - width / 2)..<(end - width / 2 + width) { columns[column] = false }
        }
        return Spacing.restored(text[...], ink: InkProfile(originX: 0, ink: columns), em: em) {
            ends[$0.lowerBound]
        }
    }

    @Test func restoresNarrowMixedSpacesMeasuredInTheSourceImage() {
        let raw = "本次OCR 测试包含 English words和版本2.0，编号为"
        #expect(restore(raw, gaps: ["次O": 9, "R测": 10, "含E": 11, "s和": 10, "本2": 9])
            == "本次 OCR 测试包含 English words 和版本 2.0，编号为")
    }

    @Test func leavesUnspacedAndPartiallySpacedTextAlone() {
        let unspaced = "图像OCR版本2.0"
        #expect(restore(unspaced, gaps: ["像O": 9, "R版": 9, "本2": 9]) == unspaced)
        let partial = "使用OCR 工具和 English words版本2.0"
        #expect(restore(partial, gaps: ["用O": 3, "R工": 10, "和E": 11, "s版": 3, "本2": 4]) == partial)
    }

    @Test func requiresConsistentExamplesInBothScriptDirections() {
        let oneDirection = "图像 OCR和 English版本2.0"
        #expect(restore(oneDirection, gaps: ["像O": 10, "和E": 11, "本2": 9]) == oneDirection)
        let inconsistent = "图像OCR 工具和 English版本2.0"
        #expect(restore(inconsistent, gaps: ["像O": 9, "R工": 9, "和E": 18, "本2": 9]) == inconsistent)
    }

    @Test func doesNotUseSpuriousSpacesOrChangeLetterDigitSpacing() {
        #expect(restore("图像 OCR 文本2.0", gaps: ["像O": 2, "R文": 2, "本2": 9]) == "图像OCR文本2.0")
        let raw = "图像 OCR 工具 English words24px"
        #expect(restore(raw, gaps: ["像O": 10, "R工": 11, "具E": 10, "s2": 9, "4p": 9]) == raw)
    }

    @Test func keepsTheExistingFallbackAndWhitespaceBehavior() {
        #expect(restore("图像OCR版本2.0", gaps: ["像O": 13, "本2": 14]) == "图像 OCR版本 2.0")
        #expect(restore("   图像OCR   ", gaps: [:]) == "   图像OCR ")
        #expect(!Spacing.mayNeedSpaces("午後2時にコピー"[...]))
    }
}
