//
//  PasteboardWork.swift
//  PasteBopCore
//

import AppKit

/// Where the rewriting runs.
///
/// A paragraph takes microseconds, so dispatching it would cost more than
/// doing it. A large document does not: RTF round-trips at roughly 4 MB/s, so
/// a 15 MB styled selection is seconds of work, and seconds on the main thread
/// is a beachball in whatever app the user is typing in.
public enum PasteboardWork {

    /// Queue for anything too big to do inline. Utility rather than
    /// background: the user is waiting for the result, just not on the main
    /// thread.
    private static let queue = DispatchQueue(
        label: "info.neuroo.PasteBop.rewrite",
        qos: .utility
    )

    /// How long the Services entry will wait before giving up and leaving the
    /// selection alone. Long enough for any realistic document, short enough
    /// that a pathological one does not look like a hang.
    public static let deadline: TimeInterval = 5

    /// Rewrites a clipboard change without ever blocking the main thread.
    ///
    /// Small payloads are done inline so the common copy is rewritten before
    /// the user can switch apps. Large ones go to the queue, and the result is
    /// dropped if the clipboard moved on while they were being processed.
    @MainActor
    public static func normalizeClipboard(
        _ pasteboard: NSPasteboard,
        rules: RewriteRules,
        completion: @escaping @MainActor (PasteboardNormalizer.Outcome) -> Void
    ) {
        let snapshot = PasteboardNormalizer.snapshot(pasteboard)
        guard !snapshot.isEmpty else {
            completion(PasteboardNormalizer.Outcome(
                rewrittenItems: 0,
                changeCount: pasteboard.changeCount
            ))
            return
        }

        if snapshot.textBytes <= PasteboardNormalizer.inlineTextBytes {
            let rewrite = PasteboardNormalizer.rewrite(snapshot, rules: rules)
            completion(PasteboardNormalizer.apply(rewrite, to: pasteboard, from: snapshot))
            return
        }

        // The pasteboard never leaves the main actor. What crosses to the
        // queue is the snapshot and this closure, which is main-actor isolated
        // and so can hold the pasteboard safely.
        let finish: @MainActor (PasteboardNormalizer.Rewrite) -> Void = { rewrite in
            completion(PasteboardNormalizer.apply(rewrite, to: pasteboard, from: snapshot))
        }
        queue.async {
            let rewrite = PasteboardNormalizer.rewrite(snapshot, rules: rules)
            Task { @MainActor in finish(rewrite) }
        }
    }

    /// Rewrites a selection for the Services entry, which has to return with
    /// the pasteboard already updated.
    ///
    /// Reads exactly one flavour and writes back exactly one. Enumerating the
    /// item's types instead deadlocks: the pasteboard belongs to the app that
    /// invoked the service, that app is blocked inside the call waiting for
    /// an answer, and asking it to materialise a derived flavour waits on it
    /// right back. The service then dies on the system's 30 second timeout.
    ///
    /// A large selection goes to the queue and is waited for, because there is
    /// nowhere to hand a late answer: the system reads the pasteboard the
    /// moment this returns. Past the deadline the selection is left alone.
    @MainActor
    @discardableResult
    public static func normalizeSelection(
        _ pasteboard: NSPasteboard,
        rules: RewriteRules
    ) -> PasteboardNormalizer.Outcome {
        let unchanged = PasteboardNormalizer.Outcome(
            rewrittenItems: 0,
            changeCount: pasteboard.changeCount
        )
        guard let type = pasteboard.availableType(from: PasteboardNormalizer.selectionTypes),
              let data = pasteboard.data(forType: type),
              data.count <= PasteboardNormalizer.maximumTextBytes
        else { return unchanged }

        let rewritten: Data?
        if data.count <= PasteboardNormalizer.inlineTextBytes {
            rewritten = PasteboardNormalizer.rewrite(data, as: type, rules: rules)
        } else {
            let box = DataBox()
            let finished = DispatchSemaphore(value: 0)
            queue.async {
                box.value = PasteboardNormalizer.rewrite(data, as: type, rules: rules)
                finished.signal()
            }
            guard finished.wait(timeout: .now() + deadline) == .success else { return unchanged }
            rewritten = box.value
        }

        guard let rewritten else { return unchanged }

        var tally = RewriteTally()
        var characterCount = 0
        if type == .string, let text = String(data: data, encoding: .utf8) {
            tally = TextNormalizer.tally(text, rules: rules)
            characterCount = text.unicodeScalars.count
        }

        pasteboard.clearContents()
        pasteboard.setData(rewritten, forType: type)
        return PasteboardNormalizer.Outcome(
            rewrittenItems: 1,
            changeCount: pasteboard.changeCount,
            tally: tally,
            characterCount: characterCount
        )
    }
}

/// Hands one result back across the semaphore. Written on the queue, read only
/// after the wait succeeds, so the two never touch it at once.
private final class DataBox: @unchecked Sendable {
    var value: Data?
}
