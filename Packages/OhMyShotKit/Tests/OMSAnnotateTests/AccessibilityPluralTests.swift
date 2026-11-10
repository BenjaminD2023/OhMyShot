import Foundation
@testable import OMSAnnotate
import Testing

/// What VoiceOver hears in the editor counts in the language's plural, never "1 suggestions".
struct AccessibilityPluralTests {
    private func english(_ key: String.LocalizationValue) -> String {
        let bundle = Bundle.module.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.module
        return String(localized: key, bundle: bundle)
    }

    @Test func countsTakeTheirPlural() {
        #expect(english("\(1) suggestions to redact") == "1 suggestion to redact")
        #expect(english("\(2) suggestions to redact") == "2 suggestions to redact")
        #expect(english("\(1) lines of text to highlight") == "1 line of text to highlight")
        #expect(english("Capture, \(1) marks") == "Capture, 1 mark")
        #expect(english("Capture, \(3) marks") == "Capture, 3 marks")
    }
}
