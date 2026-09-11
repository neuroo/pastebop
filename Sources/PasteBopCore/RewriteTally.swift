//
//  RewriteTally.swift
//  PasteBopCore
//

/// How often each rule has fired. Filled by a second pass over text already
/// known to need rewriting, so the scanner's loop carries no counting.
public struct RewriteTally: Sendable, Equatable {

    /// Keyed by `Pattern.key`. A single scalar's key is its bare code point,
    /// so statistics recorded before substring rules existed still read.
    public private(set) var counts: [String: Int]

    public init(counts: [String: Int] = [:]) {
        self.counts = counts
    }

    public var characterCount: Int {
        counts.values.reduce(0, +)
    }

    public var isEmpty: Bool { counts.isEmpty }

    public mutating func record(_ key: String, times: Int = 1) {
        counts[key, default: 0] += times
    }

    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(counts: lhs.counts.merging(rhs.counts, uniquingKeysWith: +))
    }

    public static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }

    // MARK: - Presentation

    public struct Offender: Sendable, Identifiable {
        public let key: String
        public let count: Int
        public let name: String
        public let category: Replacement.Category
        /// Nil when there is nothing visible to show.
        public let glyph: String?

        public var id: String { key }
    }

    /// Commonest first.
    public func topOffenders(limit: Int = 5, rules: RewriteRules = .builtIn) -> [Offender] {
        counts
            .sorted(byCountThen: <)
            .prefix(limit)
            .map { key, count in
                let rule = rules.rule(forKey: key)
                let category = rule?.category ?? .custom
                return Offender(
                    key: key,
                    count: count,
                    name: rule?.name.sentenceCased ?? key.uppercased(),
                    category: category,
                    glyph: category.hasVisibleGlyphs ? rule.flatMap { Self.glyph(for: $0) } : nil
                )
            }
    }

    /// Busiest first.
    public func familyTotals(
        rules: RewriteRules = .builtIn
    ) -> [(category: Replacement.Category, count: Int)] {
        var totals: [Replacement.Category: Int] = [:]
        for (key, count) in counts {
            totals[rules.rule(forKey: key)?.category ?? .custom, default: 0] += count
        }
        return totals
            .sorted(byCountThen: { $0.rawValue < $1.rawValue })
            .map { (category: $0.key, count: $0.value) }
    }

    private static func glyph(for rule: Replacement) -> String? {
        if let scalar = rule.scalar { return String(scalar) }
        if let text = rule.sequenceText, !text.isEmpty { return text }
        return nil
    }

    // MARK: - Storage

    public var storage: [String: Int] { counts }

    /// Skips anything that is not a rule key with a positive count: one corrupt
    /// entry must not throw away the rest.
    public init(storage: [String: Any]) {
        counts = storage.compactMapValues { $0 as? Int }.filter { key, count in
            count > 0 && !key.isEmpty
                && key.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                    !$0.isEmpty && UInt32($0.split(separator: "-")[0], radix: 16) != nil
                }
        }
    }
}

private extension Dictionary where Value == Int {
    /// Commonest first; ties broken on the key so the order does not follow
    /// the hash seed.
    func sorted(byCountThen tieBreak: (Key, Key) -> Bool) -> [(key: Key, value: Value)] {
        sorted { left, right in
            left.value == right.value
                ? tieBreak(left.key, right.key)
                : left.value > right.value
        }
    }
}

private extension String {
    /// "RIGHT SINGLE QUOTATION MARK" reads as shouting in a menu.
    var sentenceCased: String {
        let lowered = lowercased()
        guard let first = lowered.first else { return lowered }
        return first.uppercased() + lowered.dropFirst()
    }
}
