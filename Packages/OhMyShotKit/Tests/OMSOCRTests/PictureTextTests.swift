import CoreGraphics
import Testing
@testable import OMSOCR

struct PictureTextTests {
    @Test func aPictureUpToAQuarterTallerThanABandIsReadWhole() {
        #expect(PictureText.pieces(width: 2336, height: 2287) == [CGRect(x: 0, y: 0, width: 2336, height: 2287)])
        #expect(PictureText.pieces(width: 4112, height: 2560) == [CGRect(x: 0, y: 0, width: 4112, height: 2560)])
    }

    @Test func aScreenIsReadInBandsAcrossItsWidth() {
        #expect(PictureText.pieces(width: 4112, height: 2658) == [
            CGRect(x: 0, y: 0, width: 4112, height: 2048),
            CGRect(x: 0, y: 2048 - 256, width: 4112, height: 2658 - 1792),
        ])
    }

    @Test func aLongScrollingCaptureIsReadInOverlappingBands() {
        let pieces = PictureText.pieces(width: 3346, height: 47_500)
        #expect(pieces.first == CGRect(x: 0, y: 0, width: 3346, height: 2048))
        #expect(pieces.last?.maxY == 47_500)
        for (piece, next) in zip(pieces, pieces.dropFirst()) {
            #expect(piece.minX == 0 && piece.width == 3346)
            #expect(next.minY == piece.maxY - CGFloat(PictureText.overlap))
        }
    }

    @Test func aVeryWidePictureIsAlsoCutAcrossAsWideAsItIsTall() {
        let pieces = PictureText.pieces(width: 30_000, height: 2400)
        #expect(pieces.first == CGRect(x: 0, y: 0, width: 2400, height: 2400))
        #expect(pieces.last?.maxX == 30_000)
        #expect(pieces.allSatisfy { $0.minY == 0 && $0.height == 2400 })
        // Taller than a band too: row by row, each row cut across the same way.
        let both = PictureText.pieces(width: 10_989, height: 2880)
        #expect(both.count == 10)
        #expect(both.prefix(5).allSatisfy { $0.minY == 0 && $0.height == 2048 })
        #expect(both[0].width == 2880 && both[1].minX == 2880 - 256)
    }

    @Test func aWideScreenIsNotCutAcross() {
        #expect(PictureText.pieces(width: 6880, height: 2880).allSatisfy { $0.minX == 0 && $0.width == 6880 })
    }
}
