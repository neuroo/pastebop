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
        var remote: RuleOverrides = .none
        private(set) var publishCount = 0
        private var onChange: (@MainActor @Sendable () -> Void)?

        func publish(_ overrides: RuleOverrides) {
            remote = overrides
            publishCount += 1
        }

        func start(onChange: @escaping @MainActor @Sendable () -> Void) {
            self.onChange = onChange
        }

        func arrive(_ overrides: RuleOverrides) {
            remote = overrides
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

        func save(_ overrides: RuleOverrides) {
            self.overrides = overrides
            saveCount += 1
            onOverridesChanged?(overrides)
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

        #expect(cloud.remote == RuleOverrides([emDash: .off]))
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
        cloud.remote = theirs

        RuleCloudMirror(store: store, cloud: cloud, defaults: try scratchDefaults()).start()

        #expect(store.overrides == theirs)
        #expect(cloud.remote == theirs)
        #expect(cloud.publishCount == 0)
    }

    @Test("Switching a character back on removes it from iCloud too")
    func deletionPropagates() throws {
        let defaults = try scratchDefaults()
        let had = RuleOverrides([emDash: .off])
        let store = FakeStore(had)
        let cloud = FakeCloud()
        cloud.remote = had

        // First run agrees with iCloud, which is what records the base.
        RuleCloudMirror(store: store, cloud: cloud, defaults: defaults).start()
        #expect(cloud.publishCount == 0)

        // Now the character is switched back on here.
        store.overrides = .none
        RuleCloudMirror(store: store, cloud: cloud, defaults: defaults).start()
        #expect(cloud.remote.isEmpty)
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
        cloud.remote = had

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
        #expect(cloud.remote == both)
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
