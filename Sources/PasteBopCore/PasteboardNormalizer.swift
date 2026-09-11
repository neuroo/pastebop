//
//  PasteboardNormalizer.swift
//  PasteBopCore
//

import AppKit
import Foundation
import UniformTypeIdentifiers

/// Rewrites the text flavours of a pasteboard in place, preserving everything else.
public enum PasteboardNormalizer {

    /// What a single pass over a pasteboard did.
    public struct Outcome: Sendable, Equatable {
        /// Zero means nothing was written.
        public let rewrittenItems: Int
        /// After the pass, so the caller can recognise its own write.
        public let changeCount: Int
        public let tally: RewriteTally
        /// Characters in the plain text that was rewritten, so the tally can
        /// be read as a density rather than a bare count.
        public let characterCount: Int

        public var didRewrite: Bool { rewrittenItems > 0 }

        /// What the rules that fired suggest about where the text came from.
        public var provenance: Provenance {
            Provenance(tally: tally, characterCount: characterCount)
        }

        init(
            rewrittenItems: Int,
            changeCount: Int,
            tally: RewriteTally = RewriteTally(),
            characterCount: Int = 0
        ) {
            self.rewrittenItems = rewrittenItems
            self.changeCount = changeCount
            self.tally = tally
            self.characterCount = characterCount
        }
    }

    // MARK: - Pasteboard types

    /// Set by password managers (nspasteboard.org). Touching it can defeat
    /// the owner's auto-clear.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static let utf16PlainText = NSPasteboard.PasteboardType("public.utf16-external-plain-text")

    /// Text above this is left exactly as it is.
    ///
    /// A memory bound rather than a time one: rewriting allocates a second
    /// copy, and the pasteboard write a third. Time is bounded separately, by
    /// running the work off the main thread with a deadline. Plain text scans
    /// at roughly 380 MB/s and RTF round-trips at roughly 4 MB/s, so nothing
    /// under this limit is slow for the reason the limit exists.
    public static let maximumTextBytes = 64 << 20

    /// Work below this is done inline, because dispatching it would cost more
    /// than doing it. A paragraph is a few hundred bytes; this is a hundred
    /// pages.
    public static let inlineTextBytes = 256 << 10

    /// Everything else -- images, video, PDFs -- is read only if one of these
    /// changed and the item has to be reproduced.
    static let textTypes: [NSPasteboard.PasteboardType] = [
        .string, utf16PlainText, .html, .rtf, .rtfd,
    ]

    /// Left alone in full. Files and links put their address in the text
    /// flavour, and `report\u{2014}final.pdf` must not paste as `report--final.pdf`.
    static let untouchableTypes: [NSPasteboard.PasteboardType] = [
        concealedType, transientType, .fileURL, .URL,
    ]

    /// Pre-UTI names `UTType` cannot classify; each is an alias for text.
    private static let legacyTextAliases: Set<String> = [
        "NSStringPboardType",
        "NeXT Rich Text Format v1.0 pasteboard type",
        "NeXT RTFD pasteboard type",
        "Apple HTML pasteboard type",
        "CorePasteboardFlavorType 0x54455854",  // 'TEXT'
        "CorePasteboardFlavorType 0x7574726C",  // 'utrl'
        "CorePasteboardFlavorType 0x75743136",  // 'ut16'
    ]

    /// The server advertises conversions it can perform, such as UTF-16
    /// beside stored UTF-8, and reading one returns nil. Those are safe to
    /// drop: writing the canonical flavour brings them back. Any other nil is
    /// data we failed to read, and stops the rewrite.
    private static func isDerivedTextAlias(_ type: NSPasteboard.PasteboardType) -> Bool {
        if legacyTextAliases.contains(type.rawValue) { return true }
        guard let utType = UTType(type.rawValue) else { return false }
        return utType.conforms(to: .text) || utType.conforms(to: .html) || utType.conforms(to: .rtf)
    }

    // MARK: - Snapshot, rewrite, apply

    /// The text flavours read off a pasteboard, detached from it.
    ///
    /// `NSPasteboard` is not safe to touch off the main thread, so the work is
    /// split: read there, rewrite anywhere, write back there. Keyed by raw
    /// type name so the whole thing is `Sendable` and can cross threads.
    public struct Snapshot: Sendable {
        struct Item: Sendable {
            var flavours: [String: Data]
            /// Concealed, transient, a file or a link: reproduced, never rewritten.
            var isProtected: Bool
        }

        var items: [Item]
        /// What the pasteboard read as, so a late write can tell whether the
        /// user has copied something else in the meantime.
        public let changeCount: Int

        public var isEmpty: Bool { items.allSatisfy(\.flavours.isEmpty) }

        /// Total bytes of text, for deciding whether to dispatch.
        public var textBytes: Int {
            items.reduce(0) { $0 + $1.flavours.values.reduce(0) { $0 + $1.count } }
        }
    }

    /// The rewritten flavours, ready to go back.
    public struct Rewrite: Sendable {
        var items: [[String: Data]]
        public let tally: RewriteTally
        public let characterCount: Int

        public var isEmpty: Bool { items.allSatisfy(\.isEmpty) }
    }

    /// Reads the text flavours. Main thread, and cheap: data copies only.
    @MainActor
    public static func snapshot(_ pasteboard: NSPasteboard) -> Snapshot {
        let changeCount = pasteboard.changeCount
        guard pasteboard.availableType(from: textTypes) != nil,
              let items = pasteboard.pasteboardItems, !items.isEmpty
        else { return Snapshot(items: [], changeCount: changeCount) }

        let read = items.map { item -> Snapshot.Item in
            let types = item.types
            guard !types.contains(where: untouchableTypes.contains) else {
                return Snapshot.Item(flavours: [:], isProtected: true)
            }
            var flavours: [String: Data] = [:]
            for type in types where textTypes.contains(type) {
                guard let data = item.data(forType: type),
                      data.count <= maximumTextBytes else { continue }
                flavours[type.rawValue] = data
            }
            return Snapshot.Item(flavours: flavours, isProtected: false)
        }
        return Snapshot(items: read, changeCount: changeCount)
    }

    /// Rewrites a snapshot. Pure, so it runs on whatever thread the caller likes.
    public static func rewrite(_ snapshot: Snapshot, rules: RewriteRules) -> Rewrite {
        var tally = RewriteTally()
        var characterCount = 0
        let items = snapshot.items.map { item -> [String: Data] in
            var changed: [String: Data] = [:]
            for (rawType, data) in item.flavours {
                let type = NSPasteboard.PasteboardType(rawType)
                guard let rewritten = rewrite(data, as: type, rules: rules) else { continue }
                changed[rawType] = rewritten
                // Plain text only, or every figure is multiplied by however
                // many flavours the app wrote.
                if type == .string, let text = String(data: data, encoding: .utf8) {
                    tally += TextNormalizer.tally(text, rules: rules)
                    characterCount += text.unicodeScalars.count
                }
            }
            return changed
        }
        return Rewrite(items: items, tally: tally, characterCount: characterCount)
    }

    /// Writes a rewrite back, if the pasteboard still holds what was read.
    ///
    /// The change count guard is what makes rewriting off the main thread
    /// safe: copy something else while a large document is being processed
    /// and the stale result is dropped rather than overwriting the new copy.
    @MainActor
    public static func apply(
        _ rewrite: Rewrite,
        to pasteboard: NSPasteboard,
        from snapshot: Snapshot
    ) -> Outcome {
        let unchanged = Outcome(rewrittenItems: 0, changeCount: pasteboard.changeCount)
        guard !rewrite.isEmpty else { return unchanged }
        guard pasteboard.changeCount == snapshot.changeCount else { return unchanged }
        guard let items = pasteboard.pasteboardItems, items.count == rewrite.items.count else {
            return unchanged
        }

        var rebuilt: [NSPasteboardItem] = []
        rebuilt.reserveCapacity(items.count)
        var rewrittenItems = 0
        for (item, changed) in zip(items, rewrite.items) {
            let byType = Dictionary(
                uniqueKeysWithValues: changed.map { (NSPasteboard.PasteboardType($0.key), $0.value) }
            )
            guard let copy = reproduce(item, replacing: byType) else { return unchanged }
            rebuilt.append(copy)
            if !changed.isEmpty { rewrittenItems += 1 }
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects(rebuilt) else {
            // clearContents() already moved the count; the old one would make
            // the monitor re-enter next tick.
            return Outcome(rewrittenItems: 0, changeCount: pasteboard.changeCount)
        }
        return Outcome(
            rewrittenItems: rewrittenItems,
            changeCount: pasteboard.changeCount,
            tally: rewrite.tally,
            characterCount: rewrite.characterCount
        )
    }

    // MARK: - Entry point

    /// Reads, rewrites and writes back in one go, on the calling thread.
    ///
    /// Correct for any size, but a large document blocks whoever called it.
    /// The clipboard monitor and the Services entry use the three steps
    /// separately so the slow part happens off the main thread.
    @MainActor
    public static func normalize(
        _ pasteboard: NSPasteboard,
        rules: RewriteRules = .builtIn
    ) -> Outcome {
        let taken = snapshot(pasteboard)
        guard !taken.isEmpty else {
            return Outcome(rewrittenItems: 0, changeCount: pasteboard.changeCount)
        }
        return apply(rewrite(taken, rules: rules), to: pasteboard, from: taken)
    }

    // MARK: - Items

    /// A faithful copy with `changed` swapped in, or `nil` if the item cannot
    /// be reproduced exactly. The only place non-text flavours are read.
    @MainActor
    private static func reproduce(
        _ item: NSPasteboardItem,
        replacing changed: [NSPasteboard.PasteboardType: Data]
    ) -> NSPasteboardItem? {
        let copy = NSPasteboardItem()
        for type in item.types {
            if let rewritten = changed[type] {
                copy.setData(rewritten, forType: type)
                continue
            }
            guard let data = item.data(forType: type) else {
                guard isDerivedTextAlias(type) else { return nil }
                continue
            }
            copy.setData(data, forType: type)
        }
        guard !copy.types.isEmpty else { return nil }
        return copy
    }

    /// Richest first. A service is handed one selection, and returning the
    /// styled form keeps the user's formatting.
    static let selectionTypes: [NSPasteboard.PasteboardType] = [.rtf, .rtfd, .html, .string]

    /// `nil` for flavours that are not text or need no change.
    static func rewrite(
        _ data: Data,
        as type: NSPasteboard.PasteboardType,
        rules: RewriteRules
    ) -> Data? {
        guard data.count <= maximumTextBytes else { return nil }
        switch type {
        case .string:
            guard let text = String(data: data, encoding: .utf8),
                  let rewritten = TextNormalizer.normalize(text, rules: rules) else { return nil }
            return Data(rewritten.utf8)

        case utf16PlainText:
            guard let text = String(data: data, encoding: .utf16),
                  let rewritten = TextNormalizer.normalize(text, rules: rules) else { return nil }
            return rewritten.data(using: .utf16)

        case .html:
            guard let markup = String(data: data, encoding: .utf8),
                  let rewritten = HTMLTextRewriter.rewrite(markup, rules: rules) else { return nil }
            return Data(rewritten.utf8)

        case .rtf:
            guard let styled = NSAttributedString(rtf: data, documentAttributes: nil),
                  let rewritten = TextNormalizer.normalize(styled, rules: rules) else { return nil }
            return rewritten.rtf(from: rewritten.fullRange, documentAttributes: [:])

        case .rtfd:
            guard let styled = NSAttributedString(rtfd: data, documentAttributes: nil),
                  let rewritten = TextNormalizer.normalize(styled, rules: rules) else { return nil }
            return rewritten.rtfd(from: rewritten.fullRange, documentAttributes: [:])

        default:
            return nil
        }
    }
}

private extension NSAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}
