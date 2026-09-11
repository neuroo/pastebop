//
//  ClipboardMonitor.swift
//  PasteBop
//

import AppKit
import Foundation
import PasteBopCore

/// Watches `NSPasteboard` and rewrites it when the contents change. AppKit
/// publishes no notification for that, so `changeCount` is polled.
@MainActor
final class ClipboardMonitor {

    /// Faster than a human can switch apps and paste.
    static let pollInterval: TimeInterval = 0.25

    /// Lets the scheduler coalesce the wakeup with other timers.
    private static let leeway: DispatchTimeInterval = .milliseconds(100)

    private let pasteboard: NSPasteboard
    /// Swapped in when the rules file changes.
    var rules: RewriteRules
    private let onRewrite: (PasteboardNormalizer.Outcome) -> Void
    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int

    init(
        pasteboard: NSPasteboard = .general,
        rules: RewriteRules = .builtIn,
        onRewrite: @escaping (PasteboardNormalizer.Outcome) -> Void
    ) {
        self.pasteboard = pasteboard
        self.rules = rules
        self.onRewrite = onRewrite
        self.lastChangeCount = pasteboard.changeCount
    }

    deinit {
        timer?.cancel()
    }

    func start() {
        guard timer == nil else { return }
        // Adopt the current contents rather than reaching back for whatever
        // was copied before PasteBop was switched on.
        lastChangeCount = pasteboard.changeCount

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.pollInterval,
            repeating: Self.pollInterval,
            leeway: Self.leeway
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }

        let outcome = PasteboardNormalizer.normalize(pasteboard, rules: rules)
        // Our own write bumps the count; adopting it is what stops the loop.
        lastChangeCount = outcome.changeCount
        if outcome.didRewrite { onRewrite(outcome) }
    }
}
