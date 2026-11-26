import Foundation

/// How a recognized LaTeX formula is wrapped when copied to the clipboard.
public enum FormulaDelimiter: String, CaseIterable, Codable, Sendable {
    /// Plain LaTeX with no surrounding delimiters, e.g. `x^2 + y^2`.
    case raw
    /// Inline math delimited with single dollars, e.g. `$x^2 + y^2$`.
    case inlineDollar
    /// Display math delimited with double dollars, e.g. `$$x^2 + y^2$$`.
    case displayDollar
    /// Inline math delimited with `\(…\)`.
    case inlineParen

    /// Wraps `latex` in the chosen delimiter. Returns `latex` trimmed when empty or already wrapped identically.
    public func wrap(_ latex: String) -> String {
        let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return latex }
        switch self {
        case .raw:
            return trimmed
        case .inlineDollar:
            if trimmed.hasPrefix("$"), trimmed.hasSuffix("$") { return trimmed }
            return "$\(trimmed)$"
        case .displayDollar:
            if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$") { return trimmed }
            return "$$\(trimmed)$$"
        case .inlineParen:
            if trimmed.hasPrefix(#"\("#), trimmed.hasSuffix(#"\)"#) { return trimmed }
            return #"\("# + trimmed + #"\)"#
        }
    }
}
