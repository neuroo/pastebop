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

    // MARK: - Entry point

    /// Writes back only if some text flavour changed. Text is read and
    /// rewritten first; everything else is read only after that, to reproduce
    /// the item. If any flavour cannot be read back the pasteboard is left
    /// alone: losing a promised file is worse than leaving a curly quote.
    @MainActor
    public static func normalize(
        _ pasteboard: NSPasteboard,
        rules: RewriteRules = .builtIn
    ) -> Outcome {
        let unchanged = Outcome(rewrittenItems: 0, changeCount: pasteboard.changeCount)

        // A picture, a video, a PDF: leave without reading a byte of it.
        guard pasteboard.availableType(from: textTypes) != nil,
              let items = pasteboard.pasteboardItems, !items.isEmpty
        else { return unchanged }

        var tally = RewriteTally()
        var characterCount = 0
        let rewrites = items.map { item in
            rewriteText(of: item, rules: rules, tally: &tally, characterCount: &characterCount)
        }
        guard rewrites.contains(where: { !$0.isEmpty }) else { return unchanged }

        var rebuilt: [NSPasteboardItem] = []
        rebuilt.reserveCapacity(items.count)
        var rewrittenItems = 0
        for (item, changed) in zip(items, rewrites) {
            guard let copy = reproduce(item, replacing: changed) else { return unchanged }
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
            tally: tally,
            characterCount: characterCount
        )
    }

    // MARK: - Items

    /// The rewritten text flavours, keyed by type. Reads text flavours only.
    @MainActor
    private static func rewriteText(
        of item: NSPasteboardItem,
        rules: RewriteRules,
        tally: inout RewriteTally,
        characterCount: inout Int
    ) -> [NSPasteboard.PasteboardType: Data] {
        let types = item.types
        guard !types.contains(where: untouchableTypes.contains) else { return [:] }

        var changed: [NSPasteboard.PasteboardType: Data] = [:]
        for type in types where textTypes.contains(type) {
            guard let data = item.data(forType: type),
                  let rewritten = rewrite(data, as: type, rules: rules)
            else { continue }
            changed[type] = rewritten
            // Plain text only, or every figure is multiplied by however many
            // flavours the app wrote.
            if type == .string, let text = String(data: data, encoding: .utf8) {
                tally += TextNormalizer.tally(text, rules: rules)
                characterCount += text.unicodeScalars.count
            }
        }
        return changed
    }

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

    /// `nil` for flavours that are not text or need no change.
    private static func rewrite(
        _ data: Data,
        as type: NSPasteboard.PasteboardType,
        rules: RewriteRules
    ) -> Data? {
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
