//
//  TextNormalizer.swift
//  PasteBopCore
//

import Foundation

/// Rewrites typographic and invisible characters into their keyboard equivalents.
///
/// Every entry point returns `nil` when nothing needed changing. The scanner
/// walks UTF-8 bytes, not characters: ASCII is rejected on one compare and
/// unchanged runs are copied as raw memory.
public enum TextNormalizer {

    public enum Escaping: Sendable {
        case none
        /// For an HTML text node, where `LEFTWARDS ARROW -> "<-"` would
        /// otherwise open a tag.
        case html
    }

    // MARK: - Plain text

    /// Returns the rewritten string, or `nil` if nothing needed rewriting.
    public static func normalize(
        _ input: String,
        rules: RewriteRules = .builtIn,
        escaping: Escaping = .none
    ) -> String? {
        guard !input.isEmpty else { return nil }
        var subject = input
        guard let bytes = subject.withUTF8({ rewrite($0, table: rules.table, escaping: escaping) })
        else { return nil }
        // The bytes came from a String plus the table's outputs, so there is
        // no invalid UTF-8 for the repairing initialiser to hide.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The rewritten string, or the input unchanged.
    public static func normalized(_ input: String, rules: RewriteRules = .builtIn) -> String {
        normalize(input, rules: rules) ?? input
    }

    /// Whether `input` holds at least one character these rules rewrite.
    public static func needsRewrite(_ input: String, rules: RewriteRules = .builtIn) -> Bool {
        guard !input.isEmpty else { return false }
        var subject = input
        return subject.withUTF8 { nextRewrite(in: $0, from: 0, using: rules.table) != nil }
    }

    /// Counts which rules `input` fires. A separate pass, so the rewrite loop
    /// carries no counting.
    public static func tally(_ input: String, rules: RewriteRules = .builtIn) -> RewriteTally {
        guard !input.isEmpty else { return RewriteTally() }
        var subject = input
        return subject.withUTF8 { utf8 in
            var tally = RewriteTally()
            var cursor = 0
            while let hit = nextRewrite(in: utf8, from: cursor, using: rules.table) {
                // A scalar inside a range rule is credited to that rule.
                let key: String
                if hit.sequenceIndex == Hit.noSequence {
                    key = rules.rule(for: hit.value)?.pattern.key
                        ?? Pattern.scalars(hit.value...hit.value).key
                } else {
                    key = Pattern.sequence(rules.table.sequence(at: hit.sequenceIndex).scalars).key
                }
                tally.record(key)
                cursor = hit.end
            }
            return tally
        }
    }

    // MARK: - Attributed text

    /// Keeps the styling. Edits are applied back to front so earlier ranges
    /// stay valid as the text shifts.
    public static func normalize(
        _ input: NSAttributedString,
        rules: RewriteRules = .builtIn
    ) -> NSAttributedString? {
        var source = input.string
        guard !source.isEmpty else { return nil }

        // Same scanner as plain text; byte offsets become UTF-16 ranges.
        let edits: [(range: NSRange, text: String)] = source.withUTF8 { utf8 in
            var edits: [(range: NSRange, text: String)] = []
            var byteCursor = 0
            var utf16Cursor = 0
            while let hit = nextRewrite(in: utf8, from: byteCursor, using: rules.table) {
                utf16Cursor += utf16Length(of: utf8, from: byteCursor, to: hit.index)
                let length = utf16Length(of: utf8, from: hit.index, to: hit.end)
                edits.append((NSRange(location: utf16Cursor, length: length), hit.replacement))
                utf16Cursor += length
                byteCursor = hit.end
            }
            return edits
        }
        guard !edits.isEmpty else { return nil }

        let result = NSMutableAttributedString(attributedString: input)
        result.beginEditing()
        for edit in edits.reversed() {
            result.mutableString.replaceCharacters(in: edit.range, with: edit.text)
        }
        result.endEditing()
        return result
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

    // MARK: - Scanner

    /// One match. A plain value: an index into the table rather than the rule
    /// itself, because anything refcounted here costs on every return.
    private struct Hit {
        let index: Int
        let width: Int
        /// The scalar matched, or the first scalar of the substring.
        let value: UInt32
        /// Index into the table's substring rules, or `noSequence`.
        let sequenceIndex: Int
        let replacement: String

        static let noSequence = -1

        var end: Int { index + width }
    }

    /// Rewritten UTF-8, or `nil` if the input was already clean.
    private static func rewrite(
        _ utf8: UnsafeBufferPointer<UInt8>,
        table: ScalarTable,
        escaping: Escaping
    ) -> [UInt8]? {
        guard var hit = nextRewrite(in: utf8, from: 0, using: table) else { return nil }

        var output = [UInt8]()
        output.reserveCapacity(utf8.count + 16)
        var runStart = 0

        while true {
            output.append(contentsOf: UnsafeBufferPointer(rebasing: utf8[runStart..<hit.index]))
            var replacement = escape(hit.replacement, escaping, table)
            replacement.withUTF8 { output.append(contentsOf: $0) }
            runStart = hit.end
            guard let next = nextRewrite(in: utf8, from: runStart, using: table) else { break }
            hit = next
        }

        output.append(contentsOf: UnsafeBufferPointer(rebasing: utf8[runStart...]))
        return output
    }

    /// The next match at or after `start`.
    @inline(__always)
    private static func nextRewrite(
        in utf8: UnsafeBufferPointer<UInt8>,
        from start: Int,
        using table: ScalarTable
    ) -> Hit? {
        // Loop-invariant; read once, not per byte.
        let hasSequences = table.hasSequences
        let asciiCanStart = table.hasASCIISequenceStarts

        var index = start
        let count = utf8.count
        while index < count {
            // No single-scalar rule fires below U+00A0, so ASCII is skipped on
            // one compare -- unless a substring rule starts with ASCII, which
            // the default table never does.
            if asciiCanStart {
                let byte = utf8[index]
                if byte < 0x80 {
                    if table.asciiCanStartSequence(byte),
                       let hit = matchSequence(utf8, at: index, first: UInt32(byte), using: table) {
                        return hit
                    }
                    index += 1
                    continue
                }
            } else {
                while index < count, utf8[index] < 0x80 { index += 1 }
                if index == count { return nil }
            }

            let (value, width) = decodeScalar(utf8, at: index)

            // Substrings beat the single-scalar rule for the same first scalar.
            if hasSequences, let hit = matchSequence(utf8, at: index, first: value, using: table) {
                return hit
            }
            if let replacement = table.replacement(forValue: value) {
                return Hit(
                    index: index,
                    width: width,
                    value: value,
                    sequenceIndex: Hit.noSequence,
                    replacement: replacement
                )
            }
            index += width
        }
        return nil
    }

    /// The longest substring rule matching at `index`. Candidates arrive
    /// longest first, so the first full match wins. Not inlined: it would
    /// bloat the loop every byte runs through.
    private static func matchSequence(
        _ utf8: UnsafeBufferPointer<UInt8>,
        at index: Int,
        first: UInt32,
        using table: ScalarTable
    ) -> Hit? {
        guard let candidates = table.sequenceIndices(startingWith: first) else { return nil }

        for sequenceIndex in candidates {
            let candidate = table.sequence(at: sequenceIndex)
            var cursor = index
            var matched = true
            for expected in candidate.scalars {
                guard cursor < utf8.count else { matched = false; break }
                let (value, width) = decodeScalar(utf8, at: cursor)
                guard value == expected else { matched = false; break }
                cursor += width
            }
            if matched {
                return Hit(
                    index: index,
                    width: cursor - index,
                    value: first,
                    sequenceIndex: sequenceIndex,
                    replacement: candidate.output
                )
            }
        }
        return nil
    }

    /// The bytes come from a `String`, so they are well formed and need no
    /// validation; the length checks only guard against reading past the end.
    @inline(__always)
    private static func decodeScalar(
        _ utf8: UnsafeBufferPointer<UInt8>,
        at index: Int
    ) -> (value: UInt32, width: Int) {
        let lead = utf8[index]
        let remaining = utf8.count - index

        if lead < 0x80 {
            return (UInt32(lead), 1)
        }
        if lead < 0xE0, remaining >= 2 {
            return ((UInt32(lead & 0x1F) << 6)
                    | UInt32(utf8[index + 1] & 0x3F), 2)
        }
        if lead < 0xF0, remaining >= 3 {
            return ((UInt32(lead & 0x0F) << 12)
                    | (UInt32(utf8[index + 1] & 0x3F) << 6)
                    | UInt32(utf8[index + 2] & 0x3F), 3)
        }
        if lead >= 0xF0, remaining >= 4 {
            return ((UInt32(lead & 0x07) << 18)
                    | (UInt32(utf8[index + 1] & 0x3F) << 12)
                    | (UInt32(utf8[index + 2] & 0x3F) << 6)
                    | UInt32(utf8[index + 3] & 0x3F), 4)
        }
        // Unreachable for a Swift String; zero is below the floor, so a
        // truncated tail is stepped over rather than misread.
        return (0, 1)
    }

    // MARK: - Escaping

    /// Escaped forms come from the table in force, so a user rule producing
    /// markup is escaped like a shipped one.
    @inline(__always)
    private static func escape(_ replacement: String, _ escaping: Escaping, _ table: ScalarTable) -> String {
        switch escaping {
        case .none: replacement
        case .html: table.htmlEscaped(replacement)
        }
    }
}
