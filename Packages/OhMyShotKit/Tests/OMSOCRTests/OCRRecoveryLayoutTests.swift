import CoreGraphics
import Testing
@testable import OMSOCR

struct OCRRecoveryLayoutTests {
    @Test func aWidePictureHoldingVerticalColumnsMustNotUseRecovery() {
        // The benchmark's vertical-zh picture is landscape: image aspect alone accepted its known
        // failed reading. Four tall text regions correctly keep it on the current recognizer.
        let columns = [100, 160, 220, 280].map { CGRect(x: $0, y: 60, width: 36, height: 240) }
        #expect(!OCRRecoveryLayout.allows(size: CGSize(width: 680, height: 360), textRegions: columns))
        #expect(!OCRRecoveryLayout.allows(size: CGSize(width: 680, height: 360), textRegions:
            columns + [CGRect(x: 50, y: 10, width: 500, height: 30)]))
    }

    @Test func shortPicturesWithClearlyHorizontalTextCanRecover() {
        let lines = [CGRect(x: 20, y: 15, width: 420, height: 28), CGRect(x: 20, y: 60, width: 250, height: 28)]
        #expect(OCRRecoveryLayout.allows(size: CGSize(width: 680, height: 360), textRegions: lines))
        #expect(OCRRecoveryLayout.allows(size: CGSize(width: 1024, height: 1024), textRegions: lines))
    }

    @Test func aHorizontalCaptionCannotHideTheVerticalFixturesSquareGlyphs() {
        // Actual DetectTextRectanglesRequest output for vertical-zh: the detector returned only
        // three separate glyphs. Even a clear horizontal title leaves that body unsuitable.
        let glyphs = [
            CGRect(x: 323, y: 97, width: 32, height: 33),
            CGRect(x: 211, y: 167, width: 33, height: 33),
            CGRect(x: 546, y: 201, width: 34, height: 34)
        ]
        #expect(!OCRRecoveryLayout.allows(size: CGSize(width: 680, height: 360), textRegions: glyphs))
        #expect(!OCRRecoveryLayout.allows(size: CGSize(width: 680, height: 360), textRegions:
            glyphs + [CGRect(x: 50, y: 10, width: 500, height: 30)]))
    }

    @Test func largePortraitAndUnknownLayoutsKeepTheCurrentRecognizer() {
        let line = CGRect(x: 20, y: 15, width: 420, height: 28)
        #expect(!OCRRecoveryLayout.allows(size: CGSize(width: 2000, height: 1025), textRegions: [line]))
        #expect(!OCRRecoveryLayout.allows(size: CGSize(width: 360, height: 680), textRegions: [line]))
        #expect(!OCRRecoveryLayout.allows(size: CGSize(width: 680, height: 360), textRegions: []))
        #expect(!OCRRecoveryLayout.allows(size: CGSize(width: 680, height: 360), textRegions: [CGRect(x: 20, y: 15, width: 28, height: 28)]))
        #expect(!OCRRecoveryLayout.allows(size: CGSize(width: 680, height: 360), textRegions: [CGRect(x: 20, y: 15, width: 56, height: 28)]))
    }

    @Test func invalidGeometryCannotProveACompatibleLayout() {
        let line = CGRect(x: 20, y: 15, width: 420, height: 28)
        #expect(!OCRRecoveryLayout.allows(size: .zero, textRegions: [line]))
        #expect(!OCRRecoveryLayout.allows(size: CGSize(width: CGFloat.infinity, height: 360), textRegions: [line]))
        #expect(!OCRRecoveryLayout.allows(size: CGSize(width: 680, height: 360), textRegions: [line, .zero]))
    }
}
