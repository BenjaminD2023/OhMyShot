import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// What a case is meant to test.
enum Category: String, CaseIterable, Codable, Sendable {
    case zhHansEn = "zh-Hans+en"
    case zhHant = "zh-Hant"
    case ja
    case ko
    case multilingual
    case en
    case code
    case table
    case vertical
    case chat
    case small
    case dark
    /// Labels beside icons, as an app's sidebar draws them.
    case ui
    /// A real screenshot from `--real`.
    case real
}

/// The exact reading of a case.
struct Truth: Sendable {
    /// Lines in reading order, as drawn.
    var lines: [String]
    /// The cells, for table cases.
    var table: [[String]]?

    var text: String { lines.joined(separator: "\n") }
}

struct BenchCase: Sendable {
    let id: String
    let category: Category
    let truth: Truth
    let render: @Sendable () -> CGImage
}

/// The synthetic corpus. Every sentence here was written for this benchmark, so the images can live in a
/// GPL repository. Real screenshots belong in a folder outside the repo (see `--real`).
enum Corpus {
    /// Real screenshots: each `NAME.png` in `directory` with its ground truth in `NAME.txt`, one line of
    /// the image per line of text.
    static func real(in directory: URL) throws -> [BenchCase] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        return try names.filter { $0.hasSuffix(".png") }.sorted().compactMap { name -> BenchCase? in
            let stem = String(name.dropLast(4))
            let truthURL = directory.appending(path: "\(stem).txt")
            guard FileManager.default.fileExists(atPath: truthURL.path(percentEncoded: false)) else { return nil }
            let lines = try String(contentsOf: truthURL, encoding: .utf8)
                .components(separatedBy: "\n")
                .map { $0.replacingOccurrences(of: "\r", with: "") }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let imageURL = directory.appending(path: name)
            return BenchCase(id: "real-\(stem)", category: .real, truth: Truth(lines: lines)) {
                guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else { fatalError("Cannot read \(imageURL.path(percentEncoded: false))") }
                return image
            }
        }
    }

    static var all: [BenchCase] {
        [zhEnChat, zhNoSpace, zhDoc, zhEnLines, zhHant, ja, ko, multilingual, enUI, enWithChinese, codeSwift, codeSwiftPlain, codeYAML, codeGutter, tableZh, tableEn, verticalZh, chat, darkUI, uiIcons]
            + smallText
    }

    // MARK: Text blocks

    static let zhEnChat = textCase("zh-en-chat", .zhHansEn, language: "zh-Hans", [
        "下午 3 点开会，讨论 OhMyShot 的 OCR 方案。",
        "请把 build 日志发到 #dev 频道，附上 commit hash。",
        "新版本把截图延迟降到了 10 ms 以内，内存约 40 MB。",
        "如果 Wi-Fi 断开，上传会自动重试 3 次。",
        "这个 bug 只在 macOS 26 上出现，Safari 和 Chrome 都能复现。",
        "接口文档在 https://example.com/docs/ocr 里。",
    ])

    /// Chinese with Latin and digits but no typed spaces, as many people write it: spaces must not be
    /// invented here.
    static let zhNoSpace = textCase("zh-nospace", .zhHansEn, language: "zh-Hans", [
        "版本号为v2.3，大小约12MB。",
        "本周共有3个需求和12个bug需要处理。",
        "请在iPhone或iPad上打开App Store。",
    ])

    static let zhDoc = textCase("zh-doc", .zhHansEn, language: "zh-Hans", [
        "第一步：打开「设置」，选择“截图”标签页。",
        "第二步：勾选“截图后复制到剪贴板”（默认已开启）。",
        "注意：快捷键 ⌘⇧4 可能与系统冲突，请先关闭系统快捷键。",
        "常见问题：为什么中文里会出现多余的空格？",
        "答：识别结果会按语言规则自动整理标点与间距。",
    ])

    /// A Chinese page with whole lines of English prose. The Chinese model reads such lines without
    /// language correction and confuses letter case ("QuICK", "copiea"). Kept free of `Word:` lines, which
    /// would make the page read as code and send it down the code path instead.
    static let zhEnLines = BenchCase(
        id: "zh-en-lines",
        category: .zhHansEn,
        truth: Truth(lines: zhEnLinesText.map(\.text))
    ) {
        textBlock(zhEnLinesText, size: 15)
    }

    private static let zhEnLinesText: [(text: String, language: String)] = [
        ("截图完成后，卡片会出现在屏幕左下角，可以直接拖到其他应用里。", "zh-Hans"),
        ("Quick Access keeps every capture one click away.", "en"),
        ("The text in a capture can be copied, edited, and searched.", "en"),
        ("按住 Option 再松开鼠标，就能在面板里查看识别出的文字。", "zh-Hans"),
        ("Read the docs at https://example.com/docs", "en"),
        ("Write to hello@example.com or call +1 (555) 010-0199.", "en"),
        ("Version 2.4 ships on October 15, 2026 at 2:30 PM.", "en"),
        ("Free, Pro, and Team plans; Team adds shared folders.", "en"),
    ]

    static let zhHant = textCase("zh-hant", .zhHant, language: "zh-Hant", [
        "請在週五之前完成設計稿的最後修改。",
        "這個功能支援繁體中文、日文與韓文的混合排版。",
        "會議記錄已上傳至共用資料夾，請大家查閱。",
        "若有任何問題，歡迎隨時與我們聯繫。",
    ])

    static let ja = textCase("ja", .ja, language: "ja", [
        "明日の打ち合わせは午後2時からです。",
        "スクリーンショットをコピーして、チャットに貼り付けてください。",
        "この設定はアプリを再起動すると反映されます。",
        "OCRの精度は、文字の大きさとコントラストに左右されます。",
    ])

    static let ko = textCase("ko", .ko, language: "ko", [
        "내일 오전 10시에 회의가 있습니다.",
        "스크린샷을 복사해서 메신저에 붙여 넣으세요.",
        "이 설정은 앱을 다시 시작하면 적용됩니다.",
        "문자 인식 정확도는 글자 크기와 대비에 따라 달라집니다.",
    ])

    /// One image, five languages: the case that decides whether one multi-language request is enough.
    static let multilingual = BenchCase(
        id: "multilingual",
        category: .multilingual,
        truth: Truth(lines: multilingualLines.map(\.text))
    ) {
        textBlock(multilingualLines)
    }

    private static let multilingualLines: [(text: String, language: String)] = [
        ("截图完成后，卡片会出现在屏幕左下角。", "zh-Hans"),
        ("保存したい場合は「保存」を押してください。", "ja"),
        ("저장하려면 저장 버튼을 누르세요.", "ko"),
        ("Press Copy to put the capture on the clipboard.", "en"),
        ("歷史記錄會保留一週，之後自動刪除。", "zh-Hant"),
    ]

    static let enUI = textCase("en-ui", .en, language: "en", [
        "Capture Area",
        "Show Quick Access after capturing",
        "Keep captures for 1 week",
        "Screen Recording permission is required.",
        "Version 0.1.0 (build 42)",
    ])

    /// English with one Chinese word, where the Latin model takes over and must not lose the word.
    static let enWithChinese = textCase("en-zh-word", .en, language: "en", [
        "Saved 3 screenshots to Downloads",
        "Last file: 设计稿.png",
        "Open the folder in Finder",
    ])

    /// A sidebar: an SF Symbol before each label, some with an unread dot after it, and a muted bell at
    /// the end of a chat preview, all of which Vision reads as characters.
    static let uiIcons = BenchCase(id: "ui-icons", category: .ui, truth: Truth(lines: uiIconRows.map(\.label))) {
        let font = Fonts.ui(13, language: "zh-Hans")
        let rowHeight: CGFloat = 32
        let canvas = Canvas(width: 300, height: rowHeight * CGFloat(uiIconRows.count) + 24, background: .hex(0xFFFFFF))
        for (row, item) in uiIconRows.enumerated() {
            let top = 12 + CGFloat(row) * rowHeight
            let label = NSAttributedString(item.label, font: font, color: .hex(0x3C3C43))
            let size = Canvas.measure(label)
            let textTop = top + (rowHeight - size.height) / 2
            canvas.drawSymbol(item.symbol, in: CGRect(x: 16, y: textTop + size.height / 2 - 8, width: 16, height: 16), color: item.color)
            canvas.draw(label, x: 42, top: textTop)
            switch item.trailing {
            case .dot:
                canvas.fill(CGRect(x: 42 + size.width + 9, y: textTop + size.height / 2 - 3, width: 6, height: 6), radius: 3, color: .hex(0x2F80ED))
            case .bell:
                canvas.drawSymbol("bell.slash", in: CGRect(x: 260, y: textTop + size.height / 2 - 7, width: 14, height: 14), color: .hex(0xB0B0B5))
            case .none:
                break
            }
        }
        return canvas.image()
    }

    private enum Trailing { case none, dot, bell }

    private static let uiIconRows: [(symbol: String, label: String, color: CGColor, trailing: Trailing)] = [
        ("square.stack.3d.up.fill", "话题", .hex(0x3C3C43), .dot),
        ("person.fill", "我的草稿", .hex(0x3C3C43), .dot),
        ("tray.fill", "我的消息", .hex(0x3C3C43), .none),
        ("calendar", "近期活动", .hex(0x3C3C43), .none),
        ("link", "Connect", .hex(0x3C3C43), .none),
        ("paperplane.fill", "Channel", .hex(0x3C3C43), .none),
        ("chevron.left.forwardslash.chevron.right", "开发调优", .hex(0x16A2B8), .dot),
        ("leaf.fill", "国产替代", .hex(0xE5484D), .dot),
        ("square.and.arrow.up", "资源荟萃", .hex(0x12A594), .none),
        ("gift.fill", "福利羊毛", .hex(0xE5484D), .dot),
        ("ellipsis.bubble.fill", "您好，您的服务已升级", .hex(0x8E8E93), .bell),
    ]

    static let darkUI = BenchCase(
        id: "dark-ui",
        category: .dark,
        truth: Truth(lines: darkLines.map(\.text))
    ) {
        let primary = CGColor.hex(0xE5E5E7)
        let secondary = CGColor.hex(0x98989D)
        let strings = darkLines.map { line in
            NSAttributedString(line.text, font: Fonts.ui(13, language: "zh-Hans", bold: line.header), color: line.dim ? secondary : primary)
        }
        return stack(strings, background: .hex(0x1E1E1E))
    }

    private static let darkLines: [(text: String, header: Bool, dim: Bool)] = [
        ("通知", true, false),
        ("允许通知", false, false),
        ("在锁定屏幕上显示", false, false),
        ("显示预览：始终", false, true),
        ("Focus 模式下静音", false, false),
        ("上次更新：2026 年 10 月 8 日", false, true),
    ]

    /// The same two lines from 9 to 30 pixels tall, to find where small text stops being read.
    static let smallText: [BenchCase] = [9, 11, 13, 16, 20, 24, 30].map { pixels in
        let lines = ["字号 \(pixels) px：截图里的小字也要认清。", "Small text at \(pixels) px: 0123456789"]
        return BenchCase(id: "small-\(pixels)px", category: .small, truth: Truth(lines: lines)) {
            // Rendered at 2×, so a font of pixels / 2 points is `pixels` tall on the bitmap.
            textBlock(lines.map { ($0, "zh-Hans") }, size: CGFloat(pixels) / 2, padding: 12)
        }
    }

    // MARK: Code

    static let codeSwift = codeCase("code-swift", syntax: .swift, codeSwiftLines)

    private static let codeSwiftLines = [
        "// 计算缩略图的最大边长",
        "func thumbnail(for url: URL, maxPixels: Int = 512) -> CGImage? {",
        "    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {",
        "        return nil",
        "    }",
        "    let options: [CFString: Any] = [",
        "        kCGImageSourceThumbnailMaxPixelSize: maxPixels,",
        "    ]",
        "    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)",
        "}",
    ]

    /// The same code without the Chinese comment, to tell what the comment changes.
    static let codeSwiftPlain = codeCase("code-swift-plain", syntax: .swift, Array(codeSwiftLines.dropFirst()))

    /// An editor's view: right-aligned line numbers in a gutter beside the code, which the text leaves out.
    static let codeGutter = BenchCase(id: "code-gutter", category: .code, truth: Truth(lines: Array(codeSwiftLines.dropFirst()))) {
        let lines = Array(codeSwiftLines.dropFirst())
        let strings = lines.map { highlight($0, syntax: .swift) }
        let numbers = lines.indices.map { NSAttributedString("\($0 + 32)", font: Fonts.mono(12), color: .hex(0x6C7086)) }
        let rowHeight = (strings.map { Canvas.measure($0).height }.max() ?? 15) + 5
        let gutter: CGFloat = 52
        let width = (strings.map { Canvas.measure($0).width }.max() ?? 0) + gutter + 40
        let canvas = Canvas(width: ceil(width), height: ceil(rowHeight * CGFloat(lines.count) + 40), background: .hex(0x1F1F24))
        for (row, (number, code)) in zip(numbers, strings).enumerated() {
            let top = 20 + CGFloat(row) * rowHeight
            canvas.draw(number, x: 36 - Canvas.measure(number).width, top: top)
            canvas.draw(code, x: gutter + 20, top: top)
        }
        return canvas.image()
    }

    static let codeYAML = codeCase("code-yaml", syntax: .yaml, [
        "name: ocr-bench",
        "on:",
        "  push:",
        "    branches: [main]",
        "jobs:",
        "  test:",
        "    runs-on: macos-26",
        "    steps:",
        "      - uses: actions/checkout@v4",
        "      - run: swift test",
    ])

    // MARK: Tables

    static let tableZh = tableCase("table-zh", language: "zh-Hans", [
        ["名称", "数量", "单价"],
        ["苹果", "3", "¥12.50"],
        ["Banana", "12", "¥8.00"],
        ["牛奶", "2", "¥15.90"],
        ["合计", "17", "¥165.30"],
    ])

    static let tableEn = tableCase("table-en", language: "en", [
        ["Region", "Q1", "Q2", "Change"],
        ["North", "1,240", "1,385", "+11.7%"],
        ["South", "980", "912", "-6.9%"],
        ["West", "1,105", "1,230", "+11.3%"],
    ])

    // MARK: Vertical, chat

    static let verticalZh = BenchCase(
        id: "vertical-zh",
        category: .vertical,
        truth: Truth(lines: verticalColumns)
    ) {
        let font = Fonts.ui(18, language: "zh-Hans")
        let text = NSAttributedString(verticalColumns.joined(separator: "\n"), font: font, color: .hex(0x1D1D1F), vertical: true)
        let canvas = Canvas(width: 340, height: 180, background: .hex(0xFFFFFF))
        canvas.drawVertical(text, in: CGRect(x: 30, y: 30, width: 280, height: 130))
        return canvas.image()
    }

    private static let verticalColumns = ["春风吹过小城", "街角的花开了", "我们约在桥边", "等一场好天气"]

    static let chat = BenchCase(
        id: "chat-bubbles",
        category: .chat,
        truth: Truth(lines: chatBubbles.map(\.text))
    ) {
        let font = Fonts.ui(14, language: "zh-Hans")
        let width: CGFloat = 420
        let padding = CGSize(width: 14, height: 9)
        let measured = chatBubbles.map { bubble in
            let string = NSAttributedString(bubble.text, font: font, color: bubble.mine ? .hex(0xFFFFFF) : .hex(0x1D1D1F))
            return (bubble, string, Canvas.measure(string))
        }
        let height = measured.reduce(CGFloat(24)) { $0 + $1.2.height + padding.height * 2 + 10 } + 14
        let canvas = Canvas(width: width, height: height, background: .hex(0xFFFFFF))
        var top: CGFloat = 24
        for (bubble, string, size) in measured {
            let bubbleSize = CGSize(width: size.width + padding.width * 2, height: size.height + padding.height * 2)
            let x = bubble.mine ? width - 20 - bubbleSize.width : 20
            canvas.fill(CGRect(origin: CGPoint(x: x, y: top), size: bubbleSize), radius: 17, color: bubble.mine ? .hex(0x0A84FF) : .hex(0xE9E9EB))
            canvas.draw(string, x: x + padding.width, top: top + padding.height)
            top += bubbleSize.height + 10
        }
        return canvas.image()
    }

    private static let chatBubbles: [(text: String, mine: Bool)] = [
        ("周末一起去爬山吗？🏔️", false),
        ("好啊！几点出发？", true),
        ("早上 8 点地铁站见 👍", false),
        ("收到，我带水和零食 🍎", true),
    ]

    // MARK: Builders

    private static func textCase(_ id: String, _ category: Category, language: String, _ lines: [String]) -> BenchCase {
        BenchCase(id: id, category: category, truth: Truth(lines: lines)) {
            textBlock(lines.map { ($0, language) })
        }
    }

    /// Lines in the system face, each in its own language's cascade, stacked on white.
    private static func textBlock(_ lines: [(text: String, language: String)], size: CGFloat = 13, padding: CGFloat = 24) -> CGImage {
        let strings = lines.map { NSAttributedString($0.text, font: Fonts.ui(size, language: $0.language), color: .hex(0x1D1D1F)) }
        return stack(strings, background: .hex(0xFFFFFF), gap: max(4, size * 0.6), padding: padding)
    }

    private static func stack(_ strings: [NSAttributedString], background: CGColor, gap: CGFloat = 8, padding: CGFloat = 24) -> CGImage {
        let sizes = strings.map(Canvas.measure)
        let width = (sizes.map(\.width).max() ?? 0) + padding * 2
        let height = sizes.map(\.height).reduce(0, +) + gap * CGFloat(max(strings.count - 1, 0)) + padding * 2
        let canvas = Canvas(width: ceil(width), height: ceil(height), background: background)
        var top = padding
        for (string, size) in zip(strings, sizes) {
            canvas.draw(string, x: padding, top: top)
            top += size.height + gap
        }
        return canvas.image()
    }

    private static func tableCase(_ id: String, language: String, _ rows: [[String]]) -> BenchCase {
        BenchCase(id: id, category: .table, truth: Truth(lines: rows.flatMap(\.self), table: rows)) {
            let font = Fonts.ui(13, language: language)
            let header = Fonts.ui(13, language: language, bold: true)
            let ink = CGColor.hex(0x1D1D1F)
            let cells = rows.enumerated().map { index, row in
                row.map { NSAttributedString($0, font: index == 0 ? header : font, color: ink) }
            }
            let cellPadding = CGSize(width: 14, height: 8)
            let columnCount = rows.map(\.count).max() ?? 0
            let columnWidths = (0..<columnCount).map { column in
                (cells.compactMap { $0.indices.contains(column) ? Canvas.measure($0[column]).width : nil }.max() ?? 0) + cellPadding.width * 2
            }
            let rowHeight = Canvas.measure(cells[0][0]).height + cellPadding.height * 2
            let margin: CGFloat = 20
            let tableWidth = columnWidths.reduce(0, +)
            let tableHeight = rowHeight * CGFloat(rows.count)
            let canvas = Canvas(width: tableWidth + margin * 2, height: tableHeight + margin * 2, background: .hex(0xFFFFFF))
            canvas.fill(CGRect(x: margin, y: margin, width: tableWidth, height: rowHeight), color: .hex(0xF2F2F7))
            let rule = CGColor.hex(0xC7C7CC)
            for row in 0...rows.count {
                let y = margin + rowHeight * CGFloat(row)
                canvas.stroke(from: CGPoint(x: margin, y: y), to: CGPoint(x: margin + tableWidth, y: y), color: rule)
            }
            var x = margin
            for width in columnWidths + [0] {
                canvas.stroke(from: CGPoint(x: x, y: margin), to: CGPoint(x: x, y: margin + tableHeight), color: rule)
                x += width
            }
            for (rowIndex, row) in cells.enumerated() {
                var cellX = margin
                for (column, cell) in row.enumerated() {
                    canvas.draw(cell, x: cellX + cellPadding.width, top: margin + rowHeight * CGFloat(rowIndex) + cellPadding.height)
                    cellX += columnWidths[column]
                }
            }
            return canvas.image()
        }
    }

    enum Syntax {
        case swift
        case yaml
    }

    /// Code in SF Mono on an editor's dark background, highlighted roughly as Xcode does.
    private static func codeCase(_ id: String, syntax: Syntax, _ lines: [String]) -> BenchCase {
        BenchCase(id: id, category: .code, truth: Truth(lines: lines)) {
            let strings = lines.map { highlight($0, syntax: syntax) }
            return stack(strings, background: .hex(0x1F1F24), gap: 5, padding: 20)
        }
    }

    private static func highlight(_ line: String, syntax: Syntax) -> NSAttributedString {
        let font = Fonts.mono(12)
        let text = NSMutableAttributedString(line, font: font, color: .hex(0xFFFFFF, alpha: 0.85))
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let rules: [(pattern: String, color: CGColor)] = switch syntax {
        case .swift: [
            (#"\b[A-Z][A-Za-z0-9]*\b"#, .hex(0x5DD8FF)),
            (#"\b(func|guard|let|var|else|return|nil|as|if|in|Any)\b"#, .hex(0xFF7AB2)),
            (#"\b\d+\b"#, .hex(0xD9C97C)),
            (#"//.*$"#, .hex(0x7F8C98)),
        ]
        case .yaml: [
            (#"^\s*-?\s*[A-Za-z_-]+(?=:)"#, .hex(0xFF7AB2)),
            (#"\b\d+\b"#, .hex(0xD9C97C)),
            (#"#.*$"#, .hex(0x7F8C98)),
        ]
        }
        for rule in rules {
            let expression = try! NSRegularExpression(pattern: rule.pattern, options: [.anchorsMatchLines])
            for match in expression.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                text.addAttribute(colorKey, value: rule.color, range: match.range)
            }
        }
        return text
    }
}
