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
        remote: RuleOverrides = .none,
        unreadable: Set<String> = []
    ) -> RuleSync.Outcome {
        RuleSync.merge(
            base: base,
            local: local,
            remote: RemoteRules(remote, unreadable: unreadable)
        )
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

    @Test("An entry the other side holds but this build cannot read stays put")
    func unreadableRemoteEntriesAreNotDeletions() {
        // It is absent from what came back, which is exactly what a deletion
        // looks like. Read as one it is removed here and then removed from
        // the store, so a single line this build could not parse destroys
        // the entry for every Mac.
        let had = RuleOverrides([emDash: .off])
        let outcome = merge(base: had, local: had, remote: .none, unreadable: [emDash.key])
        #expect(outcome.merged == had)
        #expect(!outcome.writeLocal)
        #expect(!outcome.publish)
    }

    @Test("An unreadable entry is no reason to publish")
    func unreadableEntriesDoNotProvokeAPublish() {
        // It can never be in what came back, so comparing against it would
        // differ on every pass and republish forever — overwriting the entry
        // that was supposed to be left alone.
        let had = RuleOverrides([emDash: .off, ellipsis: .off])
        let outcome = merge(
            base: had,
            local: had,
            remote: RuleOverrides([emDash: .off]),
            unreadable: [ellipsis.key]
        )
        #expect(outcome.merged == had)
        #expect(!outcome.publish)
    }

    @Test("Leaving one entry alone does not freeze the others")
    func changesBesideAnUnreadableEntryStillTravel() {
        let outcome = merge(
            local: RuleOverrides([emDash: .off]),
            remote: .none,
            unreadable: [ellipsis.key]
        )
        #expect(outcome.merged == RuleOverrides([emDash: .off]))
        #expect(outcome.publish)
    }

    @Test("A character changed here still wins over an unreadable one there")
    func aLocalChangeBeatsAnUnreadableEntry() {
        // The merge cannot reconcile with something it cannot read, so the
        // Mac someone is sitting at keeps its answer. Publishing it is the
        // cloud's business: it leaves the entry alone until a build that
        // understands it reconciles.
        let outcome = merge(
            base: RuleOverrides([emDash: .off]),
            local: RuleOverrides([emDash: .output("---")]),
            remote: .none,
            unreadable: [emDash.key]
        )
        #expect(outcome.merged[emDash] == .output("---"))
        #expect(!outcome.writeLocal)
    }
}
