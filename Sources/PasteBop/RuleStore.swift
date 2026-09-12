//
//  RuleStore.swift
//  PasteBop
//

import AppKit
import Observation
import PasteBopCore

/// Owns `~/Library/Application Support/PasteBop/rules.yaml` and keeps the app
/// in step with it. Written with the built-in table on first launch, so there
/// is always something to open rather than a blank page; saving applies
/// immediately.
@MainActor
@Observable
final class RuleStore {

    /// Editors save by writing a new file and renaming it over the old one,
    /// which fires several events at once.
    private static let reloadDelay = Duration.milliseconds(150)

    static let fileName = "rules.yaml"

    private(set) var rules: RewriteRules = .builtIn

    /// What the file actually holds: the changes, not the table. The window
    /// edits these, and each one travels on its own.
    private(set) var overrides: RuleOverrides = .none

    /// Bumped whenever a readable table lands, from any route: a hand edit,
    /// the rules window, or a copy arriving from iCloud. Anything holding a
    /// table derived from this one can tell that the file moved underneath
    /// it.
    private(set) var revision = 0

    /// Set when the file could not be read. The last working rules stay in
    /// force, so a typo mid-edit does not stop PasteBop working.
    private(set) var failure: String?

    /// The failure as a sentence. Both the rules window and the About panel
    /// show it, and they must not word the same problem differently.
    var failureMessage: String? {
        failure.map { "Rules file: \($0) Still using the last rules that worked." }
    }

    var isCustomised: Bool {
        !overrides.isEmpty
    }

    let fileURL: URL?

    /// So the clipboard monitor can pick up a new set.
    var onChange: ((RewriteRules) -> Void)?

    /// Handed the changes whenever a readable file lands on disk, so a
    /// mirror can follow it. Never called for a file that failed to parse:
    /// nothing should propagate something the parser refused.
    var onOverridesChanged: ((RuleOverrides) -> Void)?

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?

    init(fileURL: URL? = AppSupport.directory()?.appending(path: RuleStore.fileName)) {
        self.fileURL = fileURL
    }

    deinit {
        pendingReload?.cancel()
        watcher?.cancel()
    }

    /// Loads the file, writing the defaults first if there is none.
    func start() {
        load()
        watch()
    }

    func restoreDefaults() {
        save(.none)
    }

    /// Writes the changes the rules window made, and picks them up again the
    /// same way an edit made by hand is picked up.
    func save(_ overrides: RuleOverrides) {
        save(RuleFile.encode(overrides))
    }

    private func save(_ text: String) {
        write(text)
        load()
        // The file has a new inode, so the old watch is stale.
        watch()
    }

    func edit() {
        guard let fileURL else { return }
        if !FileManager.default.fileExists(atPath: fileURL.path) { load() }
        NSWorkspace.shared.open(fileURL)
    }

    func revealInFinder() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func load() {
        guard let fileURL else { return }
        // Deleting the file asks for the defaults back; this also writes it
        // on a first launch.
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            write(RuleFile.encode(.none))
        }
        do {
            let size = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? 0
            guard size <= RuleFile.Limits.fileBytes else {
                let limit = RuleFile.Limits.fileBytes / 1024
                failure = "The rules file is \(size / 1024) KB; the limit is \(limit) KB."
                return
            }
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let parsed = try RuleFile.decode(text)
            overrides = parsed
            rules = RewriteRules(overrides: parsed)
            revision &+= 1
            failure = nil
            onChange?(rules)
            onOverridesChanged?(parsed)
        } catch let error as RuleFile.ParseError {
            // Keep the last rules that worked: editing the file must not stop
            // the clipboard being fixed mid-keystroke.
            failure = error.errorDescription
        } catch {
            failure = error.localizedDescription
        }
    }

    private func write(_ text: String) {
        guard let fileURL else { return }
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            failure = "Could not write the rules file: \(error.localizedDescription)"
        }
    }

    private func watch() {
        watcher?.cancel()
        watcher = nil

        guard let fileURL else { return }
        let descriptor = open(fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            // A rename or delete means the file was replaced, not written
            // into, so the watch has to be rebuilt.
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let replaced = source.data.contains(.delete)
                    || source.data.contains(.rename)
                    || source.data.contains(.revoke)
                self.scheduleReload(rewatch: replaced)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func scheduleReload(rewatch: Bool) {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: Self.reloadDelay)
            guard !Task.isCancelled, let self else { return }
            self.load()
            if rewatch { self.watch() }
        }
    }
}
