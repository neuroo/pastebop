//
//  RuleCloud+KeyValue.swift
//  PasteBop
//

import Foundation
import PasteBopCore
#if PASTEBOP_ICLOUD
import Security
#endif

extension RuleStore: RuleStoring {}

#if PASTEBOP_ICLOUD

/// The flag compiles the code in; the entitlement is what makes the store
/// usable, and only a build signed against this team's profile has one. A
/// source build has the first and not the second, so it runs with sync off
/// rather than reaching for a store that is not there.
@MainActor
private func hasKeyValueEntitlement() -> Bool {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    let key = "com.apple.developer.ubiquity-kvstore-identifier" as CFString
    return SecTaskCopyValueForEntitlement(task, key, nil) != nil
}

/// One key per changed character, because that is what makes iCloud keep
/// both when two Macs change different ones. The value is the same line the
/// file would hold, so what comes back is read by the same parser.
@MainActor
final class KeyValueCloud: RuleCloud {

    private static let prefix = "rule."

    private let store = NSUbiquitousKeyValueStore.default

    var remote: RemoteRules {
        var overrides = RuleOverrides()
        var unreadable: Set<String> = []
        for (key, value) in held() {
            guard let entry = (value as? String).flatMap(RuleFile.decodeEntry) else {
                // The key still names the character, so an entry written by a
                // version that spells it differently is known to be *there*
                // even though nothing here can say what it holds.
                unreadable.insert(String(key.dropFirst(Self.prefix.count)))
                continue
            }
            overrides[entry.pattern] = entry.change
        }
        return RemoteRules(overrides, unreadable: unreadable)
    }

    func publish(_ overrides: RuleOverrides) {
        // An entry this build cannot read is left exactly as it is. Removing
        // it because the merge could not see it would destroy for every Mac
        // what only this one failed to read, and rewriting it in the spelling
        // this build knows would throw away whatever it actually said.
        let held = held()
        let untouchable = Set(held.compactMap { key, value in
            (value as? String).flatMap(RuleFile.decodeEntry) == nil ? key : nil
        })

        var wanted: [String: String] = [:]
        for entry in overrides.sorted {
            let key = Self.prefix + entry.pattern.key
            guard !untouchable.contains(key) else { continue }
            wanted[key] = RuleFile.line(for: entry.pattern, entry.change)
        }

        for key in held.keys where wanted[key] == nil && !untouchable.contains(key) {
            store.removeObject(forKey: key)
        }
        for (key, value) in wanted where store.string(forKey: key) != value {
            store.set(value, forKey: key)
        }
        store.synchronize()
    }

    /// Only this app's entries: the store is shared with anything else the
    /// container holds.
    private func held() -> [String: Any] {
        store.dictionaryRepresentation.filter { $0.key.hasPrefix(Self.prefix) }
    }

    /// The token is not kept: this lives as long as the app does, so there
    /// is no point at which the observer would be removed.
    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }
        store.synchronize()
    }
}

#endif

extension RuleCloudMirror {
    /// Nil unless the build was both compiled and signed for iCloud. There is
    /// deliberately no do-nothing stand-in: a mirror needs a cloud that gives
    /// back what it was given, and one that does not would read as the other
    /// side having deleted everything.
    static func standard(store: RuleStore) -> RuleCloudMirror? {
        #if PASTEBOP_ICLOUD
        guard hasKeyValueEntitlement() else { return nil }
        return RuleCloudMirror(store: store, cloud: KeyValueCloud())
        #else
        return nil
        #endif
    }
}
