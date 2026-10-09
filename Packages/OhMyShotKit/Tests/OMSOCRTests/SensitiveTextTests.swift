import AppKit
import Foundation
import Testing
@testable import OMSOCR

struct SensitiveTextFinderTests {
    /// The matches in `line`, as kind and text.
    private func found(_ line: String) -> [String] {
        SensitiveTextFinder.matches(in: line).map { "\($0.kind.rawValue): \(line[$0.range])" }
    }

    @Test func emailsAndPhones() {
        #expect(found("Mail: hello@example.com") == ["email: hello@example.com"])
        #expect(found("Phone: +1 (555) 010-0199").contains("phone: +1 (555) 010-0199"))
        #expect(found("手机：138 1234 5678") == ["phone: 138 1234 5678"])
        #expect(found("联系电话13812345678") == ["phone: 13812345678"])
    }

    @Test func numbersMustPassTheirChecksums() {
        #expect(found("Card 4111 1111 1111 1111 expires 12/28") == ["card: 4111 1111 1111 1111"])
        #expect(found("Order 4111 1111 1111 1112").isEmpty)
        #expect(found("身份证号：11010519491231002X") == ["idNumber: 11010519491231002X"])
        #expect(!found("身份证号：110105194912310021").contains { $0.hasPrefix("idNumber") })
        #expect(SensitiveTextFinder.passesLuhn([4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2]))
    }

    @Test func keysAndTokens() {
        #expect(found("aws_access_key_id AKIAIOSFODNN7EXAMPLE") == ["secret: AKIAIOSFODNN7EXAMPLE"])
        #expect(found("ghp_0123456789abcdefghijklmnopqrstuvwxyZ is mine") == ["secret: ghp_0123456789abcdefghijklmnopqrstuvwxyZ"])
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
        #expect(found("Authorization: Bearer \(jwt)") == ["secret: \(jwt)"])
        #expect(found("OPENAI_API_KEY=sk-proj-9fKq2LmXv8RtYp4WzNc7Ba1Qe") == ["secret: sk-proj-9fKq2LmXv8RtYp4WzNc7Ba1Qe"])
        // A long random run with no label or prefix.
        #expect(found("Zq3xV9kLm2Np7Rt5Wy8Bc4Df6Gh1Jk0As") == ["secret: Zq3xV9kLm2Np7Rt5Wy8Bc4Df6Gh1Jk0As"])
        #expect(found("glpat-Xy7Kq2Lm9Np4Rt6Wz8Bc") == ["secret: glpat-Xy7Kq2Lm9Np4Rt6Wz8Bc"])
        // Read with a capital I as "|", a key is still covered to its end.
        #expect(found("sk-ant-usr-Qx7Lm2Np9|fRt5Wy8Bc4Df6Gh1Jk0As3Vz") == ["secret: sk-ant-usr-Qx7Lm2Np9|fRt5Wy8Bc4Df6Gh1Jk0As3Vz"])
        // Identifiers are not secrets: a commit hash, an upper-case checksum, a UUID.
        #expect(found("commit e620611941a499325cb684b4ee5aaf35abb6d149").isEmpty)
        #expect(found("SHA1 E620611941A499325CB684B4EE5AAF35ABB6D149").isEmpty)
        #expect(found("request 123e4567-e89b-12d3-a456-426614174000 failed").isEmpty)
        // Nor are long runs made of words: a host name, an identifier in code, a path.
        #expect(found("johnappleseedsMacBook-Pro-Studio-128").isEmpty)
        #expect(found("makeAccessibilityAnnouncementForSuggestion2()").isEmpty)
        #expect(found("build/Build/Products/Debug-iphonesimulator26").isEmpty)
        #expect(SensitiveTextFinder.wordiness(of: "Zq3xV9kLm2Np7Rt5Wy8Bc4Df6Gh1Jk0As") < 0.5)
    }

    @Test func passwordsAfterTheirLabels() {
        #expect(found("Password: hunter2") == ["password: hunter2"])
        #expect(found("密码：abc123456") == ["password: abc123456"])
        #expect(found("token = \"t0k3n-value\"") == ["secret: t0k3n-value"])
    }

    @Test func linksGiveUpOnlyWhatTheyShouldNotCarry() {
        #expect(found("https://example.com/callback?code=abc123&state=xyz") == ["secret: abc123"])
        #expect(found("https://user:pa55w0rd@files.example.com/report") == ["password: pa55w0rd"])
        #expect(found("ftp://user:pa55w0rd@files.example.com/report") == ["password: pa55w0rd"])
        #expect(found("Docs: https://example.com/docs").isEmpty)
    }

    @Test func addressesNamesAndIPs() {
        #expect(found("Server 192.168.1.20 is up") == ["ipAddress: 192.168.1.20"])
        #expect(found("Upgrade to 999.1.1.1").isEmpty)
        #expect(found("1 Infinite Loop, Cupertino, CA 95014").contains { $0.hasPrefix("address") })
        #expect(found("Ask John Appleseed for access") == ["name: John Appleseed"])
    }

    @Test func namesMustBeWrittenAsNames() {
        for name in ["John Appleseed", "Ludwig van Beethoven", "JOHN APPLESEED", "J. Appleseed", "Иван Петров", "王小明", "李雷", "欧阳娜娜", "김민수"] {
            #expect(SensitiveTextFinder.looksLikeName(Substring(name)), "\(name)")
        }
        // A product name alone, an acronym, a file name beside its icon's letters, a handle with digits, a
        // Chinese word the tagger took for a person, a name without a surname, one too long.
        // Capitals read out of a line of Chinese, and letters of two scripts.
        for name in ["Hermes", "Claude", "VIP", "Git", "Ts tsconfig.json", "Package.swift", "John2 Appleseed", "运维", "小明", "王小明明", "API TX", "Ivan Пeтров"] {
            #expect(!SensitiveTextFinder.looksLikeName(Substring(name)), "\(name)")
        }
    }

    @Test func phoneNumbersMustBeWrittenAsPhoneNumbers() {
        for phone in ["+1 (555) 010-0199", "(555) 010-0199", "555-0199", "0755 8888 6666", "+86 21 6888 8888"] {
            #expect(SensitiveTextFinder.looksLikePhoneNumber(Substring(phone)), "\(phone)")
        }
        // Bare runs of seven to nine digits, codes ending in short groups, too few digits.
        for number in ["123456789", "1234-56-78", "12 34 56", "555 01"] {
            #expect(!SensitiveTextFinder.looksLikePhoneNumber(Substring(number)), "\(number)")
        }
    }

    @Test func datesAreNotPhoneNumbers() {
        for date in ["2026-10-08", "2026-10 081", "2026/10", "10/08/2026", "8.10.26"] {
            #expect(SensitiveTextFinder.looksLikeDate(Substring(date)), "\(date)")
        }
        for phone in ["+1 (555) 010-0199", "12-34-5678", "138 1234 5678", "202-610-1234"] {
            #expect(!SensitiveTextFinder.looksLikeDate(Substring(phone)), "\(phone)")
        }
    }

    @Test func plainTextIsLeftAlone() {
        for line in [
            "Quick Access keeps every capture one click away.",
            "Release: October 15, 2026 at 2:30 PM",
            "Price $1,299.00, 3 items",
            "Version 26.4 (25E5207)",
            "Updated 2026-10-08 by the build",
            "截图完成后，卡片会出现在屏幕左下角。",
        ] {
            #expect(found(line).isEmpty, "\(line)")
        }
    }
}

struct SensitiveTextScannerTests {
    @Test func aPicturesSensitiveTextIsFoundWithItsOwnBoxes() async throws {
        let size = CGSize(width: 900, height: 260)
        let lines = ["Mail: hello@example.com", "手机：138 1234 5678", "API_KEY=sk-proj-9fKq2LmXv8RtYp4WzNc7Ba1Qe"]
        let font = NSFont.systemFont(ofSize: 28)
        let picture = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 30, y: 30 + CGFloat(index) * 70), withAttributes: [.font: font, .foregroundColor: NSColor.black])
            }
            return true
        }
        var rect = CGRect(origin: .zero, size: size)
        let image = try #require(picture.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let scale = CGFloat(image.width) / size.width
        let found = try await SensitiveTextScanner().scan(image)
        let kinds = Set(found.map(\.kind))
        #expect(kinds.isSuperset(of: [.email, .phone, .secret]), "\(found.map { "\($0.kind): \($0.text)" })")
        // The address alone is covered, not its label: its box starts at the address's first glyph, past
        // "Mail: " and the gap after it.
        let label = ("Mail: " as NSString).size(withAttributes: [.font: font]).width
        let email = try #require(found.first { $0.kind == .email })
        #expect(email.box.minX >= (30 + label - 1) * scale, "\(email.box)")
        #expect(email.box.minX <= (30 + label + 4) * scale, "\(email.box)")
        #expect(email.box.minY < 70 * scale && email.box.maxY > 30 * scale)
    }

    /// White, with black blocks for glyphs: a colon at x 40–43, then a word of two glyphs at 60–69 and
    /// 74–83; or, with `busy`, a pattern with ink in every column.
    private func glyphs(busy: Bool = false) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 140, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 140, height: 30))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        if busy {
            for x in 0..<140 { for y in 0..<30 where (x * 7 + y * 13) % 3 == 0 { context.fill(CGRect(x: x, y: y, width: 1, height: 1)) } }
        } else {
            for block in [CGRect(x: 40, y: 8, width: 4, height: 14), CGRect(x: 60, y: 5, width: 10, height: 20), CGRect(x: 74, y: 5, width: 10, height: 20)] {
                context.fill(block)
            }
        }
        return try #require(context.makeImage())
    }

    @Test func boxesAreFittedToTheInk() throws {
        let image = try glyphs()
        let word = CGRect(x: 60, y: 2, width: 24, height: 26)
        // Loose: reaching into the gaps on either side, not as far as the colon.
        #expect(SensitiveTextScanner.fitted(CGRect(x: 50, y: 2, width: 42, height: 26), in: image) == word)
        // Clipped: both ends inside a glyph.
        #expect(SensitiveTextScanner.fitted(CGRect(x: 64, y: 2, width: 16, height: 26), in: image) == word)
        // Nothing to fit to: as it was.
        let blank = CGRect(x: 95, y: 2, width: 30, height: 26)
        #expect(SensitiveTextScanner.fitted(blank, in: image) == blank)
        // A background too busy to tell ink from: as it was.
        #expect(SensitiveTextScanner.fitted(CGRect(x: 50, y: 2, width: 42, height: 26), in: try glyphs(busy: true)) == CGRect(x: 50, y: 2, width: 42, height: 26))
    }

    @Test func namesAndAddressesComeFromTheChineseReadingOnly() {
        let latin = [
            SensitiveText(kind: .name, box: CGRect(x: 400, y: 340, width: 370, height: 36), text: "API TX"),
            SensitiveText(kind: .address, box: CGRect(x: 100, y: 500, width: 300, height: 30), text: "1 Infinite Loop"),
            SensitiveText(kind: .email, box: CGRect(x: 100, y: 10, width: 200, height: 30), text: "a@b.co"),
        ]
        let chinese = [SensitiveText(kind: .name, box: CGRect(x: 100, y: 80, width: 90, height: 30), text: "王小明")]
        #expect(SensitiveTextScanner.combined(latin: latin, chinese: chinese).map(\.kind) == [.email, .name])
    }

    @Test func overlappingReadingsBecomeOneOverBothBoxes() {
        let merged = SensitiveTextScanner.merged([
            SensitiveText(kind: .email, box: CGRect(x: 100, y: 10, width: 200, height: 30), text: "a@b.co"),
            SensitiveText(kind: .email, box: CGRect(x: 104, y: 12, width: 200, height: 30), text: "a@b.co"),
            SensitiveText(kind: .phone, box: CGRect(x: 100, y: 80, width: 180, height: 30), text: "13812345678"),
        ])
        #expect(merged.count == 2)
        #expect(merged[0].box == CGRect(x: 100, y: 10, width: 204, height: 32))
    }
}
