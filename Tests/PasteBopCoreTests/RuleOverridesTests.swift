//
//  RuleOverridesTests.swift
//  PasteBopCoreTests
//

import Testing
@testable import PasteBopCore

@Suite("Rule overrides")
struct RuleOverridesTests {

    private let emDash = Pattern.scalars(0x2014...0x2014)
    private let ellipsis = Pattern.scalars(0x2026...0x2026)
    /// No built-in rule covers it, so it can only arrive as an override.
    private let copyright = Pattern.scalars(0x00A9...0x00A9)

    @Test("Changing nothing is exactly the built-in table")
    func emptyOverridesAreTheDefaults() {
        let rules = RewriteRules(overrides: .none)
        #expect(rules.replacements == RewriteRules.builtIn.replacements)
    }

    @Test("Switching a character off drops its rule and nothing else")
    func offRemovesOneRule() {
        let rules = RewriteRules(overrides: RuleOverrides([emDash: .off]))
        #expect(rules.rule(for: 0x2014) == nil)
        #expect(rules.replacements.count == RewriteRules.builtIn.replacements.count - 1)
        // The family it belonged to is still there, minus the one character.
        #expect(rules.families.contains(.dashes))
    }

    @Test("A new version's characters reach a Mac that already has changes")
    func defaultsNotMentionedStillApply() {
        // The whole point of storing changes rather than the table: a
        // character nobody has an opinion about comes from the binary, so
        // adding one later does not need anybody's file to be touched.
        let laterVersion = RewriteRules.builtIn.replacements + [
            Replacement(pattern: copyright, output: "(c)", name: "COPYRIGHT SIGN", category: .symbols)
        ]
        let rules = RewriteRules(overrides: RuleOverrides([emDash: .off]), defaults: laterVersion)
        #expect(rules.rule(for: 0x2014) == nil)
        #expect(rules.rule(for: 0x00A9)?.output == "(c)")
    }

    @Test("Changing what a character becomes keeps what it is called")
    func outputOverrideKeepsNameAndFamily() throws {
        let rules = RewriteRules(overrides: RuleOverrides([emDash: .output("---")]))
        let rule = try #require(rules.rule(for: 0x2014))
        #expect(rule.output == "---")
        #expect(rule.name == "EM DASH")
        #expect(rule.category == .dashes)
    }

    @Test("A character with no built-in rule is added as a custom one")
    func unknownPatternIsAdded() throws {
        let rules = RewriteRules(overrides: RuleOverrides([copyright: .output("(c)")]))
        let rule = try #require(rules.rule(for: 0x00A9))
        #expect(rule.category == .custom)
        #expect(rule.name == "U+00A9")
        #expect(TextNormalizer.normalize("\u{a9} 2026", rules: rules) == "(c) 2026")
    }

    @Test("Switching off a character that has no rule changes nothing")
    func offForAnUnknownPatternIsANoOp() {
        let rules = RewriteRules(overrides: RuleOverrides([copyright: .off]))
        #expect(rules.replacements == RewriteRules.builtIn.replacements)
    }

    @Test("Two changes to different characters both survive")
    func changesAreIndependent() {
        // This is what a whole-table copy could not do: each entry stands on
        // its own, so two Macs can each switch something off and both win.
        var overrides = RuleOverrides([emDash: .off])
        overrides[ellipsis] = .off
        let rules = RewriteRules(overrides: overrides)
        #expect(rules.rule(for: 0x2014) == nil)
        #expect(rules.rule(for: 0x2026) == nil)
        #expect(rules.replacements.count == RewriteRules.builtIn.replacements.count - 2)
    }

    @Test("Added characters come out in a stable order")
    func addedRulesAreOrderedDeterministically() {
        let overrides = RuleOverrides([
            Pattern.scalars(0x00AE...0x00AE): .output("(r)"),
            copyright: .output("(c)"),
        ])
        let added = RewriteRules(overrides: overrides).replacements.filter { $0.category == .custom }
        #expect(added.map(\.pattern.firstScalar) == [0x00A9, 0x00AE])
    }
}
