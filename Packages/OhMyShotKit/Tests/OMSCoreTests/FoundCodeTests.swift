import CoreGraphics
import Foundation
import OMSCore
import Testing

struct FoundCodeTests {
    private func code(_ payload: String, isMatrix: Bool = true) -> FoundCode {
        FoundCode(payload: payload, isMatrix: isMatrix, box: .zero)
    }

    @Test func parsesWiFiWithEscapedCharactersAndHiddenFlag() throws {
        let wifi = code(#"WIFI:T:WPA;S:My\;Net\\Work\:1;P:s\;ecret\\pass\:2;H:true;;"#)
        #expect(wifi.structured == .wifi(ssid: #"My;Net\Work:1"#, password: #"s;ecret\pass:2"#, security: "WPA", hidden: true))
        #expect(wifi.displaySummary == #"Wi-Fi: My;Net\Work:1"#)
        #expect(wifi.primaryCopyValue == #"s;ecret\pass:2"#)
        #expect(wifi.openableURL == nil)
        #expect(wifi.webURL == nil)
    }

    @Test func openWiFiWithoutPasswordCopiesSSID() {
        let wifi = code("WIFI:T:nopass;S:CoffeeShop;P:;;")
        #expect(wifi.structured == .wifi(ssid: "CoffeeShop", password: nil, security: "nopass", hidden: false))
        #expect(wifi.displaySummary == "Wi-Fi: CoffeeShop")
        #expect(wifi.primaryCopyValue == "CoffeeShop")
        #expect(wifi.openableURL == nil)
    }

    @Test func parsesMailtoWithSubjectAndSafeOpenableURL() throws {
        let mail = code("mailto:jane@example.com?subject=Hello%20World")
        let expectedURL = try #require(URL(string: "mailto:jane@example.com?subject=Hello%20World"))
        #expect(mail.structured == .mailto(address: "jane@example.com", subject: "Hello World", url: expectedURL))
        #expect(mail.displaySummary == "Email: jane@example.com")
        #expect(mail.primaryCopyValue == "jane@example.com")
        #expect(mail.openableURL == expectedURL)
        #expect(mail.webURL == nil)
    }

    @Test func parsesPhoneNumberAndAllowsTelScheme() throws {
        let phone = code("tel:+1 415 555 0100")
        let expectedURL = try #require(URL(string: "tel:+14155550100"))
        #expect(phone.structured == .phone(number: "+1 415 555 0100", url: expectedURL))
        #expect(phone.displaySummary == "Call: +1 415 555 0100")
        #expect(phone.primaryCopyValue == "+1 415 555 0100")
        #expect(phone.openableURL == expectedURL)
        #expect(phone.webURL == nil)
    }

    @Test func parsesVCardContactWithFoldedAndEscapedFields() {
        let raw = """
        BEGIN:VCARD\r
        VERSION:3.0\r
        FN:Jane Doe\r
        ORG:Acme\\; Inc.;Engineering\r
        TEL;TYPE=CELL:+1-415-555-0199\r
        EMAIL;TYPE=WORK:jane@acme.example\r
        END:VCARD
        """
        let contact = code(raw)
        #expect(contact.structured == .contact(
            name: "Jane Doe",
            organization: "Acme; Inc., Engineering",
            phone: "+1-415-555-0199",
            email: "jane@acme.example",
            rawVCard: raw
        ))
        #expect(contact.displaySummary == "Contact: Jane Doe")
        #expect(contact.primaryCopyValue == raw)
        #expect(contact.openableURL == nil)
    }

    @Test func vCardFallsBackToStructuredNWhenFNIsMissing() {
        let raw = "BEGIN:VCARD\nVERSION:3.0\nN:Lovelace;Ada;;;\nTEL:tel:+4412345678\nEND:VCARD"
        let contact = code(raw)
        #expect(contact.structured == .contact(
            name: "Ada Lovelace",
            organization: nil,
            phone: "+4412345678",
            email: nil,
            rawVCard: raw
        ))
        #expect(contact.displaySummary == "Contact: Ada Lovelace")
    }

    @Test func webURLsAreOpenableAndUnsafeSchemesAreRejected() throws {
        let web = code("https://example.com/path?q=1")
        let expected = try #require(URL(string: "https://example.com/path?q=1"))
        #expect(web.structured == .web(expected))
        #expect(web.webURL == expected)
        #expect(web.openableURL == expected)
        #expect(web.displaySummary == "https://example.com/path?q=1")
        #expect(web.primaryCopyValue == "https://example.com/path?q=1")

        for unsafe in [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "smb://192.168.1.1/share",
            "ssh://root@example.com",
            "shortcuts://run-shortcut?name=Bad",
            "http://",
            "WIFI:T:WPA;P:secret;;",
            "tel:abc",
            "mailto:",
            "4006381333931",
        ] {
            let item = code(unsafe)
            #expect(item.structured == nil, "Expected nil structured for \(unsafe)")
            #expect(item.openableURL == nil, "Expected nil openableURL for \(unsafe)")
            #expect(item.webURL == nil, "Expected nil webURL for \(unsafe)")
            #expect(item.displaySummary == unsafe)
            #expect(item.primaryCopyValue == unsafe)
        }
    }

    @Test func formulaDelimiterWrapsAllModesAndAvoidsDoubleWrapping() {
        #expect(FormulaDelimiter.raw.wrap("  x^2 + y^2  ") == "x^2 + y^2")
        #expect(FormulaDelimiter.inlineDollar.wrap("x^2 + y^2") == "$x^2 + y^2$")
        #expect(FormulaDelimiter.inlineDollar.wrap("$x^2 + y^2$") == "$x^2 + y^2$")
        #expect(FormulaDelimiter.displayDollar.wrap("x^2 + y^2") == "$$x^2 + y^2$$")
        #expect(FormulaDelimiter.displayDollar.wrap("$$x^2 + y^2$$") == "$$x^2 + y^2$$")
        #expect(FormulaDelimiter.inlineParen.wrap("x^2 + y^2") == #"\(x^2 + y^2\)"#)
        #expect(FormulaDelimiter.inlineParen.wrap(#"\(x^2 + y^2\)"#) == #"\(x^2 + y^2\)"#)
        #expect(FormulaDelimiter.inlineDollar.wrap("   ") == "   ")
    }
}
