//
//  RulesEditor.swift
//  PasteBop
//

import Observation
import PasteBopCore

/// The editing session behind the rules window: a `RuleSelection`, and the
/// decision about when to write it back.
@MainActor
@Observable
final class RulesEditor {

    /// Long enough that running down a column of switches writes the file
    /// once rather than once per row.
    private static let saveDelay = Duration.milliseconds(400)

    private(set) var selection: RuleSelection

    private let store: RuleStore
    /// The store revision `selection` was built from, so a table arriving
    /// while the window is open can be told apart from one it wrote itself.
    @ObservationIgnored private var revision: Int
    @ObservationIgnored private var isDirty = false
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    init(store: RuleStore) {
        self.store = store
        self.selection = RuleSelection(overrides: store.overrides)
        self.revision = store.revision
    }

    deinit {
        pendingSave?.cancel()
    }

    /// Rebuilds the switches from the file. Which side wins depends on
    /// whether the file moved underneath us.
    ///
    /// If it did not, anything the debounce still holds is the only news, so
    /// it is written first. If it did — a hand edit, or a table arriving from
    /// iCloud — the file wins and the pending edits are dropped: `selection`
    /// is a *whole table*, so writing a stale one would not lose a switch, it
    /// would revert every change that had arrived.
    func reload() {
        if store.revision == revision {
            flush()
        } else {
            cancelPendingSave()
        }
        selection = RuleSelection(overrides: store.overrides)
        revision = store.revision
    }

    func setOn(_ rule: Replacement, _ isOn: Bool) {
        reloadIfStale()
        selection.setOn(rule, isOn)
        scheduleSave()
    }

    func setOn(_ category: Replacement.Category, _ isOn: Bool) {
        reloadIfStale()
        selection.setOn(category, isOn)
        scheduleSave()
    }

    /// A switch flipped after the file changed must apply to what the file
    /// now says, not to what the window was showing before it changed.
    private func reloadIfStale() {
        guard store.revision != revision else { return }
        reload()
    }

    func restoreDefaults() {
        cancelPendingSave()
        store.restoreDefaults()
        reload()
    }

    /// The window can be closed, or the app left, before the debounce fires.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        save()
    }

    private func cancelPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
        isDirty = false
    }

    private func scheduleSave() {
        isDirty = true
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, let self else { return }
            self.pendingSave = nil
            self.save()
        }
    }

    private func save() {
        guard isDirty else { return }
        isDirty = false
        store.save(selection.changes)
        // Our own write is not the file moving underneath us.
        revision = store.revision
    }
}
