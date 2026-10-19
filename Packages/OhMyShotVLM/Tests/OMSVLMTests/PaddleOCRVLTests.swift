import Foundation
@testable import OMSVLM
import Testing

/// What the Swift PaddleOCR-VL does before and after the model, which needs no GPU: the picture's size and values, the
/// tokens' positions, and the tokens back to text. Each expectation is what mlx-vlm 0.7.4 gives
/// (Tools/l3-spike/vlm_stages.py); the model itself is compared stage by stage with `vlm-check`.
struct PaddleOCRVLTests {
    @Test func picturesAreScaledToWholeBlocksAsTheProcessorScalesThem() throws {
        func size(_ height: Int, _ width: Int) throws -> [Int] {
            let size = try PaddleOCRVLPicture.scaledSize(height: height, width: width)
            return [size.height, size.width]
        }
        #expect(try size(312, 594) == [308, 588])
        // 70 / 28 is 2.5, which Python rounds to the even 2.
        #expect(try size(70, 2240) == [56, 2240])
        // Over 1280 blocks: shrunk; under 144: grown.
        #expect(try size(3000, 4000) == [840, 1148])
        #expect(try size(96, 310) == [196, 616])
        // A side shorter than a block is made one first.
        #expect(try size(20, 300) == [112, 1316])
        #expect(try size(5950, 1128) == [2296, 420])
        #expect(throws: PaddleOCRVLPicture.Failure.self) { try size(10, 4000) }
    }

    @Test func valuesAreNormalizedAndCutIntoPatchesRowByRow() throws {
        #expect(PaddleOCRVLPicture.normalized[0] == -1)
        #expect(PaddleOCRVLPicture.normalized[255] == 1)
        #expect(PaddleOCRVLPicture.normalized[128] == Float((128.0 / 255 - 0.5) / 0.5))
        // A picture already of the size it is scaled to (one patch down, two across, 28 × 28 the smallest scaling),
        // left half black and right half white, red only in its top-left pixel.
        let width = 336, height = 336
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in width / 2..<width { for c in 0..<3 { bytes[(y * width + x) * 4 + c] = 255 } }
        }
        bytes[0] = 255
        let picture = try PaddleOCRVLPicture(bytes: bytes, width: width, height: height)
        #expect(picture.height == 24 && picture.width == 24)
        #expect(picture.tokens == 144)
        let patch = 3 * 14 * 14
        #expect(picture.values.count == 24 * 24 * patch)
        // The first patch: red's plane first, its first value the red pixel; the patch's other channels black.
        #expect(picture.values[0] == 1)
        #expect(picture.values[1] == -1)
        #expect(picture.values[14 * 14] == -1)
        // The 13th patch of the first row is the first in the white half.
        #expect(picture.values[(12 * patch)...].prefix(patch).allSatisfy { $0 == 1 })
        #expect(picture.values[(11 * patch)...].prefix(patch).allSatisfy { $0 == -1 })
    }

    @Test func thePicturesTokensTakeTheirRowAndColumnAndTextCountsOn() {
        // The prompt the stage check read: 5 tokens before the picture, its 22 × 42 patches as 11 × 21 tokens, 8 after.
        let picture = PaddleOCRVLPicture(height: 22, width: 42, values: [])
        let tokens = [100273, 2969, 93963, 93919, 101305] + Array(repeating: 100295, count: 231) + [101306, 93972, 2497, 93963, 23, 92267, 93963, 23]
        let (positions, delta) = PaddleOCRVL.positions(tokens, imageToken: 100295, picture: picture)
        #expect(delta == -210)
        #expect(positions.allSatisfy { $0.count == 244 })
        #expect(positions.map { Array($0.prefix(5)) } == [[0, 1, 2, 3, 4], [0, 1, 2, 3, 4], [0, 1, 2, 3, 4]])
        // The picture's first token, the last of its first row, the first of its second row, its last.
        #expect([5, 25, 26, 235].map { index in positions.map { $0[index] } } == [[5, 5, 5], [5, 5, 25], [5, 6, 5], [5, 15, 25]])
        // Text after: from one past the picture's largest position.
        #expect(positions.map { Array($0.suffix(8)) } == Array(repeating: Array(26...33).map(Int32.init), count: 3))
        // Text alone counts from 0 in all three.
        let text = PaddleOCRVL.positions([1, 2, 3], imageToken: 100295, picture: picture)
        #expect(text.positions == [[0, 1, 2], [0, 1, 2], [0, 1, 2]] && text.delta == 0)
    }

    @Test func tokensBecomeTextAsTheTokenizerDecodesThem() {
        let vocabulary = PaddleOCRVLTokens(vocabulary: ["<unk>", "\u{2581}Region", "<fcel>", "<0xE4>", "<0xBD>", "<0xA0>", "<0x0A>", "\u{2581}", "Q1", "<0xFF>", "<0xBD>x"])
        #expect(vocabulary.text([2, 1, 2, 8]) == "<fcel> Region<fcel>Q1")
        // Bytes in a row are one UTF-8 string: 你, then a line break.
        #expect(vocabulary.text([3, 4, 5, 6, 8]) == "你\nQ1")
        // Bytes that aren't UTF-8 are one U+FFFD each; a token that only starts like a byte is text.
        #expect(vocabulary.text([9, 7, 3, 4, 8]) == "\u{FFFD} \u{FFFD}\u{FFFD}Q1")
        #expect(vocabulary.text([10, 99]) == "<0xBD>x")
    }
}
