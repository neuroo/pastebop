//
//  RuleSelection.swift
//  PasteBopCore
//

/// Which characters are switched on, and the full set on offer.
///
/// The set on offer is the built-in table plus anything added by hand, so it
/// is always complete: a character switched off is still listed, which is how
/// it gets switched back on.
public struct RuleSelection: Sendable {

    /// Every rule the window can show: the built-in table with any changed
    /// replacements applied, plus characters that have no built-in rule.
    public let universe: [Replacement]

    private var overrides: RuleOverrides

    public init(overrides: RuleOverrides, defaults: [Replacement] = Replacements.all) {
        self.overrides = overrides

        var universe: [Replacement] = []
        universe.reserveCapacity(defaults.count + overrides.count)
        var known: Set<Pattern> = []
        known.reserveCapacity(defaults.count)

        for rule in defaults {
            known.insert(rule.pattern)
            if case .output(let output) = overrides[rule.pattern] {
                universe.append(Replacement(
                    pattern: rule.pattern,
                    output: output,
                    name: rule.name,
                    category: rule.category
                ))
            } else {
                universe.append(rule)
            }
        }

        for entry in overrides.sorted where !known.contains(entry.pattern) {
            guard case .output(let output) = entry.change else { continue }
            universe.append(Replacement(
                pattern: entry.pattern,
                output: output,
                name: Replacements.builtIn(entry.pattern)?.name ?? entry.pattern.displayName,
                category: .custom
            ))
        }

        self.universe = universe
    }

    /// The changes to write.
    public var changes: RuleOverrides { overrides }

    // MARK: - Reading

    public var categories: [Replacement.Category] {
        Replacement.Category.allCases.filter { category in
            universe.contains { $0.category == category }
        }
    }

    public func rules(in category: Replacement.Category) -> [Replacement] {
        universe.filter { $0.category == category }
    }

    public func isOn(_ rule: Replacement) -> Bool {
        overrides[rule.pattern] != .off
    }

    /// On when the family is doing anything at all. A switch cannot show the
    /// half-on case, so the count beside it carries that.
    public func isOn(_ category: Replacement.Category) -> Bool {
        rules(in: category).contains { isOn($0) }
    }

    public func enabledCount(in category: Replacement.Category) -> Int {
        rules(in: category).filter { isOn($0) }.count
    }

    /// Ranges expanded, to match how the rest of the app counts characters.
    public var enabledScalarCount: Int {
        universe.reduce(0) { total, rule in
            isOn(rule) ? total + rule.scalarCount : total
        }
    }

    // MARK: - Writing

    public mutating func setOn(_ rule: Replacement, _ isOn: Bool) {
        guard isOn else {
            overrides[rule.pattern] = .off
            return
        }
        // A character whose replacement was changed keeps it: the set on
        // offer still holds it, so off-and-on again is not a way to quietly
        // lose an edit. One matching its default needs no entry at all.
        if let builtIn = Replacements.builtIn(rule.pattern), builtIn.output == rule.output {
            overrides[rule.pattern] = nil
        } else {
            overrides[rule.pattern] = .output(rule.output)
        }
    }

    public mutating func setOn(_ category: Replacement.Category, _ isOn: Bool) {
        for rule in rules(in: category) {
            setOn(rule, isOn)
        }
    }
}
