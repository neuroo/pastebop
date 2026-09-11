//
//  UpdateChecker.swift
//  PasteBop
//

import AppKit
import Observation
import PasteBopCore

/// Asks GitHub whether a newer release exists, weekly and on demand. The
/// weekly check is silent unless there is something to say and never mentions
/// the same release twice; the manual one always reports back.
@MainActor
@Observable
final class UpdateChecker {

    /// Much shorter than the interval, so a machine that spends most of its
    /// life asleep still gets there.
    private static let pollInterval: TimeInterval = 6 * 60 * 60

    enum Reason {
        case manual
        case scheduled
    }

    private(set) var isChecking = false

    private let repository: String
    private let currentVersion: String
    private let session: URLSession
    private let store: UpdateStateStore
    // Neither drives the UI, and @Observable would make them isolated
    // accessors deinit cannot reach.
    @ObservationIgnored private var state: UpdateState
    @ObservationIgnored private var timer: DispatchSourceTimer?

    init(
        repository: String,
        currentVersion: String,
        session: URLSession = .shared,
        store: UpdateStateStore = UpdateStateStore()
    ) {
        self.repository = repository
        self.currentVersion = currentVersion
        self.session = session
        self.store = store
        self.state = store.load()
    }

    deinit {
        timer?.cancel()
    }

    /// Checks immediately if one is overdue, then weekly.
    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + 5,
            repeating: Self.pollInterval,
            leeway: .seconds(600)
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state.isCheckDue() else { return }
                Task { await self.check(.scheduled) }
            }
        }
        timer.resume()
        self.timer = timer
    }

    func check(_ reason: Reason) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let outcome: UpdateCheck.Outcome
        do {
            outcome = try await fetch()
        } catch {
            // A failure still counts, or an offline machine retries every tick.
            record(checkedAt: .now)
            if reason == .manual { present(error) }
            return
        }

        record(checkedAt: .now)

        switch (outcome, reason) {
        case (.updateAvailable(let release), .scheduled):
            guard state.shouldAnnounce(release.version) else { return }
            record(announced: release.version)
            announce(release)
        case (.updateAvailable(let release), .manual):
            record(announced: release.version)
            announce(release)
        case (.upToDate(let version), .manual):
            show(title: "PasteBop is up to date", message: "You have \(version), the latest release.")
        case (.upToDate, .scheduled):
            break
        }
    }

    // MARK: - Networking

    private func fetch() async throws -> UpdateCheck.Outcome {
        guard let url = UpdateCheck.latestReleaseURL(repository: repository) else {
            throw UpdateCheck.Failure.notFound
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects requests without one.
        request.setValue("PasteBop/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try UpdateCheck.outcome(status: status, body: data, currentVersion: currentVersion)
    }

    // MARK: - State

    private func record(checkedAt date: Date) {
        state.lastCheck = date
        store.save(state)
    }

    private func record(announced version: AppVersion) {
        state.lastNotifiedVersion = version.description
        store.save(state)
    }

    // MARK: - Telling the user

    private func announce(_ release: UpdateCheck.Release) {
        let download = show(
            title: "PasteBop \(release.version) is available",
            message: "You have \(currentVersion).",
            confirm: "Download"
        )
        if download {
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    private func present(_ error: any Error) {
        show(
            title: "Could not check for updates",
            message: error.localizedDescription,
            style: .warning
        )
    }

    /// True when the confirming button was chosen. The activation is what
    /// keeps the alert from opening behind everything.
    @discardableResult
    private func show(
        title: String,
        message: String,
        confirm: String? = nil,
        style: NSAlert.Style = .informational
    ) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: confirm ?? "OK")
        if confirm != nil {
            alert.addButton(withTitle: "Later")
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
