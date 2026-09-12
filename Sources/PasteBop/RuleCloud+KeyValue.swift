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

    var remote: RuleOverrides {
        let lines = store.dictionaryRepresentation.compactMap { key, value -> String? in
            guard key.hasPrefix(Self.prefix) else { return nil }
            return value as? String
        }
        // A line iCloud holds but this build cannot read is skipped rather
        // than allowed to throw away everything alongside it.
        return (try? RuleFile.decode(RuleFile.document(lines))) ?? .none
    }

    func publish(_ overrides: RuleOverrides) {
        var wanted: [String: String] = [:]
        for entry in overrides.sorted {
            wanted[Self.prefix + entry.pattern.key] = RuleFile.line(for: entry.pattern, entry.change)
        }

        for key in store.dictionaryRepresentation.keys
        where key.hasPrefix(Self.prefix) && wanted[key] == nil {
            store.removeObject(forKey: key)
        }
        for (key, value) in wanted where store.string(forKey: key) != value {
            store.set(value, forKey: key)
        }
        store.synchronize()
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
