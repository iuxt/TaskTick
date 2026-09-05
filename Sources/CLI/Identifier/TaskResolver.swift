import Foundation
import TaskTickCore

enum TaskResolverError: Error, CustomStringConvertible {
    case noMatch(String)
    case ambiguous([(id: UUID, name: String)])

    var description: String {
        switch self {
        case .noMatch(let q):
            return "no task matches \"\(q)\""
        case .ambiguous(let cs):
            let lines = cs.map { c in
                "  \(String(c.id.uuidString.prefix(4)).lowercased()) \(c.name)"
            }.joined(separator: "\n")
            return "multiple matches:\n\(lines)\nbe more specific."
        }
    }
}

/// Multi-tier identifier resolver. Generic over the item type so it can be
/// unit-tested without standing up SwiftData.
struct TaskResolver<Item> {
    let items: [Item]
    let idOf: (Item) -> UUID
    let nameOf: (Item) -> String

    /// 1. UUID full match
    /// 2. UUID prefix match (≥4 chars, hex)
    /// 3. Name case-insensitive exact match
    /// 4. Fuzzy name match (FuzzyMatch.score)
    /// Throws .noMatch on zero hits, .ambiguous on multi-hit at any tier.
    func resolve(_ query: String) throws -> Item {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { throw TaskResolverError.noMatch(query) }

        // Tier 1: UUID full match
        if let uuid = UUID(uuidString: q) {
            if let hit = items.first(where: { idOf($0) == uuid }) {
                return hit
            }
            throw TaskResolverError.noMatch(query)
        }

        // Tier 2: UUID prefix (≥4 hex chars, normalize to lowercase)
        let lowered = q.lowercased()
        if lowered.count >= 4, lowered.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            let prefixHits = items.filter { idOf($0).uuidString.lowercased().hasPrefix(lowered) }
            if prefixHits.count == 1 { return prefixHits[0] }
            if prefixHits.count > 1 { throw ambiguousError(prefixHits) }
        }

        // Tier 3: Exact name (case-insensitive)
        let exactHits = items.filter { nameOf($0).lowercased() == lowered }
        if exactHits.count == 1 { return exactHits[0] }
        if exactHits.count > 1 { throw ambiguousError(exactHits) }

        // Tier 4: Fuzzy name match — score every candidate, keep top.
        let scored = items.compactMap { item -> (item: Item, score: Int)? in
            guard let s = FuzzyMatch.score(query: q, candidate: nameOf(item)) else { return nil }
            return (item, s)
        }
        guard !scored.isEmpty else { throw TaskResolverError.noMatch(query) }
        let topScore = scored.map(\.score).max()!
        let topMatches = scored.filter { $0.score == topScore }.map(\.item)
        if topMatches.count == 1 { return topMatches[0] }
        throw ambiguousError(topMatches)
    }

    private func ambiguousError(_ items: [Item]) -> TaskResolverError {
        .ambiguous(items.map { (id: idOf($0), name: nameOf($0)) })
    }
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self.lowercased().first!)
    }
}
