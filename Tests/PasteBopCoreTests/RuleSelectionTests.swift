//
//  RuleSelectionTests.swift
//  PasteBopCoreTests
//

import Testing
@testable import PasteBopCore

@Suite("Rule selection")
struct RuleSelectionTests {

    private let emDash = Pattern.scalars(0x2014...0x2014)
    private let ellipsis = Pattern.scalars(0x2026...0x2026)

    private func rule(_ scalar: UInt32, in selection: RuleSelection) throws -> Replacement {
        try #require(selection.universe.first { $0.range == scalar...scalar })
    }

    private func table(_ selection: RuleSelection) -> RewriteRules {
        RewriteRules(overrides: selection.changes)
    }

    @Test("With nothing changed, everything is on")
    func startsFromTheDefaults() {
        let selection = RuleSelection(overrides: .none)
        #expect(selection.changes.isEmpty)
        #expect(table(selection).replacements == RewriteRules.builtIn.replacements)
        #expect(selection.enabledScalarCount == RewriteRules.builtIn.scalarCount)
    }

    @Test("A character switched off is still on offer, so it can come back")
    func switchedOffRulesStayInTheUniverse() throws {
        // The set on offer is the built-in table, so nothing can go missing
        // from it — which is what used to make a deleted family unreachable.
        var selection = RuleSelection(overrides: RuleOverrides([emDash: .off]))
        let dash = try rule(0x2014, in: selection)
        #expect(!selection.isOn(dash))
        #expect(table(selection).rule(for: 0x2014) == nil)

        selection.setOn(dash, true)
        #expect(table(selection).rule(for: 0x2014)?.output == "--")
    }

    @Test("Switching off and on again leaves no trace in the file")
    func offThenOnWritesNothing() throws {
        var selection = RuleSelection(overrides: .none)
        let dash = try rule(0x2014, in: selection)

        selection.setOn(dash, false)
        #expect(selection.changes.count == 1)

        selection.setOn(dash, true)
        // Back to the default, so there is nothing left to say about it.
        #expect(selection.changes.isEmpty)
    }

    @Test("Switching a changed replacement off and on keeps the change")
    func offThenOnKeepsACustomReplacement() throws {
        // Deliberately not the built-in "--": restoring from the built-in
        // table would hand that back and lose the edit in silence.
        var selection = RuleSelection(overrides: RuleOverrides([emDash: .output(" -- ")]))
        let dash = try rule(0x2014, in: selection)
        #expect(dash.output == " -- ")

        selection.setOn(dash, false)
        #expect(table(selection).rule(for: 0x2014) == nil)

        selection.setOn(dash, true)
        #expect(table(selection).rule(for: 0x2014)?.output == " -- ")
        #expect(selection.changes[emDash] == .output(" -- "))
    }

    @Test("A changed replacement survives being switched off, saved and reloaded")
    func offThenOnAcrossASaveKeepsTheChange() throws {
        // In-session the set on offer still held it, so this looked fine
        // until the file was written and read back: the entry said only
        // "off", and switching it on again handed back the built-in "--".
        var selection = RuleSelection(overrides: RuleOverrides([emDash: .output(" -- ")]))
        selection.setOn(try rule(0x2014, in: selection), false)

        let reloaded = try RuleFile.decode(RuleFile.encode(selection.changes))
        var after = RuleSelection(overrides: reloaded)
        after.setOn(try rule(0x2014, in: after), true)
        #expect(table(after).rule(for: 0x2014)?.output == " -- ")
    }

    @Test("A character with no built-in rule can be switched off and back on")
    func customOnlyRuleSurvivesBeingSwitchedOff() throws {
        // It used to vanish from the set on offer entirely, leaving nothing
        // to switch back on and no way to recover it from the window.
        let copyright = Pattern.scalars(0x00A9...0x00A9)
        var selection = RuleSelection(overrides: RuleOverrides([copyright: .output("(c)")]))
        selection.setOn(try rule(0x00A9, in: selection), false)

        let reloaded = try RuleFile.decode(RuleFile.encode(selection.changes))
        var after = RuleSelection(overrides: reloaded)
        #expect(after.universe.contains { $0.range == 0x00A9...0x00A9 })
        after.setOn(try rule(0x00A9, in: after), true)
        #expect(table(after).rule(for: 0x00A9)?.output == "(c)")
    }

    @Test("A half-on family reads as on, and says how many")
    func reportsAPartlySwitchedOffFamily() throws {
        var selection = RuleSelection(overrides: .none)
        let total = selection.rules(in: .dashes).count
        let dash = try rule(0x2014, in: selection)

        selection.setOn(dash, false)
        #expect(selection.isOn(.dashes))
        #expect(selection.enabledCount(in: .dashes) == total - 1)

        selection.setOn(.dashes, false)
        #expect(!selection.isOn(.dashes))
        #expect(selection.enabledCount(in: .dashes) == 0)
    }

    @Test("Switching a family off leaves every other family alone")
    func switchingAFamilyOffTouchesNothingElse() {
        var selection = RuleSelection(overrides: .none)
        selection.setOn(.quotes, false)

        let rules = table(selection)
        #expect(!rules.families.contains(.quotes))
        for category in RewriteRules.builtIn.families where category != .quotes {
            #expect(rules.rules(in: category) == RewriteRules.builtIn.rules(in: category))
        }
    }

    @Test("Switching everything off leaves nothing to rewrite")
    func switchingEverythingOff() {
        var selection = RuleSelection(overrides: .none)
        for category in selection.categories {
            selection.setOn(category, false)
        }
        #expect(table(selection).replacements.isEmpty)
        #expect(selection.enabledScalarCount == 0)
    }

    @Test("Two characters switched off are two independent entries")
    func changesAreIndependent() throws {
        // This is what a whole-table copy could not do: each entry stands on
        // its own, so two Macs can each switch something off and both win.
        var selection = RuleSelection(overrides: .none)
        selection.setOn(try rule(0x2014, in: selection), false)
        selection.setOn(try rule(0x2026, in: selection), false)
        #expect(selection.changes[emDash] == .off)
        #expect(selection.changes[ellipsis] == .off)
        #expect(selection.changes.count == 2)
    }

    @Test("What the window writes is what the file gives back")
    func whatIsWrittenParsesBack() throws {
        var selection = RuleSelection(overrides: .none)
        selection.setOn(.invisibles, false)
        selection.setOn(try rule(0x2014, in: selection), false)

        let written = selection.changes
        let parsed = try RuleFile.decode(RuleFile.encode(written))
        #expect(parsed == written)
        #expect(RewriteRules(overrides: parsed).rule(for: 0x2014) == nil)
    }
}
