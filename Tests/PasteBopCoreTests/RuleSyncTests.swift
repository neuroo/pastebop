//
//  RuleSyncTests.swift
//  PasteBopCoreTests
//

import Testing
@testable import PasteBopCore

@Suite("Rule sync")
struct RuleSyncTests {

    private let emDash = Pattern.scalars(0x2014...0x2014)
    private let ellipsis = Pattern.scalars(0x2026...0x2026)

    private func merge(
        base: RuleOverrides = .none,
        local: RuleOverrides = .none,
        remote: RuleOverrides = .none
    ) -> RuleSync.Outcome {
        RuleSync.merge(base: base, local: local, remote: remote)
    }

    @Test("Everyone already agrees")
    func nothingToDo() {
        let same = RuleOverrides([emDash: .off])
        let outcome = merge(base: same, local: same, remote: same)
        #expect(outcome.merged == same)
        #expect(!outcome.writeLocal)
        #expect(!outcome.publish)
    }

    @Test("A change made here is published, not written back")
    func localChangeIsPublished() {
        let outcome = merge(local: RuleOverrides([emDash: .off]))
        #expect(outcome.merged == RuleOverrides([emDash: .off]))
        #expect(outcome.publish)
        #expect(!outcome.writeLocal)
    }

    @Test("A change made elsewhere is written to the file here")
    func remoteChangeIsWritten() {
        let outcome = merge(remote: RuleOverrides([emDash: .off]))
        #expect(outcome.merged == RuleOverrides([emDash: .off]))
        #expect(outcome.writeLocal)
        #expect(!outcome.publish)
    }

    @Test("A Mac with no file yet does not wipe what iCloud holds")
    func aFreshMacAdoptsRatherThanDeletes() {
        // The failure this prevents is total: with no base to compare
        // against, an empty local set looks exactly like "everything was
        // deleted here", and a newly signed-in Mac would erase the lot.
        let theirs = RuleOverrides([emDash: .off, ellipsis: .output("...")])
        let outcome = merge(base: .none, local: .none, remote: theirs)
        #expect(outcome.merged == theirs)
        #expect(outcome.writeLocal)
        #expect(!outcome.publish)
    }

    @Test("Switching a character back on travels as a deletion")
    func removingAnEntryPropagates() {
        // Both sides had it; this Mac removed it. Without treating a missing
        // entry as a change, the other Mac would simply put it back.
        let had = RuleOverrides([emDash: .off])
        let outcome = merge(base: had, local: .none, remote: had)
        #expect(outcome.merged.isEmpty)
        #expect(outcome.publish)
        #expect(!outcome.writeLocal)
    }

    @Test("Two Macs changing different characters both win")
    func independentChangesBothSurvive() {
        let outcome = merge(
            base: .none,
            local: RuleOverrides([emDash: .off]),
            remote: RuleOverrides([ellipsis: .off])
        )
        #expect(outcome.merged == RuleOverrides([emDash: .off, ellipsis: .off]))
        #expect(outcome.writeLocal)
        #expect(outcome.publish)
    }

    @Test("The Mac in front of you wins the same character")
    func localWinsAConflict() {
        let outcome = merge(
            base: .none,
            local: RuleOverrides([emDash: .output("---")]),
            remote: RuleOverrides([emDash: .off])
        )
        #expect(outcome.merged[emDash] == .output("---"))
        #expect(outcome.publish)
    }

    @Test("An entry neither side touched is left exactly as it was")
    func untouchedEntriesSurvive() {
        let base = RuleOverrides([emDash: .off, ellipsis: .output("...")])
        var local = base
        local[emDash] = .output("--")
        let outcome = merge(base: base, local: local, remote: base)
        #expect(outcome.merged[ellipsis] == .output("..."))
        #expect(outcome.merged[emDash] == .output("--"))
    }

    @Test("Too many changes to travel still apply here")
    func oversizedSetsStayLocal() {
        var many = RuleOverrides()
        for scalar in 0x3000..<(0x3000 + RuleSync.maxSyncedEntries + 1) {
            many[.scalars(UInt32(scalar)...UInt32(scalar))] = .off
        }
        let outcome = merge(local: many)
        #expect(outcome.tooLarge)
        #expect(!outcome.publish)
        #expect(outcome.merged.count == many.count)
    }

    @Test("Switching off every character PasteBop knows still fits")
    func everyCharacterOffStillFits() {
        #expect(Replacements.all.count < RuleSync.maxSyncedEntries)
    }
}
