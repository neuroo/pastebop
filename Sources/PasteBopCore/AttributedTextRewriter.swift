//
//  AttributedTextRewriter.swift
//  PasteBopCore
//
//  The styled-text path. Same scanner as plain text -- byte offsets become
//  UTF-16 ranges -- but everything else about it is different enough to keep
//  apart: Cocoa's attribute runs, and a result built in one forward pass
//  because editing a copy in place is quadratic in them.
//

import Foundation

extension TextNormalizer {

    /// Keeps the styling.
    ///
    /// Built as one forward pass rather than by editing a copy in place. Each
    /// `replaceCharacters` has to shuffle every attribute run after it, so a
    /// call per rewrite is quadratic: a 17 MB document took over three
    /// minutes that way, against a fraction of a second for this.
    public static func normalize(
        _ input: NSAttributedString,
        rules: RewriteRules = .builtIn
    ) -> NSAttributedString? {
        attempt(input, rules: rules).value
    }

    /// The same rewrite, saying whether nothing needed changing or it grew
    /// past what it was allowed.
    public static func attempt(
        _ input: NSAttributedString,
        rules: RewriteRules = .builtIn
    ) -> RewriteAttempt<NSAttributedString> {
        var source = input.string
        guard !source.isEmpty else { return .unchanged }

        // Same scanner as plain text; byte offsets become UTF-16 ranges.
        let edits: [(range: NSRange, text: String)]? = source.withUTF8 { utf8 in
            var edits: [(range: NSRange, text: String)] = []
            var byteCursor = 0
            var utf16Cursor = 0
            // The edits are small; the string they will be applied to is not.
            // Its size is known from them, so the ceiling is enforced before
            // any of it is built rather than after.
            let limit = outputLimit(for: utf8.count)
            var willProduce = utf8.count
            while let hit = nextRewrite(in: utf8, from: byteCursor, using: rules.table) {
                willProduce += hit.replacement.utf8.count - (hit.end - hit.index)
                guard willProduce <= limit else { return nil }
                utf16Cursor += utf16Length(of: utf8, from: byteCursor, to: hit.index)
                let length = utf16Length(of: utf8, from: hit.index, to: hit.end)
                edits.append((NSRange(location: utf16Cursor, length: length), hit.replacement))
                utf16Cursor += length
                byteCursor = hit.end
            }
            return edits
        }
        guard let edits else { return .tooLarge }
        guard !edits.isEmpty else { return .unchanged }

        let result = NSMutableAttributedString()
        result.beginEditing()
        var cursor = 0
        // Every untouched run becomes an autoreleased attributed string on its
        // way into the result. Without a pool to drain, a document with many
        // rewrites holds all of them at once: measured at forty-five times the
        // size of the text, which at the input ceiling is gigabytes. Drained
        // in batches rather than per edit, which costs more than it saves.
        for batch in stride(from: 0, to: edits.count, by: 4096) {
            autoreleasepool {
                for edit in edits[batch..<min(batch + 4096, edits.count)] {
                    if edit.range.location > cursor {
                        let untouched = NSRange(
                            location: cursor,
                            length: edit.range.location - cursor
                        )
                        result.append(input.attributedSubstring(from: untouched))
                    }
                    if !edit.text.isEmpty {
                        // The replacement inherits the styling of what it replaces.
                        let attributes = input.attributes(
                            at: edit.range.location,
                            effectiveRange: nil
                        )
                        result.append(NSAttributedString(string: edit.text, attributes: attributes))
                    }
                    cursor = edit.range.location + edit.range.length
                }
            }
        }
        if cursor < input.length {
            let tail = NSRange(location: cursor, length: input.length - cursor)
            result.append(input.attributedSubstring(from: tail))
        }
        result.endEditing()
        return .rewritten(result)
    }

    /// UTF-16 units in a span of well-formed UTF-8, from lead bytes alone.
    @inline(__always)
    private static func utf16Length(
        of utf8: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int
    ) -> Int {
        var length = 0
        var index = start
        while index < end {
            let byte = utf8[index]
            // Anything but a 10xxxxxx continuation byte begins a scalar.
            if byte & 0xC0 != 0x80 {
                length += byte >= 0xF0 ? 2 : 1
            }
            index += 1
        }
        return length
    }
}
