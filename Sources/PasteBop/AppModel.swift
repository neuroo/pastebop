//
//  AppModel.swift
//  PasteBop
//

import Foundation
import Observation
import PasteBopCore

/// Observable state behind the menu.
@MainActor
@Observable
final class AppModel {

    // MARK: - Settings

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Key.isEnabled)
            syncMonitor()
        }
    }

    var startsAtLogin: Bool {
        didSet {
            guard oldValue != startsAtLogin else { return }
            do {
                try LoginItem.setEnabled(startsAtLogin)
                loginItemFailure = nil
            } catch {
                loginItemFailure = error.localizedDescription
                // Show what the system actually reports, not what was asked.
                startsAtLogin = LoginItem.isEnabled
            }
        }
    }

    private(set) var loginItemFailure: String?

    // MARK: - Statistics

    private(set) var copyCount: Int
    private(set) var tally: RewriteTally
    private(set) var countingSince: Date
    /// How the last copy read, and how much of it was rewritten. Not
    /// persisted: both describe the copy in hand, not a lifetime.
    private(set) var lastProvenance: Provenance?
    private(set) var lastCopyCharacters: Int?
    private(set) var machineWrittenCopies: Int

    var report: ActivityReport {
        ActivityReport(
            isEnabled: isEnabled,
            copyCount: copyCount,
            tally: tally,
            rules: rules,
            lastProvenance: lastProvenance,
            lastCopyCharacters: lastCopyCharacters,
            machineWrittenCopies: machineWrittenCopies
        )
    }

    var familyTotals: [(category: Replacement.Category, count: Int)] {
        tally.familyTotals(rules: rules)
    }

    func resetStatistics() {
        copyCount = 0
        tally = RewriteTally()
        machineWrittenCopies = 0
        lastProvenance = nil
        lastCopyCharacters = nil
        countingSince = .now
        defaults.set(countingSince, forKey: Key.countingSince)
        persistStatistics()
    }

    // MARK: - Wiring

    let ruleStore: RuleStore
    let rulesEditor: RulesEditor
    let cloudMirror: RuleCloudMirror

    var rules: RewriteRules { ruleStore.rules }

    private let defaults: UserDefaults
    private var monitor: ClipboardMonitor?

    private enum Key {
        static let isEnabled = "PasteBopEnabled"
        static let copyCount = "PasteBopCopyCount"
        static let tally = "PasteBopTally"
        static let countingSince = "PasteBopCountingSince"
        static let machineWrittenCopies = "PasteBopMachineWrittenCopies"
    }

    init(defaults: UserDefaults = .standard, ruleStore: RuleStore = RuleStore()) {
        self.defaults = defaults
        self.ruleStore = ruleStore
        self.rulesEditor = RulesEditor(store: ruleStore)
        self.cloudMirror = .standard(store: ruleStore)
        defaults.register(defaults: [Key.isEnabled: true])
        self.isEnabled = defaults.bool(forKey: Key.isEnabled)
        self.copyCount = defaults.integer(forKey: Key.copyCount)
        self.tally = RewriteTally(storage: defaults.dictionary(forKey: Key.tally) ?? [:])
        self.machineWrittenCopies = defaults.integer(forKey: Key.machineWrittenCopies)
        self.startsAtLogin = LoginItem.isEnabled

        if let since = defaults.object(forKey: Key.countingSince) as? Date {
            self.countingSince = since
        } else {
            // Pin it now, or every relaunch claims counting began today.
            self.countingSince = .now
            defaults.set(self.countingSince, forKey: Key.countingSince)
        }
    }

    /// Called once at launch.
    func start() {
        guard monitor == nil else { return }

        // Before the first poll, or the built-in table would be used for a
        // moment even when the user has replaced it.
        ruleStore.onChange = { [weak self] rules in
            self?.monitor?.rules = rules
        }
        ruleStore.start()
        // After the first load, so the mirror compares a table that parsed.
        cloudMirror.start()

        monitor = ClipboardMonitor(rules: rules) { [weak self] outcome in
            self?.record(outcome)
        }
        syncMonitor()
    }

    private func syncMonitor() {
        guard let monitor else { return }
        // Tearing the timer down rather than idling it, so a disabled
        // PasteBop costs nothing.
        if isEnabled {
            monitor.start()
        } else {
            monitor.stop()
        }
    }

    private func record(_ outcome: PasteboardNormalizer.Outcome) {
        copyCount += outcome.rewrittenItems
        tally += outcome.tally

        let provenance = outcome.provenance
        lastProvenance = provenance
        lastCopyCharacters = outcome.tally.characterCount
        if provenance.isMachineWritten { machineWrittenCopies += 1 }

        persistStatistics()
    }

    private func persistStatistics() {
        defaults.set(copyCount, forKey: Key.copyCount)
        defaults.set(tally.storage, forKey: Key.tally)
        defaults.set(machineWrittenCopies, forKey: Key.machineWrittenCopies)
    }
}
