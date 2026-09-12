//
//  RuleSync.swift
//  PasteBopCore
//

/// What the other side holds, and how much of it this build could read.
///
/// An entry written by a newer version can be there and still not parse
/// here. It is absent from `overrides`, and that absence is not a deletion:
/// read as one it would be propagated to the file and then removed from the
/// store, destroying for every Mac an entry only this one could not read.
public struct RemoteRules: Equatable, Sendable {

    public var overrides: RuleOverrides

    /// `Pattern.key` for each entry that is there and could not be read.
    /// They are left exactly as they are until a build that understands them
    /// reconciles, so nothing here can overwrite or remove one.
    public var unreadable: Set<String>

    public init(_ overrides: RuleOverrides = .none, unreadable: Set<String> = []) {
        self.overrides = overrides
        self.unreadable = unreadable
    }
}

/// Merging one Mac's changes with the same user's changes elsewhere.
///
/// Each entry travels on its own — one key in the key-value store per
/// character — so iCloud keeps both when two Macs change different
/// characters. What it cannot know is whether an entry missing here was
/// *removed* here or simply never seen, which is what the base is for: the
/// changes as they stood when this Mac last agreed with iCloud.
public enum RuleSync {

    /// The key-value store holds 1024 keys. `RuleFile` allows far more
    /// entries than that, so a pathological set stays local and says so
    /// rather than syncing half of itself.
    public static let maxSyncedEntries = 512

    public struct Outcome: Equatable, Sendable {
        public let merged: RuleOverrides
        /// The file on this Mac disagrees with the merge.
        public let writeLocal: Bool
        /// iCloud disagrees with the merge.
        public let publish: Bool
        /// Too many entries to travel; `merged` still applies here.
        public let tooLarge: Bool
    }

    /// Three-way merge. A character only one side touched takes that side's
    /// answer; one both sides touched takes this Mac's, so the machine
    /// someone is sitting at is never overruled by a slower one.
    public static func merge(
        base: RuleOverrides,
        local: RuleOverrides,
        remote: RemoteRules
    ) -> Outcome {
        var merged = RuleOverrides()
        var patterns = Set(base.changes.keys)
        patterns.formUnion(local.changes.keys)
        patterns.formUnion(remote.overrides.changes.keys)

        for pattern in patterns {
            let was = base[pattern]
            let here = local[pattern]
            let there = remote.overrides[pattern]

            let changedHere = here != was
            // An entry this build cannot read is absent from `overrides` and
            // has not changed; it is simply out of reach. Anything else reads
            // it as deleted on the other side.
            let changedThere = !remote.unreadable.contains(pattern.key) && there != was

            // Nil is a value here: an entry deleted on one side is a change
            // like any other, which is how switching a character back on
            // travels rather than being re-added by the other Mac.
            let winner: RuleOverrides.Change?
            switch (changedHere, changedThere) {
            case (false, false): winner = was
            case (true, false): winner = here
            case (false, true): winner = there
            case (true, true): winner = here
            }
            merged[pattern] = winner
        }

        let tooLarge = merged.count > maxSyncedEntries
        return Outcome(
            merged: merged,
            writeLocal: merged != local,
            publish: !tooLarge && merged.ignoring(remote.unreadable) != remote.overrides,
            tooLarge: tooLarge
        )
    }
}
