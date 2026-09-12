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

    /// Under human reaction time. Copying and pasting is two chords back to
    /// back, 150 ms apart at the very fastest; the rewrite has to land before
    /// the second one. Reading `changeCount` costs under a microsecond, so
    /// ten a second is nothing -- what a poll costs is the wakeup.
    static let pollInterval: Duration = .milliseconds(100)

    /// How late the timer may fire, so the kernel can fold the wakeup into
    /// one it was taking anyway. A quarter of the interval keeps the worst
    /// case at 125 ms, still under the fastest paste.
    static let leeway: Duration = .milliseconds(25)

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
            deadline: .now() + Self.pollInterval.dispatchInterval,
            repeating: Self.pollInterval.dispatchInterval,
            leeway: Self.leeway.dispatchInterval
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
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        // Claimed before the work starts, so a large document being rewritten
        // off the main thread is not picked up again by the next tick.
        lastChangeCount = changeCount

        PasteboardWork.normalizeClipboard(pasteboard, rules: rules) { [weak self] outcome in
            guard let self else { return }
            // Our own write bumps the count; adopting it is what stops the loop.
            self.lastChangeCount = outcome.changeCount
            if outcome.didRewrite { self.onRewrite(outcome) }
        }
    }
}

private extension Duration {
    var dispatchInterval: DispatchTimeInterval {
        let (seconds, attoseconds) = components
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }
}
