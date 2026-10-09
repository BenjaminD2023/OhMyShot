import CoreGraphics
import Foundation
import NaturalLanguage

/// Text in a picture better covered before the picture is shared, as reading found it: its kind, where
/// it is, and what it says.
public struct SensitiveText: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case email
        case phone
        case card
        case idNumber
        /// An API key, an access token, a private key.
        case secret
        case ipAddress
        /// A password after its label.
        case password
        case address
        case name
    }

    public var kind: Kind
    /// In image pixels, top-left origin: the match's own box, not its line's.
    public var box: CGRect
    public var text: String

    public init(kind: Kind, box: CGRect, text: String) {
        self.kind = kind
        self.box = box
        self.text = text
    }
}

/// Finds what in one line of recognized text is better covered before sharing. Each check aims at
/// precision first: a suggestion that is not wanted costs a glance, but a screenful of them hides the
/// ones that matter. Numbers must pass their checksums (cards, Chinese ID numbers); keys need a known
/// prefix, a label, or a long random-looking run that is not a plain hash.
public enum SensitiveTextFinder {
    public struct Match: Equatable, Sendable {
        public var kind: SensitiveText.Kind
        public var range: Range<String.Index>
    }

    /// What `line` holds, overlaps resolved toward the more specific kind (a card number is not also a
    /// phone number).
    public static func matches(in line: String) -> [Match] {
        guard line.contains(where: { $0.isLetter || $0.isNumber }) else { return [] }
        var found: [Match] = []
        found += labeledValues(in: line)
        found += secrets(in: line)
        found += idNumbers(in: line)
        found += cards(in: line)
        found += detected(in: line)
        found += chineseMobiles(in: line)
        found += ipAddresses(in: line)
        found += names(in: line)
        // Earlier checks are the more specific: the first claim on a stretch of text wins.
        var kept: [Match] = []
        for match in found where !kept.contains(where: { $0.range.overlaps(match.range) }) {
            kept.append(match)
        }
        return kept.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: Labels

    private static let passwordLabels = #"password|passwd|pwd|passphrase|pin|密码|口令"#
    private static let secretLabels = #"secret|token|api[ _-]?key|access[ _-]?key|private[ _-]?key|client[ _-]?secret|密钥|令牌|秘钥"#

    /// The value after a password's or a key's label: "Password: hunter2", "API_KEY=…", "密码：…".
    private static func labeledValues(in line: String) -> [Match] {
        var found: [Match] = []
        for (labels, kind) in [(passwordLabels, SensitiveText.Kind.password), (secretLabels, .secret)] {
            let pattern = #"(?i)(?<![A-Za-z])(?:"# + labels + #")\s*["']?\s*[:：=]\s*["']?([^\s"',;，；]+)"#
            found += regexMatches(pattern, in: line, group: 1).map { Match(kind: kind, range: $0) }
        }
        return found
    }

    // MARK: Keys and tokens

    /// After a known prefix, "|" counts as part of the key: reading takes a capital I or a small l in a
    /// long key for one, and a key cut there would be covered only up to it.
    private static let keyPatterns = [
        #"sk-(?:ant-|proj-)?[A-Za-z0-9_|-]{20,}"#,         // OpenAI, Anthropic
        #"(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9|]{16,}"#,   // Stripe
        #"gh[pousr]_[A-Za-z0-9|]{30,}"#,                   // GitHub
        #"github_pat_[A-Za-z0-9_|]{22,}"#,
        #"glpat-[A-Za-z0-9_|-]{20,}"#,                      // GitLab
        #"npm_[A-Za-z0-9]{36}"#,                            // npm
        #"hf_[A-Za-z0-9|]{30,}"#,                           // Hugging Face
        #"(?:AKIA|ASIA)[0-9A-Z]{16}"#,                      // AWS access keys
        #"xox[abprs]-[A-Za-z0-9|-]{10,}"#,                 // Slack
        #"AIza[0-9A-Za-z_-]{35}"#,                          // Google
        #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, // JSON Web Tokens
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
    ]

    private static func secrets(in line: String) -> [Match] {
        var found = keyPatterns.flatMap { regexMatches($0, in: line) }.map { Match(kind: .secret, range: $0) }
        // A long random-looking run: letters and digits mixed, high entropy, not hex (commits, checksums,
        // and UUIDs are identifiers, not secrets), and not made of words (host names, paths, identifiers in
        // code).
        for range in regexMatches(#"(?<![A-Za-z0-9_+/=-])[A-Za-z0-9_+/=-]{32,}(?![A-Za-z0-9_+/=-])"#, in: line) {
            let token = line[range]
            let hasLetter = token.contains(where: \.isLetter), hasDigit = token.contains(where: \.isNumber)
            let hex = token.allSatisfy { $0.isHexDigit || $0 == "-" }
            if hasLetter, hasDigit, !hex, wordiness(of: token) < 0.5, entropy(of: token) >= 3.5 {
                found.append(Match(kind: .secret, range: range))
            }
        }
        return found
    }

    /// How much of `text` is in runs of three or more lowercase letters, capitalized or not: about a sixth
    /// in a random token, and rarely half, but three quarters and more in words joined up ("MacBook-Pro",
    /// "makeAnnouncementForSuggestion2", "build/Products/Debug").
    static func wordiness(of text: Substring) -> Double {
        let text = String(text)
        let letters = regexMatches(#"[A-Z]?[a-z]{3,}"#, in: text).reduce(0) { $0 + text[$1].count }
        return Double(letters) / Double(max(text.count, 1))
    }

    /// Shannon entropy in bits per character.
    static func entropy(of text: Substring) -> Double {
        let counts = Dictionary(grouping: text, by: { $0 }).mapValues(\.count)
        let total = Double(text.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }

    // MARK: Numbers

    /// Mainland China's resident ID numbers: 18 characters with a valid birth date and check character.
    private static func idNumbers(in line: String) -> [Match] {
        let pattern = #"(?<![0-9])[1-9][0-9]{5}(?:18|19|20)[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[0-9]{3}[0-9Xx](?![0-9])"#
        return regexMatches(pattern, in: line).filter { isValidIDNumber(String(line[$0])) }.map { Match(kind: .idNumber, range: $0) }
    }

    static func isValidIDNumber(_ number: String) -> Bool {
        let characters = Array(number.uppercased())
        guard characters.count == 18 else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        var sum = 0
        for (index, weight) in weights.enumerated() {
            guard let digit = characters[index].wholeNumberValue else { return false }
            sum += digit * weight
        }
        return characters[17] == Array("10X98765432")[sum % 11]
    }

    /// Card numbers: 13 to 19 digits, in groups or not, that pass the Luhn check.
    private static func cards(in line: String) -> [Match] {
        regexMatches(#"(?<![0-9])[0-9](?:[ -]?[0-9]){12,18}(?![0-9])"#, in: line).filter { range in
            let digits = line[range].compactMap(\.wholeNumberValue)
            return (13...19).contains(digits.count) && passesLuhn(digits)
        }.map { Match(kind: .card, range: $0) }
    }

    static func passesLuhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// Mainland China's mobile numbers, which the system's detector does not always catch: 1, then 3 to 9,
    /// then nine digits, in groups of four after the first three or not, with +86 or not.
    private static func chineseMobiles(in line: String) -> [Match] {
        regexMatches(#"(?<![0-9])(?:\+?86[ -]?)?1[3-9][0-9](?:[ -]?[0-9]{4}){2}(?![0-9])"#, in: line).map { Match(kind: .phone, range: $0) }
    }

    private static func ipAddresses(in line: String) -> [Match] {
        let octet = #"(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"#
        return regexMatches(#"(?<![0-9.])"# + octet + #"(?:\."# + octet + #"){3}(?![0-9]|\.[0-9])"#, in: line).map { Match(kind: .ipAddress, range: $0) }
    }

    // MARK: The system's detectors

    /// Email addresses, phone numbers, and postal addresses, as the system's data detectors read them; a
    /// web link only for what it should not carry: a password in it, or a key, token, or signature among
    /// its parameters.
    private static func detected(in line: String) -> [Match] {
        let types: NSTextCheckingResult.CheckingType = [.link, .phoneNumber, .address]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return [] }
        let whole = NSRange(line.startIndex..., in: line)
        var found: [Match] = []
        for result in detector.matches(in: line, range: whole) {
            guard let range = Range(result.range, in: line) else { continue }
            switch result.resultType {
            case .link:
                guard let url = result.url else { continue }
                if url.scheme?.lowercased() == "mailto" {
                    found.append(Match(kind: .email, range: range))
                } else {
                    found += linkSecrets(in: line, range: range)
                }
            case .phoneNumber:
                if looksLikePhoneNumber(line[range]), !looksLikeDate(line[range]) {
                    found.append(Match(kind: .phone, range: range))
                }
            case .address:
                found.append(Match(kind: .address, range: range))
            default:
                continue
            }
        }
        return found
    }

    /// The detector calls many numbers phone numbers; one is taken when it is written like one: at least
    /// seven digits, and an international "+", ten digits or more, or a last group of four ("555-0199").
    /// Bare runs of seven to nine digits are order numbers, counts, and IDs far more often.
    static func looksLikePhoneNumber(_ text: Substring) -> Bool {
        let digits = text.filter(\.isNumber).count
        guard digits >= 7 else { return false }
        let groups = text.split { !$0.isNumber }
        return text.trimmingCharacters(in: .whitespaces).hasPrefix("+") || digits >= 10 || (groups.count > 1 && (groups.last?.count ?? 0) >= 4)
    }

    /// "2026-10-08", "2026-10 081", "10/08/2026": a year and a month first, or a day, month, and year.
    static func looksLikeDate(_ text: Substring) -> Bool {
        let text = String(text).trimmingCharacters(in: .whitespaces)
        return text.range(of: #"^(?:19|20)[0-9]{2}[-/.](?:0?[1-9]|1[0-2])(?:[-/. ]|$)"#, options: .regularExpression) != nil
            || text.range(of: #"^[0-9]{1,2}[-/.][0-9]{1,2}[-/.](?:19|20)?[0-9]{2}$"#, options: .regularExpression) != nil
    }

    private static let secretParameters = #"token|access_token|refresh_token|id_token|key|api_key|apikey|secret|client_secret|password|passwd|pwd|sig|signature|auth|code|session|sessionid"#

    /// In a web link: the password in "user:password@", and the values of parameters that hold secrets.
    private static func linkSecrets(in line: String, range: Range<String.Index>) -> [Match] {
        let link = String(line[range])
        var found: [Match] = []
        for value in regexMatches(#"(?<=://)[^/@\s:]+:([^/@\s]+)@"#, in: link, group: 1) {
            found.append(Match(kind: .password, range: shifted(value, in: link, to: line, at: range.lowerBound)))
        }
        for value in regexMatches(#"(?i)[?&#](?:"# + secretParameters + #")=([^&#\s]+)"#, in: link, group: 1) {
            found.append(Match(kind: .secret, range: shifted(value, in: link, to: line, at: range.lowerBound)))
        }
        return found
    }

    // MARK: Names

    /// People's names, as the system's language model tags them: good for English, uneven for Chinese.
    private static func names(in line: String) -> [Match] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = line
        var found: [Match] = []
        tagger.enumerateTags(in: line.startIndex..<line.endIndex, unit: .word, scheme: .nameType, options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if tag == .personalName, looksLikeName(line[range]) { found.append(Match(kind: .name, range: range)) }
            return true
        }
        return found
    }

    private static let nameParticles: Set<String> = ["van", "von", "de", "da", "di", "del", "della", "der", "den", "du", "dos", "das", "le", "la", "bin", "ibn", "al"]

    /// The common Chinese surnames, which together cover most people.
    private static let surnames = Set("王李张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾肖田董袁潘于蒋蔡余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付傅方白邹孟熊秦邱江尹薛闫段雷侯龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤常温康施文牛樊葛邢安齐易乔伍庞颜倪庄聂章鲁岳翟殷詹申欧耿关兰焦俞左柳甘祝包宁尚符舒阮柯纪梅童凌毕单季裴霍涂成苗谷盛曲翁冉骆蓝路游辛靳管柴蒙鲍华喻祁蒲房滕屈饶解牟艾尤阳时穆农司卓古吉缪简车项连芦麦褚娄窦戚岑景党宫费卜冷晏席卫米柏宗瞿桂全佟应臧闵苟邬边卞姬师和仇栾隋商刁沙荣巫寇桑郎甄丛仲虞敖巩明佘池查麻苑迟邝")
    private static let doubleSurnames: Set<String> = ["欧阳", "司马", "上官", "诸葛", "东方", "皇甫", "尉迟", "公孙", "慕容", "长孙", "宇文", "司徒", "夏侯", "轩辕", "令狐", "钟离", "端木", "南宫", "西门", "独孤"]

    /// Whether what the tagger calls a name is written like one; the tagger alone takes product names
    /// ("Hermes") and Chinese words ("运维") for people. In scripts with capitals: two words or more in one
    /// script (Latin, Cyrillic, or Greek: a mix is misreading), no digits, every word capitalized but
    /// particles ("van", "de"), no dot inside a word ("tsconfig.json"), and in capitals only, words of three
    /// letters or more (not "API TX"). In Chinese: a common surname, then a given name of one or two
    /// characters. Other scripts are taken as tagged.
    static func looksLikeName(_ text: Substring) -> Bool {
        if text.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
            let characters = Array(text.filter { !$0.isWhitespace })
            if characters.count >= 3, doubleSurnames.contains(String(characters[0...1])) { return characters.count <= 4 }
            return (2...3).contains(characters.count) && surnames.contains(characters[0])
        }
        guard text.contains(where: { $0.isUppercase || $0.isLowercase }) else { return true }
        guard !text.contains(where: \.isNumber) else { return false }
        let words = text.split(whereSeparator: \.isWhitespace)
        let written = words.allSatisfy { word in
            (word.first?.isUppercase == true || nameParticles.contains(word.lowercased())) && !word.dropLast().contains(".")
        }
        let capitalsOnly = !text.contains(where: \.isLowercase)
        let acronym = capitalsOnly && words.contains { $0.filter(\.isLetter).count < 3 }
        return written && !acronym && words.count > 1 && scripts(of: text).count == 1
    }

    /// The scripts of a name's letters, of those that have capitals.
    private static func scripts(of text: Substring) -> Set<String> {
        Set(text.unicodeScalars.compactMap { scalar -> String? in
            guard scalar.properties.isAlphabetic else { return nil }
            switch scalar.value {
            case 0x370...0x3FF, 0x1F00...0x1FFF: return "Greek"
            case 0x400...0x52F: return "Cyrillic"
            default: return "Latin"
            }
        })
    }

    // MARK: Helpers

    private static func regexMatches(_ pattern: String, in line: String, group: Int = 0) -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { result in
            guard result.numberOfRanges > group, result.range(at: group).location != NSNotFound else { return nil }
            return Range(result.range(at: group), in: line)
        }
    }

    /// `range` in `part`, which begins at `start` in `line`, as a range in `line`.
    private static func shifted(_ range: Range<String.Index>, in part: String, to line: String, at start: String.Index) -> Range<String.Index> {
        let lower = line.index(start, offsetBy: part.distance(from: part.startIndex, to: range.lowerBound))
        let upper = line.index(lower, offsetBy: part.distance(from: range.lowerBound, to: range.upperBound))
        return lower..<upper
    }
}
