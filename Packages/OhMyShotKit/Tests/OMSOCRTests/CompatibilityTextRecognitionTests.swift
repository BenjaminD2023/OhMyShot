import CoreGraphics
import Foundation
import Testing
import Vision
@testable import OMSOCR

struct CompatibilityTextRecognitionTests {
    @Test func recoveryRequiresEveryLanguageAndPreservesPriorityAndScripts() {
        let supported = ["en-US", "fr-FR", "zh-Hans", "zh-Hant"]
        #expect(CompatibilityTextRecognition.compatibleLanguages(["zh-Hans", "en-US"], supported: supported, automaticallyDetectsLanguage: false) == ["zh-Hans", "en-US"])
        #expect(CompatibilityTextRecognition.compatibleLanguages(["en-US", "zh-Hant"], supported: supported, automaticallyDetectsLanguage: false) == ["en-US", "zh-Hant"])
        #expect(CompatibilityTextRecognition.compatibleLanguages(["zh-Hant"], supported: ["zh-Hans"], automaticallyDetectsLanguage: false) == nil)
        #expect(CompatibilityTextRecognition.compatibleLanguages(["ja", "en-US"], supported: supported, automaticallyDetectsLanguage: false) == nil)
        #expect(CompatibilityTextRecognition.compatibleLanguages(["ko-KR"], supported: supported, automaticallyDetectsLanguage: false) == nil)
        // A recognition level with fewer supported languages must not silently leave Chinese out.
        #expect(CompatibilityTextRecognition.compatibleLanguages(["zh-Hans", "en-US"], supported: ["en-US"], automaticallyDetectsLanguage: false) == nil)
    }

    @Test func recoveryDoesNotPretendToSupportAutomaticOrUnspecifiedLanguages() {
        #expect(CompatibilityTextRecognition.compatibleLanguages([], supported: ["en-US"], automaticallyDetectsLanguage: false) == nil)
        #expect(CompatibilityTextRecognition.compatibleLanguages(["en-US"], supported: ["en-US"], automaticallyDetectsLanguage: true) == nil)
        #expect(!VisionPipeline.Options().prefersCompatibilityRecognition)
    }

    @Test func onlyAccurateEnglishRecoveryUsesTheBilingualModel() {
        func recovered(_ identifiers: [String], accurate: Bool = true) -> [String] {
            CompatibilityTextRecognition.recoveryLanguages(identifiers.map(Locale.Language.init(identifier:)), accurate: accurate)
        }
        #expect(recovered(["en-US"]) == ["zh-Hans", "en-US"])
        for identifiers in [["ja", "en-US"], ["ko-KR"], ["zh-Hant", "en-US"], ["en-US", "fr-FR"], []] {
            #expect(recovered(identifiers) == identifiers.map { Locale.Language(identifier: $0).minimalIdentifier })
        }
        #expect(recovered(["en-US"], accurate: false) == [Locale.Language(identifier: "en-US").minimalIdentifier])
    }

    @Test func compatibilityCropUsesTheOriginalPicturesTopLeftCoordinates() {
        let region = NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
        let crop = CompatibilityTextRecognition.cropRect(for: region, in: CGSize(width: 1000, height: 500))
        #expect(abs(crop.minX - 200) < 0.0001)
        #expect(abs(crop.minY - 250) < 0.0001)
        #expect(abs(crop.width - 400) < 0.0001)
        #expect(abs(crop.height - 100) < 0.0001)
        #expect(CompatibilityTextRecognition.cropRect(for: .fullImage, in: CGSize(width: 1000, height: 500)) == CGRect(x: 0, y: 0, width: 1000, height: 500))
    }

    @Test func isolatedReaderLineTransportPreservesGeometryFormattingAndEveryFlag() throws {
        let lines = [
            OCRLine(text: "文字 Text", box: CGRect(x: 5.25, y: 10.5, width: 90.75, height: 20.25), confidence: 0.75,
                    direction: .leftToRight, wrapsToNextLine: true, math: .inline, isExact: true, isTableRow: true),
            OCRLine(text: "vertical", box: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 0.5,
                    direction: .topToBottom, wrapsToNextLine: false, math: .display),
            OCRLine(text: "rtl", box: .zero, confidence: 1, direction: .rightToLeft),
            OCRLine(text: "", box: .zero, confidence: 0)
        ]
        #expect(try JSONDecoder().decode([OCRLine].self, from: JSONEncoder().encode(lines)) == lines)
    }
}
