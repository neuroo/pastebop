//
//  RuleCloudMirror.swift
//  PasteBopCore
//

import Foundation

/// Somewhere the changes can be mirrored to, one entry at a time.
@MainActor
public protocol RuleCloud {
    var remote: RuleOverrides { get }
    /// Make it match this exactly: entries that are gone are removed.
    func publish(_ overrides: RuleOverrides)
    func start(onChange: @escaping @MainActor @Sendable () -> Void)
}

/// What the mirror needs from wherever the changes are kept.
@MainActor
public protocol RuleStoring: AnyObject {
    var overrides: RuleOverrides { get }
    func save(_ overrides: RuleOverrides)
    var onOverridesChanged: ((RuleOverrides) -> Void)? { get set }
}

/// Keeps the rules file in step with the same user's other Macs.
///
/// Only exists when there is somewhere to mirror to. A stand-in cloud that
/// accepts `publish` and reports nothing back would be read as the other
/// side having deleted everything, and the merge would faithfully propagate
/// that to the file.
///
/// The local file stays the source of truth: a change arriving from iCloud is
/// *written to it*, so it reaches the rules through the same parse and the
/// same error reporting as an edit made by hand.
@MainActor
public final class RuleCloudMirror {

    /// Set when there are too many changes to travel. They still apply here.
    public private(set) var failure: String?

    private let store: any RuleStoring
    private let cloud: any RuleCloud
    private let defaults: UserDefaults

    /// The changes as they stood when this Mac last agreed with iCloud.
    /// Without it an entry missing here cannot be told apart from one this
    /// Mac has never seen, and a fresh Mac would delete everyone's changes.
    private var base: RuleOverrides

    private enum Key {
        static let base = "PasteBopSyncedRules"
    }

    public init(store: any RuleStoring, cloud: any RuleCloud, defaults: UserDefaults = .standard) {
        self.store = store
        self.cloud = cloud
        self.defaults = defaults
        self.base = Self.read(from: defaults)
    }

    public func start() {
        cloud.start { [weak self] in self?.reconcile() }
        store.onOverridesChanged = { [weak self] _ in self?.reconcile() }
        reconcile()
    }

    /// Terminates: writing the merge makes the file equal to it, so the
    /// reconcile that write triggers agrees with everything and stops.
    private func reconcile() {
        let outcome = RuleSync.merge(base: base, local: store.overrides, remote: cloud.remote)

        failure = outcome.tooLarge
            ? "There are too many changed characters for iCloud; the limit is "
                + "\(RuleSync.maxSyncedEntries). They still apply on this Mac."
            : nil

        if outcome.publish { cloud.publish(outcome.merged) }
        if outcome.writeLocal { store.save(outcome.merged) }

        base = outcome.merged
        defaults.set(Self.text(for: outcome.merged), forKey: Key.base)
    }

    private static func text(for overrides: RuleOverrides) -> String {
        RuleFile.document(overrides.sorted.map { RuleFile.line(for: $0.pattern, $0.change) })
    }

    private static func read(from defaults: UserDefaults) -> RuleOverrides {
        guard let text = defaults.string(forKey: Key.base) else { return .none }
        return (try? RuleFile.decode(text)) ?? .none
    }
}
