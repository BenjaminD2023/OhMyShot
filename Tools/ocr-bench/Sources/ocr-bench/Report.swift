import Foundation
import OMSOCR

/// One engine on one case.
struct CaseRun: Codable, Sendable {
    var id: String
    var category: Category
    var score: Score?
    var milliseconds: Double?
    var output: String?
    var tables: [[[String]]]?
    var error: String?
}

/// One engine on the whole corpus.
struct EngineRun: Codable, Sendable {
    var engine: String
    var warmupMilliseconds: Double?
    var cases: [CaseRun]
}

/// A committed reference run, compared against later runs on the same major macOS version.
struct Baseline: Codable {
    var macOS: String
    var engine: String
    var cases: [String: Score]
}

enum Report {
    static func markdown(runs: [EngineRun], corpus: [BenchCase], environment: Environment, regressions: [String]) -> String {
        var out: [String] = []
        out.append("# OCR benchmark")
        out.append("")
        out.append("\(environment.date) · macOS \(environment.macOS) · \(corpus.count) cases · \(runs.count) engines")
        out.append("")
        out.append("- RecognizeTextRequest languages (\(environment.textLanguages.count)): \(environment.textLanguages.joined(separator: ", "))")
        out.append("- RecognizeDocumentsRequest languages (\(environment.documentLanguages.count)): \(environment.documentLanguages.joined(separator: ", "))")
        out.append("")
        out.append("Content CER ignores whitespace, punctuation width, and emoji: it counts misread characters. Raw CER is what a paste would contain; the gap between them is formatting that post-processing can fix.")
        out.append("")

        out.append("## Content CER by case (lower is better)")
        out.append("")
        out.append(contentsOf: caseTable(runs: runs, corpus: corpus) { $0.cerContent })
        out.append("")
        out.append("## Raw CER by case")
        out.append("")
        out.append(contentsOf: caseTable(runs: runs, corpus: corpus) { $0.cerRaw })
        out.append("")
        out.append("## Line order by case (higher is better)")
        out.append("")
        out.append(contentsOf: caseTable(runs: runs, corpus: corpus, format: ratio) { $0.lineOrder })
        out.append("")

        out.append("## Structure")
        out.append("")
        out.append("| engine | code indentation | table shape | table cells |")
        out.append("| --- | --- | --- | --- |")
        for run in runs {
            let indents = run.cases.compactMap { $0.score?.indentation }
            let shapes = run.cases.compactMap { $0.score?.tableShape }
            let cells = run.cases.compactMap { $0.score?.tableCells }
            out.append("| \(run.engine) | \(indents.isEmpty ? "—" : ratio(mean(indents))) | \(shapes.isEmpty ? "—" : "\(shapes.filter { $0 }.count)/\(shapes.count)") | \(cells.isEmpty ? "—" : ratio(mean(cells))) |")
        }
        out.append("")

        out.append("## Time per image")
        out.append("")
        out.append("| engine | first call | p50 | p95 | max |")
        out.append("| --- | --- | --- | --- | --- |")
        for run in runs {
            let times = run.cases.compactMap(\.milliseconds).sorted()
            out.append("| \(run.engine) | \(run.warmupMilliseconds.map(milliseconds) ?? "—") | \(milliseconds(percentile(times, 0.5))) | \(milliseconds(percentile(times, 0.95))) | \(milliseconds(times.last ?? 0)) |")
        }

        let failures = runs.flatMap { run in run.cases.compactMap { item in item.error.map { "- \(run.engine) / \(item.id): \($0)" } } }
        if !failures.isEmpty {
            out.append("")
            out.append("## Failures")
            out.append("")
            out.append(contentsOf: failures)
        }
        if !regressions.isEmpty {
            out.append("")
            out.append("## Regressions against the baseline")
            out.append("")
            out.append(contentsOf: regressions.map { "- \($0)" })
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func caseTable(runs: [EngineRun], corpus: [BenchCase], format: (Double) -> String = percent, value: (Score) -> Double) -> [String] {
        var rows = ["| case | category | " + runs.map(\.engine).joined(separator: " | ") + " |"]
        rows.append("| --- | --- | " + runs.map { _ in "---" }.joined(separator: " | ") + " |")
        for item in corpus {
            let cells = runs.map { run -> String in
                guard let found = run.cases.first(where: { $0.id == item.id }) else { return "—" }
                guard let score = found.score else { return "error" }
                return format(value(score))
            }
            rows.append("| \(item.id) | \(item.category.rawValue) | " + cells.joined(separator: " | ") + " |")
        }
        let means = runs.map { run in format(mean(run.cases.compactMap { $0.score.map(value) })) }
        rows.append("| **mean** | | " + means.map { "**\($0)**" }.joined(separator: " | ") + " |")
        return rows
    }

    /// Cases where a run is materially worse than the committed baseline.
    static func regressions(_ run: EngineRun, baseline: Baseline) -> [String] {
        run.cases.compactMap { item in
            guard let score = item.score, let reference = baseline.cases[item.id] else { return nil }
            var problems: [String] = []
            if score.cerContent > reference.cerContent + 0.02 {
                problems.append("content CER \(percent(reference.cerContent)) → \(percent(score.cerContent))")
            }
            if score.lineOrder < reference.lineOrder - 0.05 {
                problems.append("line order \(ratio(reference.lineOrder)) → \(ratio(score.lineOrder))")
            }
            return problems.isEmpty ? nil : "\(run.engine) / \(item.id): " + problems.joined(separator: ", ")
        }
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    static func ratio(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func milliseconds(_ value: Double) -> String {
        String(format: "%.0f ms", value)
    }
}

struct Environment {
    var date: String
    var macOS: String
    var macOSMajor: Int
    var textLanguages: [String]
    var documentLanguages: [String]
}
