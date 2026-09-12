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
    public enum Change: Equatable, Sendable {
        /// Leave it alone; a default rule for it does not apply.
        case off
        /// Rewrite it to this instead. Adds a rule where there was no
        /// default, replaces the output where there was.
        case output(String)
    }

    public private(set) var changes: [Pattern: Change]

    public init(_ changes: [Pattern: Change] = [:]) {
        self.changes = changes
    }

    public static let none = Self()

    public var isEmpty: Bool { changes.isEmpty }
    public var count: Int { changes.count }

    public subscript(pattern: Pattern) -> Change? {
        get { changes[pattern] }
        set { changes[pattern] = newValue }
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
            switch overrides[rule.pattern] {
            case nil:
                result.append(rule)
            case .off:
                continue
            case .output(let output):
                result.append(Replacement(
                    pattern: rule.pattern,
                    output: output,
                    name: rule.name,
                    category: rule.category
                ))
            }
        }

        // Sorted, because a dictionary is not, and both the file and the
        // window read this order.
        for entry in overrides.sorted where !defaultPatterns.contains(entry.pattern) {
            guard case .output(let output) = entry.change else { continue }
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
