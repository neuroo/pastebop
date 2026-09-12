//
//  RuleCloudMirrorTests.swift
//  PasteBopCoreTests
//

import Foundation
import Testing
@testable import PasteBopCore

@MainActor
@Suite("Rule cloud mirror")
struct RuleCloudMirrorTests {

    private let emDash = Pattern.scalars(0x2014...0x2014)
    private let ellipsis = Pattern.scalars(0x2026...0x2026)

    /// Stands in for iCloud. `arrive` is another Mac writing to it.
    private final class FakeCloud: RuleCloud {
        var remote = RemoteRules()
        private(set) var publishCount = 0
        private var onChange: (@MainActor @Sendable () -> Void)?

        /// As the real store does: an entry nothing here can read is left
        /// exactly as it is, neither removed nor rewritten.
        func publish(_ overrides: RuleOverrides) {
            remote = RemoteRules(
                overrides.ignoring(remote.unreadable),
                unreadable: remote.unreadable
            )
            publishCount += 1
        }

        func start(onChange: @escaping @MainActor @Sendable () -> Void) {
            self.onChange = onChange
        }

        func arrive(_ overrides: RuleOverrides) {
            remote = RemoteRules(overrides, unreadable: remote.unreadable)
            onChange?()
        }
    }

    /// Stands in for `RuleStore`, including the part that matters: saving
    /// reloads the file, which tells the mirror the changes moved.
    private final class FakeStore: RuleStoring {
        var overrides: RuleOverrides
        var onOverridesChanged: ((RuleOverrides) -> Void)?
        private(set) var saveCount = 0

        init(_ overrides: RuleOverrides = .none) {
            self.overrides = overrides
        }

        /// Set to fail a write, the way a read-only directory would.
        var savesFail = false

        @discardableResult
        func save(_ overrides: RuleOverrides) -> Bool {
            guard !savesFail else { return false }
            self.overrides = overrides
            saveCount += 1
            onOverridesChanged?(overrides)
            return true
        }
    }

    /// A suite of its own per test, so the recorded base from one does not
    /// leak into the next.
    private func scratchDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "pastebop.tests." + UUID().uuidString))
    }

    @Test("A change made here reaches iCloud, and settles")
    func publishesLocalChanges() throws {
        let store = FakeStore(RuleOverrides([emDash: .off]))
        let cloud = FakeCloud()
        RuleCloudMirror(store: store, cloud: cloud, defaults: try scratchDefaults()).start()

        #expect(cloud.remote.overrides == RuleOverrides([emDash: .off]))
        // Saving tells the mirror the file moved, which reconciles again.
        // That has to stop rather than write back and forth forever.
        #expect(store.saveCount == 0)
        #expect(cloud.publishCount == 1)
    }

    @Test("A change arriving from another Mac is written to the file")
    func writesRemoteChanges() throws {
        let store = FakeStore()
        let cloud = FakeCloud()
        let mirror = RuleCloudMirror(store: store, cloud: cloud, defaults: try scratchDefaults())
        mirror.start()

        cloud.arrive(RuleOverrides([ellipsis: .off]))
        #expect(store.overrides == RuleOverrides([ellipsis: .off]))
        #expect(store.saveCount == 1)
    }

    @Test("A Mac with no file yet does not wipe what iCloud holds")
    func freshMacAdopts() throws {
        // End to end, not just the merge: a newly signed-in Mac has an empty
        // local set and no base, which must not read as "delete everything".
        let theirs = RuleOverrides([emDash: .off, ellipsis: .output("...")])
        let store = FakeStore()
        let cloud = FakeCloud()
        cloud.remote = RemoteRules(theirs)

        RuleCloudMirror(store: store, cloud: cloud, defaults: try scratchDefaults()).start()

        #expect(store.overrides == theirs)
        #expect(cloud.remote.overrides == theirs)
        #expect(cloud.publishCount == 0)
    }

    @Test("Switching a character back on removes it from iCloud too")
    func deletionPropagates() throws {
        let defaults = try scratchDefaults()
        let had = RuleOverrides([emDash: .off])
        let store = FakeStore(had)
        let cloud = FakeCloud()
        cloud.remote = RemoteRules(had)

        // First run agrees with iCloud, which is what records the base.
        RuleCloudMirror(store: store, cloud: cloud, defaults: defaults).start()
        #expect(cloud.publishCount == 0)

        // Now the character is switched back on here.
        store.overrides = .none
        RuleCloudMirror(store: store, cloud: cloud, defaults: defaults).start()
        #expect(cloud.remote.overrides.isEmpty)
        #expect(store.overrides.isEmpty)
    }

    @Test("Without the recorded base, that same deletion would be undone")
    func withoutABaseTheDeletionIsLost() throws {
        // The mirror image of the test above, spelling out what the base is
        // for: a fresh record cannot tell a deletion from a Mac that has
        // never seen the entry, so iCloud wins and puts it back.
        let had = RuleOverrides([emDash: .off])
        let store = FakeStore()
        let cloud = FakeCloud()
        cloud.remote = RemoteRules(had)

        RuleCloudMirror(store: store, cloud: cloud, defaults: try scratchDefaults()).start()
        #expect(store.overrides == had)
    }

    @Test("Two Macs changing different characters end up with both")
    func independentChangesConverge() throws {
        let store = FakeStore(RuleOverrides([emDash: .off]))
        let cloud = FakeCloud()
        let mirror = RuleCloudMirror(store: store, cloud: cloud, defaults: try scratchDefaults())
        mirror.start()

        cloud.arrive(RuleOverrides([emDash: .off, ellipsis: .off]))

        let both = RuleOverrides([emDash: .off, ellipsis: .off])
        #expect(store.overrides == both)
        #expect(cloud.remote.overrides == both)
    }

    @Test("Too many changes to travel still apply here, and say so")
    func oversizedSetsStayLocal() throws {
        var many = RuleOverrides()
        for scalar in 0x3000..<(0x3000 + RuleSync.maxSyncedEntries + 1) {
            many[.scalars(UInt32(scalar)...UInt32(scalar))] = .off
        }
        let store = FakeStore(many)
        let cloud = FakeCloud()
        let mirror = RuleCloudMirror(store: store, cloud: cloud, defaults: try scratchDefaults())
        mirror.start()

        #expect(cloud.publishCount == 0)
        #expect(store.overrides == many)
        #expect(try #require(mirror.failure).contains("\(RuleSync.maxSyncedEntries)"))
    }

    @Test("A second local change does not delete the first")
    func successiveLocalChangesAccumulate() throws {
        // What a cloud that accepted publishes and reported nothing back
        // caused: after the first change is recorded as the base, the second
        // reconcile reads the empty remote as "the other side deleted that"
        // and propagates it. The file lost the earlier change.
        let store = FakeStore()
        let cloud = FakeCloud()
        let mirror = RuleCloudMirror(store: store, cloud: cloud, defaults: try scratchDefaults())
        mirror.start()

        store.overrides = RuleOverrides([emDash: .off])
        cloud.arrive(cloud.remote.overrides)
        #expect(store.overrides[emDash] == .off)

        store.overrides = RuleOverrides([emDash: .off, ellipsis: .off])
        cloud.arrive(cloud.remote.overrides)
        #expect(store.overrides[emDash] == .off)
        #expect(store.overrides[ellipsis] == .off)
        #expect(cloud.remote.overrides == RuleOverrides([emDash: .off, ellipsis: .off]))
    }

    @Test("A set too large to travel is not recorded as synced")
    func oversizedSetsDoNotAdvanceTheBase() throws {
        // Recording them as agreed-with-iCloud when nothing was published
        // makes the next reconcile read all of them as remote deletions.
        var many = RuleOverrides()
        for scalar in 0x3000..<(0x3000 + RuleSync.maxSyncedEntries + 1) {
            many[.scalars(UInt32(scalar)...UInt32(scalar))] = .off
        }
        let store = FakeStore(many)
        let cloud = FakeCloud()
        let defaults = try scratchDefaults()

        RuleCloudMirror(store: store, cloud: cloud, defaults: defaults).start()
        #expect(store.overrides.count == many.count)

        RuleCloudMirror(store: store, cloud: cloud, defaults: defaults).start()
        #expect(store.overrides.count == many.count)
    }

    @Test("A save that fails does not record the changes as synced")
    func failedSaveDoesNotAdvanceTheBase() throws {
        // Recording them anyway makes the next reconcile read the rules still
        // in iCloud as deletions and remove them from every Mac.
        let defaults = try scratchDefaults()
        let theirs = RuleOverrides([emDash: .off])
        let store = FakeStore()
        store.savesFail = true
        let cloud = FakeCloud()
        cloud.remote = RemoteRules(theirs)

        RuleCloudMirror(store: store, cloud: cloud, defaults: defaults).start()
        #expect(store.overrides.isEmpty)

        // The disk recovers; iCloud must still hold the rule.
        store.savesFail = false
        RuleCloudMirror(store: store, cloud: cloud, defaults: defaults).start()
        #expect(cloud.remote.overrides == theirs)
        #expect(store.overrides == theirs)
    }

    @Test("An entry iCloud holds but this build cannot read is not a deletion")
    func unreadableRemoteEntriesAreNotDeletions() throws {
        // A newer version writes an entry in a spelling this one does not
        // understand. It is missing from what the merge can see, and read as
        // a deletion it would be removed from the file here *and* from the
        // store — destroying for every Mac what only this build failed to
        // read.
        let defaults = try scratchDefaults()
        let had = RuleOverrides([emDash: .off, ellipsis: .off])
        let store = FakeStore(had)
        let cloud = FakeCloud()
        cloud.remote = RemoteRules(had)

        RuleCloudMirror(store: store, cloud: cloud, defaults: defaults).start()
        #expect(cloud.publishCount == 0)

        // Now this build stops being able to read the ellipsis entry.
        cloud.remote = RemoteRules(
            RuleOverrides([emDash: .off]),
            unreadable: [ellipsis.key]
        )
        RuleCloudMirror(store: store, cloud: cloud, defaults: defaults).start()

        #expect(store.overrides == had)
        #expect(cloud.publishCount == 0)
    }

    @Test("An unreadable entry does not start a publish that never settles")
    func unreadableEntriesDoNotLoop() throws {
        // It is absent from what the merge compares against, so a merge that
        // keeps it would differ from the store on every pass and publish
        // forever, rewriting the entry it was supposed to leave alone.
        let defaults = try scratchDefaults()
        let store = FakeStore(RuleOverrides([emDash: .off]))
        let cloud = FakeCloud()
        cloud.remote = RemoteRules(RuleOverrides([emDash: .off]))
        RuleCloudMirror(store: store, cloud: cloud, defaults: defaults).start()

        cloud.remote = RemoteRules(.none, unreadable: [emDash.key])
        let mirror = RuleCloudMirror(store: store, cloud: cloud, defaults: defaults)
        mirror.start()
        mirror.start()

        #expect(cloud.publishCount == 0)
        #expect(store.overrides == RuleOverrides([emDash: .off]))
    }

    @Test("A change beside an unreadable entry still travels")
    func changesBesideAnUnreadableEntryStillSync() throws {
        // Leaving one entry alone must not freeze the rest: the whole point
        // of a key per character is that they are independent.
        let defaults = try scratchDefaults()
        let store = FakeStore()
        let cloud = FakeCloud()
        cloud.remote = RemoteRules(.none, unreadable: [ellipsis.key])
        let mirror = RuleCloudMirror(store: store, cloud: cloud, defaults: defaults)
        mirror.start()

        store.overrides = RuleOverrides([emDash: .off])
        cloud.arrive(cloud.remote.overrides)

        #expect(cloud.remote.overrides == RuleOverrides([emDash: .off]))
        #expect(cloud.remote.unreadable == [ellipsis.key])
    }

    @Test("Nothing anywhere is nothing done")
    func quietWhenEverythingAgrees() throws {
        let store = FakeStore()
        let cloud = FakeCloud()
        let mirror = RuleCloudMirror(store: store, cloud: cloud, defaults: try scratchDefaults())
        mirror.start()

        #expect(store.saveCount == 0)
        #expect(cloud.publishCount == 0)
        #expect(mirror.failure == nil)
    }
}
