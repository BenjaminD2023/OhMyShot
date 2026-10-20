import Foundation

/// A formula's LaTeX, as `FormulaMerge` writes it into a line, made readable as plain text for drawing where the picture
/// can't show the formula itself: a translation laid over the picture (`TranslationOverlay`). Greek letters, operators,
/// and relations become their characters; a script becomes Unicode's superscripts or subscripts where every character
/// has one (`x^(2q)` where one hasn't); a fraction a/b, in brackets beside more; a root √. Copied text keeps the LaTeX.
/// A formula holding anything this doesn't know (a matrix, an alignment, a command not listed) is left as its LaTeX,
/// whole: half a formula made readable would read as neither.
public enum MathText {
    /// `text` with each formula it holds (`$…$`, `$$…$$`) readable, where it can be.
    public static func readable(in text: String) -> String {
        guard text.contains("$") else { return text }
        var result = ""
        var rest = text[...]
        while let span = rest.firstMatch(of: TextAssembler.mathSpan) {
            result += rest[..<span.range.lowerBound]
            let source = String(span.output)
            let latex = source.hasPrefix("$$") ? source.dropFirst(2).dropLast(2) : source.dropFirst().dropLast()
            result += readable(String(latex)) ?? source
            rest = rest[span.range.upperBound...]
        }
        return result + rest
    }

    /// One formula's LaTeX readable, or nil when it holds something this doesn't know.
    public static func readable(_ latex: String) -> String? {
        var parser = Parser(Array(latex))
        guard let atoms = try? parser.expression(), parser.isAtEnd else { return nil }
        let text = joined(atoms).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    // MARK: Atoms

    /// A piece of the formula as drawn, and what it is to its neighbors.
    fileprivate struct Atom {
        enum Kind {
            /// A fraction a/b, which takes brackets beside anything but an operator.
            case fraction
            /// A relation or operator (=, +, ∈, a comma).
            case `operator`
            /// A function's name (sin, max, softmax), which a letter after it is set apart from.
            case function
            case other
        }

        var text: String
        var kind: Kind
    }

    fileprivate struct Unknown: Error {}

    fileprivate static func joined(_ atoms: [Atom]) -> String {
        let atoms = atoms.filter { !$0.text.isEmpty }
        var output = ""
        for (index, atom) in atoms.enumerated() {
            var text = atom.text
            if atom.kind == .fraction {
                let before = index > 0 ? atoms[index - 1].kind : .operator
                let after = index + 1 < atoms.count ? atoms[index + 1].kind : .operator
                if before != .operator || after != .operator { text = "(\(text))" }
            }
            if index > 0, atoms[index - 1].kind == .function, let first = text.first, first.isLetter || first.isNumber { output += " " }
            output += text
        }
        return output
    }

    /// Brackets around a part of a fraction or root that is more than one term.
    fileprivate static func bracketed(_ text: String) -> String {
        text.count > 1 && text.contains(where: { $0.isWhitespace || "+−-=<>/·×±∓,".contains($0) }) ? "(\(text))" : text
    }

    /// `text` raised or lowered: in Unicode's scripts when every character has one, else after `mark`.
    fileprivate static func script(_ text: String, _ map: [Character: Character], mark: Character) -> String {
        let text = text.filter { !$0.isWhitespace }
        if !text.isEmpty, text.allSatisfy({ map[$0] != nil }) { return String(text.compactMap { map[$0] }) }
        return text.count == 1 ? "\(mark)\(text)" : "\(mark)(\(text))"
    }

    // MARK: Parsing

    fileprivate struct Parser {
        let characters: [Character]
        var index = 0

        init(_ characters: [Character]) {
            self.characters = characters
        }

        var isAtEnd: Bool { index >= characters.count }

        private var next: Character? { index < characters.count ? characters[index] : nil }

        private mutating func skipSpaces() {
            while let next, next.isWhitespace { index += 1 }
        }

        /// The atoms up to a closing brace (left for the caller) or the end, each with its scripts.
        mutating func expression() throws -> [Atom] {
            var atoms: [Atom] = []
            while true {
                skipSpaces()
                guard let next, next != "}" else { break }
                var atom = try self.atom()
                var superscript: String?
                var subscriptText: String?
                while true {
                    skipSpaces()
                    guard let mark = self.next, mark == "^" || mark == "_" else { break }
                    index += 1
                    let argument = MathText.joined(try self.argument())
                    if mark == "^" {
                        guard superscript == nil else { throw Unknown() }
                        superscript = argument
                    } else {
                        guard subscriptText == nil else { throw Unknown() }
                        subscriptText = argument
                    }
                }
                if superscript != nil || subscriptText != nil {
                    if atom.kind == .fraction {
                        atom.text = "(\(atom.text))"
                        atom.kind = .other
                    } else if atom.kind == .operator {
                        atom.kind = .other
                    }
                    if let subscriptText { atom.text += MathText.script(subscriptText, MathText.subscripts, mark: "_") }
                    if let superscript { atom.text += MathText.script(superscript, MathText.superscripts, mark: "^") }
                }
                atoms.append(atom)
            }
            return atoms
        }

        /// A command's argument or a script: a group in braces, or one character or command.
        private mutating func argument() throws -> [Atom] {
            skipSpaces()
            guard let next else { throw Unknown() }
            if next == "{" {
                index += 1
                let atoms = try expression()
                guard self.next == "}" else { throw Unknown() }
                index += 1
                return atoms
            }
            guard next != "}", next != "^", next != "_" else { throw Unknown() }
            return [try atom()]
        }

        private mutating func atom() throws -> Atom {
            guard let character = next else { throw Unknown() }
            switch character {
            case "{":
                let atoms = try argument()
                let drawn = atoms.filter { !$0.text.isEmpty }
                return Atom(text: MathText.joined(atoms), kind: drawn.count == 1 ? drawn[0].kind : .other)
            case "\\":
                index += 1
                return try command()
            case "^", "_":
                // A script with nothing before it ({}^{2}).
                return Atom(text: "", kind: .other)
            case "&", "#", "%", "$":
                throw Unknown()
            default:
                index += 1
                switch character {
                case "-": return Atom(text: "−", kind: .operator)
                case "'": return Atom(text: "′", kind: .other)
                case "~": return Atom(text: " ", kind: .operator)
                case "+", "=", "<", ">", ",", ";", ":", "|", "/", "*": return Atom(text: String(character), kind: .operator)
                default: return Atom(text: String(character), kind: .other)
                }
            }
        }

        private mutating func command() throws -> Atom {
            guard let first = next else { throw Unknown() }
            var name = String(first)
            index += 1
            if first.isLetter {
                while let next, next.isLetter {
                    name.append(next)
                    index += 1
                }
            }
            if let symbol = MathText.operators[name] { return Atom(text: symbol, kind: .operator) }
            if let symbol = MathText.letters[name] ?? MathText.symbols[name] { return Atom(text: symbol, kind: .other) }
            if MathText.functions.contains(name) { return Atom(text: name, kind: .function) }
            switch name {
            case ",", ":", ">": return Atom(text: "\u{2009}", kind: .operator)
            case ";", " ": return Atom(text: " ", kind: .operator)
            case "quad": return Atom(text: "\u{2003}", kind: .operator)
            case "qquad": return Atom(text: "\u{2003}\u{2003}", kind: .operator)
            case "!", "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits": return Atom(text: "", kind: .other)
            case "{", "}", "%", "$", "#", "&", "_": return Atom(text: name, kind: .other)
            case "|": return Atom(text: "‖", kind: .other)
            case "frac", "dfrac", "tfrac", "cfrac":
                let numerator = MathText.joined(try argument())
                let denominator = MathText.joined(try argument())
                if let vulgar = MathText.vulgarFractions["\(numerator)/\(denominator)"] { return Atom(text: vulgar, kind: .other) }
                guard !numerator.isEmpty, !denominator.isEmpty else { throw Unknown() }
                return Atom(text: MathText.bracketed(numerator) + "/" + MathText.bracketed(denominator), kind: .fraction)
            case "sqrt":
                skipSpaces()
                var degree: String?
                if next == "[" {
                    index += 1
                    guard let close = characters[index...].firstIndex(of: "]") else { throw Unknown() }
                    var inner = Parser(Array(characters[index..<close]))
                    let atoms = try inner.expression()
                    guard inner.isAtEnd else { throw Unknown() }
                    degree = MathText.joined(atoms)
                    index = close + 1
                }
                let radicand = MathText.joined(try argument())
                guard !radicand.isEmpty else { throw Unknown() }
                let sign: String
                switch degree {
                case nil: sign = "√"
                case "3": sign = "∛"
                case "4": sign = "∜"
                case let degree?:
                    guard degree.allSatisfy({ MathText.superscripts[$0] != nil }) else { throw Unknown() }
                    sign = MathText.script(degree, MathText.superscripts, mark: "^") + "√"
                }
                return Atom(text: sign + MathText.bracketed(radicand), kind: .other)
            case "text", "textrm", "textnormal", "textup", "textbf", "textit", "textsf", "texttt", "mbox", "emph":
                return Atom(text: try rawGroup(), kind: .other)
            case "mathrm", "operatorname", "mathit", "mathbf", "mathsf", "mathtt", "boldsymbol", "bm":
                let text = MathText.joined(try argument())
                let isName = text.count > 1 && text.allSatisfy(\.isLetter)
                return Atom(text: text, kind: isName ? .function : .other)
            case "mathbb", "mathcal", "mathscr":
                let text = MathText.joined(try argument())
                let map = name == "mathbb" ? MathText.doubleStruck : MathText.scriptCapitals
                guard !text.isEmpty, text.allSatisfy({ map[$0] != nil }) else { throw Unknown() }
                return Atom(text: String(text.compactMap { map[$0] }), kind: .other)
            case "left", "right", "middle", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr":
                skipSpaces()
                guard let delimiter = next else { throw Unknown() }
                if delimiter == "." {
                    index += 1
                    return Atom(text: "", kind: .other)
                }
                let atom = try self.atom()
                return Atom(text: atom.text, kind: .other)
            case "not":
                skipSpaces()
                let negated = try atom()
                guard let symbol = MathText.negated[negated.text] else { throw Unknown() }
                return Atom(text: symbol, kind: .operator)
            default:
                if let mark = MathText.accents[name] {
                    let text = MathText.joined(try argument())
                    if text.count == 1 { return Atom(text: text + String(mark), kind: .other) }
                    // A bar over several characters: one over each.
                    guard name == "bar" || name == "overline", !text.isEmpty, text.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw Unknown() }
                    return Atom(text: text.map { "\($0)\u{305}" }.joined(), kind: .other)
                }
                throw Unknown()
            }
        }

        /// A group's characters as they are, spaces kept (\text{ if }), with no command inside.
        private mutating func rawGroup() throws -> String {
            skipSpaces()
            guard next == "{" else { throw Unknown() }
            index += 1
            var depth = 0
            var text = ""
            while let character = next {
                index += 1
                switch character {
                case "\\", "$": throw Unknown()
                case "{": depth += 1
                case "}":
                    if depth == 0 { return text }
                    depth -= 1
                default: text.append(character)
                }
            }
            throw Unknown()
        }
    }

    // MARK: Tables

    fileprivate static let letters: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο",
        "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
    ]

    fileprivate static let operators: [String: String] = [
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "leqslant": "⩽", "geqslant": "⩾", "neq": "≠", "ne": "≠", "approx": "≈",
        "sim": "∼", "simeq": "≃", "cong": "≅", "equiv": "≡", "propto": "∝", "lesssim": "≲", "gtrsim": "≳", "ll": "≪", "gg": "≫",
        "prec": "≺", "succ": "≻", "preceq": "⪯", "succeq": "⪰", "doteq": "≐", "triangleq": "≜", "coloneqq": "≔",
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "setminus": "∖", "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗",
        "star": "⋆", "circ": "∘", "oplus": "⊕", "otimes": "⊗", "odot": "⊙", "wedge": "∧", "land": "∧", "vee": "∨", "lor": "∨",
        "neg": "¬", "lnot": "¬", "mid": "∣", "parallel": "∥", "perp": "⊥", "models": "⊨", "vdash": "⊢",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "leftrightarrow": "↔", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "Leftrightarrow": "⇔", "implies": "⟹", "impliedby": "⟸", "iff": "⟺", "mapsto": "↦", "longrightarrow": "⟶",
        "longleftarrow": "⟵", "uparrow": "↑", "downarrow": "↓",
    ]

    fileprivate static let symbols: [String: String] = [
        "infty": "∞", "partial": "∂", "nabla": "∇", "forall": "∀", "exists": "∃", "nexists": "∄", "emptyset": "∅",
        "varnothing": "∅", "ell": "ℓ", "hbar": "ℏ", "imath": "ı", "jmath": "ȷ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ",
        "angle": "∠", "triangle": "△", "square": "□", "cdots": "⋯", "ldots": "…", "dots": "…", "vdots": "⋮", "ddots": "⋱",
        "prime": "′", "top": "⊤", "bot": "⊥", "degree": "°", "bullet": "•", "dagger": "†", "ddagger": "‡",
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉", "lbrace": "{", "rbrace": "}",
        "vert": "|", "Vert": "‖", "lvert": "|", "rvert": "|", "lVert": "‖", "rVert": "‖", "backslash": "\\",
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮", "bigcup": "⋃",
        "bigcap": "⋂", "bigoplus": "⨁", "bigotimes": "⨂", "bigvee": "⋁", "bigwedge": "⋀",
    ]

    fileprivate static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth", "log", "ln",
        "lg", "exp", "max", "min", "sup", "inf", "lim", "liminf", "limsup", "det", "dim", "ker", "deg", "gcd", "arg", "Pr",
        "hom", "mod", "bmod",
    ]

    fileprivate static let negated: [String: String] = ["=": "≠", "∈": "∉", "<": "≮", ">": "≯", "≡": "≢", "⊂": "⊄", "⊆": "⊈"]

    fileprivate static let accents: [String: Character] = [
        "hat": "\u{302}", "widehat": "\u{302}", "bar": "\u{304}", "overline": "\u{305}", "tilde": "\u{303}",
        "widetilde": "\u{303}", "dot": "\u{307}", "ddot": "\u{308}", "vec": "\u{20D7}", "check": "\u{30C}",
        "breve": "\u{306}", "acute": "\u{301}", "grave": "\u{300}", "mathring": "\u{30A}",
    ]

    fileprivate static let vulgarFractions: [String: String] = [
        "1/2": "½", "1/3": "⅓", "2/3": "⅔", "1/4": "¼", "3/4": "¾", "1/5": "⅕", "2/5": "⅖", "3/5": "⅗", "4/5": "⅘",
        "1/6": "⅙", "5/6": "⅚", "1/8": "⅛", "3/8": "⅜", "5/8": "⅝", "7/8": "⅞",
    ]

    fileprivate static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ",
        "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ",
        "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ", "A": "ᴬ", "B": "ᴮ", "D": "ᴰ",
        "E": "ᴱ", "G": "ᴳ", "H": "ᴴ", "I": "ᴵ", "J": "ᴶ", "K": "ᴷ", "L": "ᴸ", "M": "ᴹ", "N": "ᴺ", "O": "ᴼ", "P": "ᴾ",
        "R": "ᴿ", "T": "ᵀ", "U": "ᵁ", "V": "ⱽ", "W": "ᵂ", "⊤": "ᵀ", "α": "ᵅ", "β": "ᵝ", "γ": "ᵞ", "δ": "ᵟ", "θ": "ᶿ",
        "ϕ": "ᵠ", "φ": "ᵠ", "χ": "ᵡ", "′": "′", "*": "*", "∗": "*",
    ]

    fileprivate static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "−": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
        "β": "ᵦ", "γ": "ᵧ", "ρ": "ᵨ", "φ": "ᵩ", "ϕ": "ᵩ", "χ": "ᵪ", ",": ",",
    ]

    /// \mathbb's letters: Unicode's double-struck capitals, those of the Letterlike Symbols block where it has them.
    fileprivate static let doubleStruck: [Character: Character] = {
        let letterlike: [Character: Character] = ["C": "ℂ", "H": "ℍ", "N": "ℕ", "P": "ℙ", "Q": "ℚ", "R": "ℝ", "Z": "ℤ"]
        var map = letterlike
        for (offset, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() where map[letter] == nil {
            map[letter] = Character(UnicodeScalar(0x1D538 + offset)!)
        }
        map["1"] = "𝟙"
        return map
    }()

    /// \mathcal's letters: Unicode's script capitals, those of the Letterlike Symbols block where it has them.
    fileprivate static let scriptCapitals: [Character: Character] = {
        let letterlike: [Character: Character] = ["B": "ℬ", "E": "ℰ", "F": "ℱ", "H": "ℋ", "I": "ℐ", "L": "ℒ", "M": "ℳ", "R": "ℛ"]
        var map = letterlike
        for (offset, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() where map[letter] == nil {
            map[letter] = Character(UnicodeScalar(0x1D49C + offset)!)
        }
        return map
    }()
}
