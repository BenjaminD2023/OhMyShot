import Foundation
import OMSCore

/// The folded text stays on one background actor for the lifetime of the history window. Queries pass
/// only text and lightweight revision metadata, never a freshly copied or rebuilt OCR index.
actor HistorySearchIndex {
    struct Change: Sendable {
        let id: UUID
        let generation: UInt64
        let entry: HistorySearch.Entry?
    }

    struct Result: Sendable {
        let terms: [String]
        let matches: [UUID: HistorySearch.Match]
    }

    private struct Indexed {
        let generation: UInt64
        let entry: HistorySearch.Entry?
    }

    private var entries: [UUID: Indexed] = [:]
    private var released = false
    private let didBeginSearch: (@Sendable () -> Void)?

    init(didBeginSearch: (@Sendable () -> Void)? = nil) {
        self.didBeginSearch = didBeginSearch
    }

    func update(_ changes: [Change]) {
        guard !released else { return }
        for change in changes where change.generation >= (entries[change.id]?.generation ?? 0) {
            entries[change.id] = Indexed(generation: change.generation, entry: change.entry)
        }
    }

    func search(_ query: String, generations: [UUID: UInt64]) throws -> Result {
        try Task.checkCancellation()
        guard !released else { return Result(terms: [], matches: [:]) }
        didBeginSearch?()
        let terms = HistorySearch.terms(in: query)
        guard !terms.isEmpty else { return Result(terms: [], matches: [:]) }
        var matches: [UUID: HistorySearch.Match] = [:]
        for (id, indexed) in entries {
            try Task.checkCancellation()
            guard indexed.generation == generations[id], let entry = indexed.entry,
                  let match = HistorySearch.match(terms, in: entry, includingExcerpt: false) else { continue }
            matches[id] = match
        }
        return Result(terms: terms, matches: matches)
    }

    func excerpt(for id: UUID, terms: [String], generation: UInt64) throws -> HistorySearch.Match? {
        try Task.checkCancellation()
        guard !released, let indexed = entries[id], indexed.generation == generation, let entry = indexed.entry else { return nil }
        return HistorySearch.match(terms, in: entry)
    }

    func release() {
        released = true
        entries = [:]
    }
}
