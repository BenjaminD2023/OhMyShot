import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import OMSOCR

struct TranslationUnitTests {
    private func line(_ text: String, y: CGFloat, width: CGFloat = 400, wraps: Bool? = false) -> OCRLine {
        OCRLine(text: text, box: CGRect(x: 20, y: y, width: width, height: 20), confidence: 1, wrapsToNextLine: wraps)
    }

    @Test func wrappedLinesAreOneUnit() {
        let lines = [
            line("Settings", y: 0, width: 120),
            line("Quick Access keeps every capture one click", y: 40, wraps: true),
            line("away, so you can copy or annotate it.", y: 66, width: 300),
            line("12:30", y: 110, width: 60),
        ]
        let units = TranslationUnits.group(lines)
        #expect(units.map(\.lines) == [[0], [1, 2], [3]])
        #expect(units[1].text == "Quick Access keeps every capture one click away, so you can copy or annotate it.")
        #expect(units[1].box == CGRect(x: 20, y: 40, width: 400, height: 46))
        #expect(units.map(\.skip) == [nil, nil, .figures])
    }

    @Test func figuresWithAnAbbreviationAreLeftAlone() {
        for figures in ["12:30", "$20", "5 GB", "100 GB", "iOS 26", "2:30 PM", "Q4 2026", "1080p"] {
            #expect(TranslationUnits.isFigures(figures), "\(figures)")
        }
        for words in ["Step 3", "Version 0.1.0", "Settings", "Release Notes", "Open 3 files"] {
            #expect(!TranslationUnits.isFigures(words), "\(words)")
        }
    }

    @Test func namesAndCommandsAreLeftAlone() {
        for name in ["package.json", "~/src", "--force", ".git", "@shmily7", "#gateevent", "camelCase", "ttys000", "macOS", "x.com/home"] {
            #expect(TranslationUnits.isIdentifier(Substring(name)), "\(name)")
        }
        for word in ["Settings", "well-known", "Explore", "(beta)", "C", "设置"] {
            #expect(!TranslationUnits.isIdentifier(Substring(word)), "\(word)")
        }
        // Anywhere: a lone identifier, or more names and figures than words.
        #expect(TranslationUnits.isCommandLike("package-lock.json", technical: false))
        #expect(TranslationUnits.isCommandLike("macOS 27.2 (26B5091g)", technical: false))
        #expect(!TranslationUnits.isCommandLike("Docs: https://example.com/docs", technical: false))
        #expect(!TranslationUnits.isCommandLike("Phone: +1 (555) 010-0199", technical: false))
        #expect(!TranslationUnits.isCommandLike("Settings", technical: false))
        // On the command line, lone words and listings too, but not sentences.
        #expect(TranslationUnits.isCommandLike("config", technical: true))
        #expect(TranslationUnits.isCommandLike("drwxr-xr-x - me 6 Oct 23:53 -- .claude", technical: true))
        #expect(!TranslationUnits.isCommandLike("Last login: Wed Oct 7 19:27:19 on ttys000", technical: true))
        #expect(!TranslationUnits.isCommandLike("error: cannot find module named foo in the current directory", technical: true))
        #expect(!TranslationUnits.isCommandLike("截图完成后", technical: true))
    }

    @Test func aPageOfTheCommandLineIsTechnical() {
        let terminal = ["drwxr-xr-x - me 6 Oct 23:53 -- .claude", "drwxr-xr-x - me 7 Oct 19:30 -- .git", ".rw-r--r-- 151 me 7 Oct 19:29 -- .gitignore",
                        ".rw-r--r-- 21k me 7 Oct 19:29 -- ASSETS.md", "> ls", "config", "desktop", "docs", "package.json"]
        #expect(TranslationUnits.isTechnical(terminal))
        let interface = ["Home", "Explore", "Notifications", "Messages", "What's happening?", "Quick Access keeps every capture one click away.",
                         "Show more", "Who to follow", "Terms of Service", "Privacy Policy", "© 2026 X Corp."]
        #expect(!TranslationUnits.isTechnical(interface))
    }

    @Test func linksCodeAndVerticalTextAreLeftAlone() {
        #expect(TranslationUnits.group([line("https://example.com/docs", y: 0)])[0].skip == .link)
        #expect(TranslationUnits.group([line("hello@example.com", y: 0)])[0].skip == .link)
        #expect(TranslationUnits.group([line("Docs: https://example.com/docs", y: 0)])[0].skip == nil)
        let code = ["func load() {", "    let image = try await read(url)", "    return image", "}"]
            .enumerated().map { line($1, y: CGFloat($0) * 24) }
        #expect(TranslationUnits.group(code).allSatisfy { $0.skip == .code })
        let vertical = OCRLine(text: "竖排文字", box: CGRect(x: 0, y: 0, width: 20, height: 80), confidence: 1)
        #expect(TranslationUnits.group([vertical])[0].skip == .vertical)
    }

    @Test func aTablesRowsAreLeftAsTheyAreOnTheImage() {
        // A paragraph, then a table's rows (TableMerge): each row alone, left as on the image, which one run of text
        // drawn across the table would cover.
        var rows = [line("Region\tQ1\tQ2", y: 60), line("North\tStrong growth\tSteady", y: 84)]
        for index in rows.indices { rows[index].isTableRow = true; rows[index].isExact = true }
        let units = TranslationUnits.group([line("The regions grew as follows.", y: 0, width: 300)] + rows)
        #expect(units.map(\.lines) == [[0], [1], [2]])
        #expect(units.map(\.skip) == [nil, .code, .code])
    }

    @Test func aUnitWithAFormulaSaysSo() {
        var formula = line(#"Given a loss $L(\theta)$, each step moves"#, y: 0, wraps: true)
        formula.math = .inline
        let units = TranslationUnits.group([formula, line("the parameters until they settle.", y: 26, width: 300), line("Settings", y: 70, width: 120)])
        #expect(units.map(\.lines) == [[0, 1], [2]])
        #expect(units.map(\.hasMath) == [true, false])
        #expect(units[0].text.contains(#"$L(\theta)$"#))
    }
}

struct TranslatorTests {
    private let hans = Locale.Language(identifier: "zh-Hans")

    @Test func simplifiedAndTraditionalAreDifferentLanguages() {
        #expect(!Translator.isSame(hans, Locale.Language(identifier: "zh-Hant")))
        #expect(Translator.isSame(Locale.Language(identifier: "zh"), hans))
        #expect(Translator.isSame(Locale.Language(identifier: "zh-TW"), Locale.Language(identifier: "zh-Hant")))
        #expect(Translator.isSame(Locale.Language(identifier: "en-US"), Locale.Language(identifier: "en")))
        #expect(!Translator.isSame(Locale.Language(identifier: "en"), hans))
    }

    @Test func languagesAreDetectedPerUnit() {
        let readings = Translator.languages(of: ["Quick Access keeps every capture one click away.", "截图完成后，卡片会出现在屏幕左下角。"])
        #expect(readings[0].language?.languageCode == .english)
        #expect(readings[1].language.map { Translator.isSame($0, hans) } == true)
    }

    /// A small selection of short Latin text: Natural Language reads it as Polish or Vietnamese, which
    /// left the whole selection untranslated. It is the page's, or the preferred, Latin language.
    @Test func shortLatinTextIsThePreferredLatinLanguage() {
        let preferred = [Locale.Language(identifier: "en"), hans]
        let terminal = Translator.languages(of: ["moraxcheng", "Oct", "drwxr-xr-x", "Grok", "Premium+", "Ts tsconfig.json", "- Ts vite.config.ts"], preferred: preferred)
        #expect(terminal.allSatisfy { $0.language?.languageCode == .english })
        // A file name read as confident Indonesian no longer makes the page Indonesian.
        #expect(terminal.allSatisfy { !$0.confident })
        // A confident French sentence makes the short words beside it French.
        let french = Translator.languages(of: ["Les captures restent sur ce Mac jusqu’à ce que vous les supprimiez.", "Réglages"], preferred: preferred)
        #expect(french.allSatisfy { $0.language?.languageCode == .french })
    }

    @Test func chineseJapaneseAndKoreanAreToldByTheirCharacters() {
        let preferred = [Locale.Language(identifier: "en"), hans]
        func language(_ text: String) -> String? { Translator.writtenLanguage(of: text, preferred: preferred).map { Translator.identifier(of: $0.language) } }
        #expect(language("设置") == "zh-Hans")
        #expect(language("關注") == "zh-Hant")
        // Characters both write alike: the preferred Chinese.
        #expect(language("中文") == "zh-Hans")
        #expect(language("設定を開く") == "ja")
        #expect(language("설정") == "ko")
        // Mostly Latin with a Chinese word: not told by its characters.
        #expect(language("Last file: 设计稿.png") == nil)
        #expect(language("按住 Option 再松开鼠标") == "zh-Hans")
        // An icon read as kana among stray letters is Japanese only in part.
        #expect(Translator.writtenLanguage(of: "2っaくコiくつlく", preferred: preferred)?.pure == false)
    }

    @Test func theTargetIsTheFirstPreferredLanguageThePageIsNotIn() {
        let preferred = [Locale.Language(identifier: "en"), hans]
        let english = Locale.Language(identifier: "en")
        let englishPage: [(text: String, language: Locale.Language?)] = [
            ("Quick Access keeps every capture one click away.", english), ("设置", hans), ("Settings", english),
        ]
        #expect(Translator.automaticTarget(for: englishPage, preferred: preferred) == hans)
        let chinesePage: [(text: String, language: Locale.Language?)] = [
            ("截图完成后，卡片会出现在屏幕左下角，可以直接拖到其他应用里。", hans), ("Quick Access", english),
        ]
        #expect(Translator.automaticTarget(for: chinesePage, preferred: preferred) == english)
    }

    @Test func languagesAreNamedOnceWithTheirScript() {
        #expect(Translator.identifier(of: Locale.Language(identifier: "zh")) == "zh-Hans")
        #expect(Translator.identifier(of: Locale.Language(identifier: "zh-TW")) == "zh-Hant")
        #expect(Translator.identifier(of: Locale.Language(identifier: "en-GB")) == "en")
        #expect(Translator.identifier(of: Locale.Language(identifier: "ar-AE")) == "ar")
        #expect(Translator.name(of: hans, in: Locale(identifier: "zh-Hans")) == "简体中文")
        #expect(Translator.name(of: Locale.Language(identifier: "zh-TW"), in: Locale(identifier: "zh-Hans")) == "繁体中文")
        #expect(Translator.name(of: Locale.Language(identifier: "en-US"), in: Locale(identifier: "en")) == "English")
    }

    @Test func bilingualLabelsAreAlreadyInTheTarget() {
        let english = Locale.Language(identifier: "en")
        for label in ["发布说明 Release Notes", "价格 Price", "套餐 Plan", "扫码下载 Scan to download"] {
            #expect(Translator.isBilingual(label, in: hans), "\(label)")
            #expect(Translator.isBilingual(label, in: english), "\(label)")
        }
        #expect(!Translator.isBilingual("Open the 设置 panel to change it", in: hans))
        #expect(!Translator.isBilingual("按住 Option 再松开鼠标", in: english))
        // Kanji and kana are no mix with Latin: Japanese is translated into Chinese as usual. And a
        // Chinese label is not Japanese for sharing its characters.
        #expect(!Translator.isBilingual("設定を開く", in: hans))
        #expect(!Translator.isBilingual("发布说明 Release Notes", in: Locale.Language(identifier: "ja")))
        #expect(!Translator.isBilingual("发布说明 Release Notes", in: Locale.Language(identifier: "fr")))
        #expect(!Translator.isBilingual("Quick Access keeps every capture", in: english))
    }

    @Test func labelsGoTogetherAndSentencesAlone() {
        let texts = ["Free", "Quick Access keeps every capture one click away.", "Pro", "Team", "Docs: https://example.com/docs", "A | B"]
        let units = texts.enumerated().map { TranslationUnit(lines: [$0], text: $1, box: .zero) }
        let (batches, singles) = Translator.batches(of: Array(units.indices), in: units)
        #expect(batches == [[0, 2, 3, 4]])
        #expect(singles == [1, 5])
        #expect(Translator.isShort("Save | Don't Save") == false)
        #expect(Translator.isShort("截图完成后，卡片会出现在屏幕左下角") == false)
        #expect(Translator.isShort("扫码下载"))
        #expect(Translator.isShort("Done."))
        #expect(!Translator.isShort("Done. Next one."))
    }

    @Test func shortTextTakesThePagesLanguage() {
        let texts = ["Quick Access keeps every capture one click away.", "The text in a capture can be copied, edited, and searched.",
                     "dfanxu", "Codex", "截图完成后，卡片会出现在屏幕左下角，可以直接拖到其他应用里。", "设置"]
        let languages = Translator.languages(of: texts).map(\.language)
        let english = Locale.Language(identifier: "en")
        #expect(languages[0].map { Translator.isSame($0, english) } == true)
        // Alone these read as other languages; here they are the page's English.
        #expect(languages[2].map { Translator.isSame($0, english) } == true)
        #expect(languages[3].map { Translator.isSame($0, english) } == true)
        #expect(languages[5].map { Translator.isSame($0, hans) } == true)
        // An icon read as kana among stray letters is no confident Japanese; nor a status bar Italian.
        let misread = Translator.languages(of: texts + ["2っaくコiくつlく"])
        #expect(misread.last?.confident == false)
        #expect(TranslationUnits.isCommandLike("品Agent Stats: 0/o (0%6) •- 7fa5b71 100.00%A 1 0)", technical: true))
    }

    @Test func chineseTranslationsLoseTheSpacesBetweenSentences() {
        #expect(Translator.tidied("快速访问让每次捕获都只需点击一下即可。 捕获中的文本可以复制。", into: hans) == "快速访问让每次捕获都只需点击一下即可。捕获中的文本可以复制。")
        #expect(Translator.tidied("按住 Option 再松开", into: hans) == "按住 Option 再松开")
        #expect(Translator.tidied("Done. Next", into: Locale.Language(identifier: "en")) == "Done. Next")
        #expect(Translator.tidied("저장 완료. 다음", into: Locale.Language(identifier: "ko")) == "저장 완료. 다음")
    }

    @Test func aFormulaTheTranslatorChangedIsPutBack() {
        // As the system's model gave it: a trailing space command dropped.
        #expect(Translator.restoringMath(#"这里 $a\,b$ 表示乘积，且 $\text{rank}(A)\leq n$ 成立。"#, from: #"Here $a\,b\,$ denotes the product and $\text{rank}(A)\leq n$ holds."#)
            == #"这里 $a\,b\,$ 表示乘积，且 $\text{rank}(A)\leq n$ 成立。"#)
        // Formulas the translation moved are matched by their text, not their order.
        let moved = #"如果$x\in A$，我们就设置$p(x)=1$，否则$p(x)=0$。"#
        #expect(Translator.restoringMath(moved, from: #"We set $p(x)=1$ if $x\in A$ and $p(x)=0$ otherwise."#) == moved)
        #expect(Translator.restoringMath(#"若 $x\in B$，设 $p(x)=1$"#, from: #"Set $p(x)=1$ if $x\in A$"#) == #"若 $x\in A$，设 $p(x)=1$"#)
        // Two the changed one is as near to: left as translated. So is one near none.
        #expect(Translator.restoringMath("取 $x_{3}$", from: "Take $x_{1}$ or $x_{2}$") == "取 $x_{3}$")
        #expect(Translator.restoringMath(#"取 $\frac{a}{b}$"#, from: "Take $y^{2}+1$") == #"取 $\frac{a}{b}$"#)
        // Money is no formula, and a translation without formulas has none to put back.
        #expect(Translator.restoringMath("利润升至500万美元", from: "Profit rose to $5 million and $3 million") == "利润升至500万美元")
        #expect(Translator.editDistance("kitten", "sitting") == 3)
    }

    @Test func chineseTidyingLeavesAFormulaAlone() {
        let translated = #"给定损失函数 $L(\theta)$，每一步都会移动参数，$\theta_{t+1}=\theta_{t}-\eta\nabla L(\theta_{t})$，直到收敛。"#
        #expect(Translator.tidied(translated, into: hans) == translated)
        #expect(Translator.tidied(#"$f(x, y)$ 的值"#, into: hans) == #"$f(x, y)$ 的值"#)
    }

    /// No model is involved: Traditional to Simplified is a character conversion, text already in the
    /// target stays, and skipped units are not looked at.
    @Test func traditionalChineseIsConvertedNotTranslated() async throws {
        let units = [
            TranslationUnit(lines: [0], text: "這個設定會在每次截圖後顯示預覽視窗。", box: .zero),
            TranslationUnit(lines: [1], text: "截图完成后，卡片会出现在屏幕左下角。", box: .zero),
            TranslationUnit(lines: [2], text: "12:30", box: .zero, skip: .figures),
        ]
        let outcome = try await Translator().translate(units, to: hans)
        #expect(outcome.translations[0] == "这个设定会在每次截图后显示预览视窗。")
        #expect(outcome.inTarget == [1])
        #expect(outcome.translations[2] == nil)
        #expect(outcome.needsDownload.isEmpty && outcome.unsupported.isEmpty)
    }
}

struct TranslationOverlayTests {
    private static let size = (width: 300, height: 100)
    /// The line's box, top-left origin.
    private static let box = CGRect(x: 20, y: 40, width: 200, height: 20)

    /// One line of "text" (3 px strokes) across `box`, in `ink` on `paper`.
    private func page(paper: (CGFloat, CGFloat, CGFloat), ink: (CGFloat, CGFloat, CGFloat)) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: Self.size.width, height: Self.size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: paper.0, green: paper.1, blue: paper.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height))
        context.setFillColor(red: ink.0, green: ink.1, blue: ink.2, alpha: 1)
        for x in stride(from: 24, to: 216, by: 9) {
            context.fill(CGRect(x: CGFloat(x), y: CGFloat(Self.size.height) - Self.box.maxY + 2, width: 3, height: 16))
        }
        return try #require(context.makeImage())
    }

    /// The colors of `image` as `LineColors` reads them.
    private func colors(of image: CGImage, box: CGRect) throws -> LineColors {
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data)
        let pixels = Pixels(base: data.assumingMemoryBound(to: UInt8.self), width: image.width, height: image.height, bytesPerRow: context.bytesPerRow)
        return LineColors(pixels: pixels, box: box)
    }

    private func components(_ color: CGColor) -> [Int] {
        (color.components ?? []).prefix(3).map { Int(($0 * 255).rounded()) }
    }

    @Test func backgroundAndInkAreMeasured() throws {
        let light = try colors(of: page(paper: (0.98, 0.97, 0.95), ink: (0.1, 0.2, 0.6)), box: Self.box)
        #expect(components(light.background) == [250, 247, 242])
        #expect(components(light.ink) == [26, 51, 153])
        let dark = try colors(of: page(paper: (0.12, 0.12, 0.13), ink: (0.9, 0.9, 0.9)), box: Self.box)
        #expect(components(dark.background) == [31, 31, 33])
        #expect(components(dark.ink) == [230, 230, 230])
    }

    @Test func theOriginalIsPaintedOverAndTheTranslationDrawn() async throws {
        let image = try page(paper: (1, 1, 1), ink: (0, 0, 0))
        let lines = [OCRLine(text: "Quick Access", box: Self.box, confidence: 1)]
        let units = TranslationUnits.group(lines)
        let rendering = try #require(await TranslationOverlay.render(
            image, lines: lines, units: units, translations: [0: "快速访问"], language: Locale.Language(identifier: "zh-Hans")
        ))
        #expect(rendering.truncated.isEmpty)
        let result = try colors(of: rendering.image, box: Self.box)
        #expect(components(result.background) == [255, 255, 255])
        // Four characters at 16 pt end well before the old strokes did: what is right of them is paper.
        let context = try #require(CGContext(
            data: nil, width: Self.size.width, height: Self.size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(rendering.image, in: CGRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height))
        let pixels = Pixels(base: try #require(context.data).assumingMemoryBound(to: UInt8.self), width: Self.size.width, height: Self.size.height, bytesPerRow: context.bytesPerRow)
        var inkLeft = 0
        var inkRight = 0
        for y in Int(Self.box.minY)..<Int(Self.box.maxY) {
            for x in 20..<100 where pixels.rgb(x, y).0 < 128 { inkLeft += 1 }
            for x in 120..<230 where pixels.rgb(x, y).0 < 250 { inkRight += 1 }
        }
        #expect(inkLeft > 50)
        #expect(inkRight == 0)
    }

    @Test func everyLineOfAParagraphIsDrawn() async throws {
        // A white page; a paragraph of three lines of strokes, read as wrapping into each other.
        let context = try #require(CGContext(
            data: nil, width: 600, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 200))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        let boxes = (0..<3).map { CGRect(x: 20, y: 30 + CGFloat($0) * 50, width: 560, height: 30) }
        for box in boxes {
            for x in stride(from: box.minX + 4, to: box.maxX - 4, by: 9) {
                context.fill(CGRect(x: x, y: 200 - box.maxY + 4, width: 3, height: box.height - 8))
            }
        }
        let image = try #require(context.makeImage())
        let lines = boxes.enumerated().map { OCRLine(text: "Quick Access keeps every capture one click away and", box: $1, confidence: 1, wrapsToNextLine: $0 < 2) }
        let units = TranslationUnits.group(lines)
        #expect(units.count == 1)
        let translation = String(repeating: "快速访问让每次捕获都只需点击一下即可", count: 3)
        let rendering = try #require(await TranslationOverlay.render(
            image, lines: lines, units: units, translations: [0: translation], language: Locale.Language(identifier: "zh-Hans")
        ))
        let result = try #require(CGContext(
            data: nil, width: 600, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        result.draw(rendering.image, in: CGRect(x: 0, y: 0, width: 600, height: 200))
        let pixels = Pixels(base: try #require(result.data).assumingMemoryBound(to: UInt8.self), width: 600, height: 200, bytesPerRow: result.bytesPerRow)
        // Ink in each of the three rows, starting near the left edge.
        for box in boxes {
            var ink = 0
            for y in Int(box.minY)..<Int(box.maxY) {
                for x in 20..<120 where pixels.rgb(x, y).0 < 128 { ink += 1 }
            }
            #expect(ink > 40, "row at \(box.minY)")
        }
    }

    @Test func aLineRunsOnBesideItselfThenShrinksThenIsCutShort() {
        let hans = Locale.Language(identifier: "zh-Hans")
        let black = CGColor(gray: 0, alpha: 1)
        let box = CGRect(x: 0, y: 0, width: 100, height: 20)
        let member = [OCRLine(text: "Capture", box: box, confidence: 1)]
        func width(_ layout: TranslationOverlay.Layout) -> CGFloat {
            layout.lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        }
        let fits = TranslationOverlay.layout("截图", box: box, room: 100, members: member, size: 16, language: hans, color: black)
        #expect(fits.scale == 1 && !fits.truncated && fits.lines.count == 1)

        // Ten characters at 16 pt are 160 wide: they run on into the room beside.
        let runsOn = TranslationOverlay.layout("截图完成后卡片会出现", box: box, room: 200, members: member, size: 16, language: hans, color: black)
        #expect(runsOn.lines.count == 1 && !runsOn.truncated)
        #expect(width(runsOn) > 100 && width(runsOn) <= 200)

        // With no room, a long one is cut short to one line within the box.
        let long = String(repeating: "截图完成后卡片会出现在屏幕左下角", count: 2)
        let cut = TranslationOverlay.layout(long, box: box, room: 100, members: member, size: 16, language: hans, color: black)
        #expect(cut.truncated && cut.lines.count == 1 && cut.scale == TranslationOverlay.minimumScale)
        #expect(width(cut) <= 100)
    }

    @Test func aParagraphKeepsItsColumn() {
        let hans = Locale.Language(identifier: "en")
        let members = (0..<3).map { OCRLine(text: "line", box: CGRect(x: 0, y: CGFloat($0) * 26, width: 200, height: 20), confidence: 1) }
        let box = members.dropFirst().reduce(members[0].box) { $0.union($1.box) }
        let layout = TranslationOverlay.layout(
            "Quick Access keeps every capture one click away, so you can copy it, annotate it, or drag it anywhere.",
            box: box, room: 600, members: members, size: 16, language: hans, color: CGColor(gray: 0, alpha: 1)
        )
        let widths = layout.lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        #expect(widths.allSatisfy { $0 <= 200 })
        #expect(layout.lines.count >= 2)
    }

    @Test func aLineRunsOnOnlyOverItsBackground() throws {
        // White paper; an "icon" (a black square) 60 px right of the line's box.
        let context = try #require(CGContext(
            data: nil, width: Self.size.width, height: Self.size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 160, y: CGFloat(Self.size.height) - 58, width: 16, height: 16))
        let data = try #require(context.data)
        let pixels = Pixels(base: data.assumingMemoryBound(to: UInt8.self), width: Self.size.width, height: Self.size.height, bytesPerRow: context.bytesPerRow)
        let box = CGRect(x: 20, y: 40, width: 80, height: 20)
        // Up to the icon, less half a line of margin: 160 − 10 − 20.
        #expect(TranslationOverlay.clear(260, beside: box, of: (255, 255, 255), in: pixels) == 130)
        // Nothing in the way above the icon's row.
        #expect(TranslationOverlay.clear(260, beside: CGRect(x: 20, y: 4, width: 80, height: 20), of: (255, 255, 255), in: pixels) == 260)
    }

    @Test func theSizeComesFromTheWidth() {
        func width(_ text: String, _ size: CGFloat) -> CGFloat {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): TranslationOverlay.font(size: size, bold: false, language: Locale.Language(identifier: "en")),
            ]))
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        // Capitals alone make a short box (0.87 of the size, measured): the width still says 30.
        let capitals = OCRLine(text: "ALL CAPS HEADING TEXT", box: CGRect(x: 0, y: 0, width: width("ALL CAPS HEADING TEXT", 30), height: 26), confidence: 1)
        #expect(abs(TranslationOverlay.typeSize(of: capitals) - 30) < 0.5)
        // Chinese with punctuation makes a tall one (1.24).
        let chinese = OCRLine(text: "截图完成后，卡片会出现", box: CGRect(x: 0, y: 0, width: width("截图完成后，卡片会出现", 30), height: 37), confidence: 1)
        #expect(abs(TranslationOverlay.typeSize(of: chinese) - 30) < 0.5)
        // Text at 15 pt on a Retina screen is drawn wider than at 30 pt: measured at 15, it still says 30.
        let retina = OCRLine(text: "Quick Access keeps every capture", box: CGRect(x: 0, y: 0, width: width("Quick Access keeps every capture", 15) * 2, height: 30), confidence: 1)
        #expect(abs(TranslationOverlay.typeSize(of: retina, scale: 2) - 30) < 0.5)
        // A misread that leaves out half the line is held to the height.
        let misread = OCRLine(text: "Quick", box: CGRect(x: 0, y: 0, width: width("Quick Access", 30), height: 30), confidence: 1)
        #expect(TranslationOverlay.typeSize(of: misread) == 37.5)
    }

    @Test func neighborsOfOneStyleAreOneSize() {
        // A sidebar of four items, a heading above it, and a line of a size apart far to the right.
        let boxes = [
            CGRect(x: 40, y: 20, width: 200, height: 40), // heading
            CGRect(x: 40, y: 90, width: 120, height: 26), CGRect(x: 40, y: 136, width: 90, height: 26),
            CGRect(x: 40, y: 182, width: 140, height: 26), CGRect(x: 40, y: 228, width: 100, height: 26),
            CGRect(x: 900, y: 136, width: 200, height: 24),
        ]
        let sizes: [CGFloat] = [40, 26, 27.5, 25.2, 26.8, 26.4]
        let harmonized = TranslationOverlay.harmonized(sizes, boxes: boxes)
        #expect(Set(harmonized[1...4]).count == 1)
        #expect(harmonized[0] == 40)
        // Not a neighbor: keeps its own.
        #expect(harmonized[5] == 26.4)
        // Cells of a row side by side.
        let row = TranslationOverlay.harmonized([28, 31, 29.5], boxes: [
            CGRect(x: 20, y: 100, width: 60, height: 30), CGRect(x: 300, y: 102, width: 40, height: 28), CGRect(x: 560, y: 99, width: 70, height: 32),
        ])
        #expect(Set(row).count == 1)
    }

    @Test func linesTakeTheirColumnsLeftEdge() {
        let boxes = [CGRect(x: 79, y: 450, width: 418, height: 33), CGRect(x: 82, y: 495, width: 324, height: 26),
                     CGRect(x: 77, y: 532, width: 347, height: 33), CGRect(x: 74, y: 567, width: 502, height: 49),
                     CGRect(x: 600, y: 567, width: 100, height: 30)]
        let lefts = TranslationOverlay.columnLefts(boxes, sizes: Array(repeating: 29, count: boxes.count))
        // One edge for the whole column, whichever line is asked about.
        #expect(Set(lefts[0...3]) == [79])
        // Alone in its column: its own edge.
        #expect(lefts[4] == 600)
        // Measured ink edges, a little inside the boxes, win over the boxes'.
        let inked = TranslationOverlay.columnLefts(boxes, sizes: Array(repeating: 29, count: boxes.count), edges: [82, 82, 81, 82, 603])
        #expect(Set(inked[0...3]) == [82])
        #expect(inked[4] == 603)
    }

    @Test func inkStartsWhereTheStrokesDo() throws {
        let image = try page(paper: (1, 1, 1), ink: (0, 0, 0))
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = Pixels(base: try #require(context.data).assumingMemoryBound(to: UInt8.self), width: image.width, height: image.height, bytesPerRow: context.bytesPerRow)
        // The page's first stroke starts at x 24, four pixels into the box.
        #expect(TranslationOverlay.inkLeft(of: Self.box, in: pixels) == 24)
    }

    @Test func erasingStopsAtALineThatStays() {
        let box = CGRect(x: 0, y: 30, width: 100, height: 20)
        let free = TranslationOverlay.erasure(of: box, keeping: [])
        #expect(free.minY < 30 && free.maxY > 50)
        let tight = TranslationOverlay.erasure(of: box, keeping: [CGRect(x: 10, y: 8, width: 50, height: 21), CGRect(x: 0, y: 51, width: 80, height: 20)])
        #expect(tight.minY == 29 && tight.maxY == 51)
    }
}
