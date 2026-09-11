//
//  RewriteRules.swift
//  PasteBopCore
//

/// An immutable rule set and the lookup table built from it. Built once,
/// handed to every scan; swapping in a new one is an assignment.
///
/// Everything the app says about the rules is asked of this, never of
/// `Replacements.all`, so a customised table is never described by the default.
public struct RewriteRules: Sendable {

    /// The table shipped with the app.
    public static let builtIn = Self(Replacements.all)

    /// The rules, in the order they were declared.
    public let replacements: [Replacement]

    let table: ScalarTable

    private let byScalar: [UInt32: Replacement]
    private let ranged: [Replacement]
    /// By `Pattern.key`, for turning statistics back into names.
    private let byKey: [String: Replacement]

    public init(_ replacements: [Replacement]) {
        self.replacements = replacements
        self.table = ScalarTable(replacements)

        var byScalar: [UInt32: Replacement] = [:]
        var ranged: [Replacement] = []
        for rule in replacements {
            guard case .scalars(let range) = rule.pattern else { continue }
            if range.lowerBound == range.upperBound {
                byScalar[range.lowerBound] = rule
            } else {
                ranged.append(rule)
            }
        }
        self.byScalar = byScalar
        self.ranged = ranged
        self.byKey = Dictionary(
            replacements.map { ($0.pattern.key, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    // MARK: - Lookup

    /// The scalar or range rule covering `value`. Substring rules are not
    /// considered; a scalar only matches one as part of a longer run.
    public func rule(for value: UInt32) -> Replacement? {
        if let rule = byScalar[value] { return rule }
        return ranged.first { rule in
            guard case .scalars(let range) = rule.pattern else { return false }
            return range.contains(value)
        }
    }

    public func rule(forKey key: String) -> Replacement? {
        byKey[key]
    }

    /// Ranges expanded.
    public var scalarCount: Int {
        replacements.reduce(0) { $0 + $1.scalarCount }
    }

    // MARK: - Describing the table

    /// Families with at least one rule, in declaration order.
    public var families: [Replacement.Category] {
        Replacement.Category.allCases.filter { category in
            replacements.contains { $0.category == category }
        }
    }

    public func rules(in category: Replacement.Category) -> [Replacement] {
        replacements.filter { $0.category == category }
    }

    public func scalarCount(in category: Replacement.Category) -> Int {
        rules(in: category).reduce(0) { $0 + $1.scalarCount }
    }

    /// Representative input characters, or a description for families with
    /// nothing visible to show.
    public func exampleInput(for category: Replacement.Category, limit: Int = 8) -> String {
        switch category {
        case .spaces: "no-break, thin, hair, ideographic"
        case .invisibles: "zero-width, bidi override, tag, BOM"
        default: rules(in: category).lazy
            .compactMap(\.scalar).prefix(limit)
            .map(String.init).joined(separator: " ")
        }
    }

    /// The distinct outputs a family produces.
    public func exampleOutput(for category: Replacement.Category, limit: Int = 6) -> String {
        guard category != .invisibles else { return "removed" }
        var seen: Set<String> = []
        return rules(in: category)
            .compactMap { seen.insert($0.output).inserted ? $0.output : nil }
            .prefix(limit)
            .map { $0 == " " ? "space" : $0 }
            .joined(separator: " ")
    }
}
