//
//  RuleOverrides.swift
//  PasteBopCore
//

/// What someone changed about the built-in table, and nothing else.
///
/// The table in force is the defaults with these applied, so a character
/// nobody has an opinion about is described in exactly one place — the
/// built-in table — and a new version can add characters without anyone's
/// file standing in the way.
public struct RuleOverrides: Equatable, Sendable {

    /// What an entry says about one character.
    ///
    /// The two halves are independent on purpose: switching a character off
    /// must not throw away a replacement someone wrote for it, or switching
    /// it back on would silently hand back the built-in one — and a
    /// character with no built-in rule would vanish with nothing left to
    /// switch back on.
    public struct Change: Equatable, Sendable {
        /// The replacement, or nil to use the built-in one.
        public var output: String?
        /// Left alone: no rule fires for this character.
        public var isOff: Bool

        public init(output: String? = nil, isOff: Bool = false) {
            self.output = output
            self.isOff = isOff
        }

        public static let off = Self(isOff: true)

        public static func output(_ text: String) -> Self { Self(output: text) }

        /// On, with no replacement of its own: the built-in rule exactly, so
        /// there is nothing for an entry to record.
        var saysNothing: Bool { !isOff && output == nil }
    }

    public private(set) var changes: [Pattern: Change]

    public init(_ changes: [Pattern: Change] = [:]) {
        self.changes = changes
    }

    public static let none = Self()

    public var isEmpty: Bool { changes.isEmpty }
    public var count: Int { changes.count }

    /// An entry that says nothing is no entry, so the file never carries a
    /// line with no effect and the merge never sees one.
    public subscript(pattern: Pattern) -> Change? {
        get { changes[pattern] }
        set { changes[pattern] = (newValue?.saysNothing ?? false) ? nil : newValue }
    }

    /// Without the entries these keys name. What is out of reach on the
    /// other side cannot be compared against it, so it is left out rather
    /// than counted as a difference that needs publishing.
    func ignoring(_ keys: Set<String>) -> Self {
        guard !keys.isEmpty else { return self }
        return Self(changes.filter { !keys.contains($0.key.key) })
    }

    /// A dictionary has no order, and re-encoding has to be byte-stable.
    public var sorted: [(pattern: Pattern, change: Change)] {
        changes
            .sorted { lhs, rhs in
                let left = lhs.key, right = rhs.key
                if left.firstScalar != right.firstScalar {
                    return left.firstScalar < right.firstScalar
                }
                return left.key < right.key
            }
            .map { (pattern: $0.key, change: $0.value) }
    }
}

extension RewriteRules {

    /// The table in force: the defaults with someone's changes laid over
    /// them. Characters nobody mentioned keep their built-in rule, which is
    /// how a new version's additions reach a Mac that already has a file.
    public init(overrides: RuleOverrides, defaults: [Replacement] = Replacements.all) {
        var result: [Replacement] = []
        result.reserveCapacity(defaults.count + overrides.count)

        var defaultPatterns: Set<Pattern> = []
        defaultPatterns.reserveCapacity(defaults.count)

        for rule in defaults {
            defaultPatterns.insert(rule.pattern)
            guard let change = overrides[rule.pattern] else {
                result.append(rule)
                continue
            }
            guard !change.isOff else { continue }
            result.append(Replacement(
                pattern: rule.pattern,
                output: change.output ?? rule.output,
                name: rule.name,
                category: rule.category
            ))
        }

        // Sorted, because a dictionary is not, and both the file and the
        // window read this order.
        for entry in overrides.sorted where !defaultPatterns.contains(entry.pattern) {
            guard !entry.change.isOff, let output = entry.change.output else { continue }
            result.append(Replacement(
                pattern: entry.pattern,
                output: output,
                name: Replacements.builtIn(entry.pattern)?.name ?? entry.pattern.displayName,
                category: .custom
            ))
        }

        self.init(result)
    }
}
