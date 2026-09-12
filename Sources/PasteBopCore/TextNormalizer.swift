//
//  TextNormalizer.swift
//  PasteBopCore
//

/// Rewrites typographic and invisible characters into their keyboard equivalents.
///
/// Every entry point returns `nil` when nothing needed changing. The scanner
/// walks UTF-8 bytes, not characters: ASCII is rejected on one compare and
/// unchanged runs are copied as raw memory.
/// What became of one attempt at a rewrite.
///
/// `nil` used to mean both "nothing needed changing" and "this outgrew what it
/// was allowed", which are opposites: the first leaves a flavour alone because
/// it already agrees with the others, the second because it cannot be made to.
/// A clipboard item carries the same text several times over, so telling them
/// apart is what stops one copy being rewritten in its HTML and left alone in
/// its plain text.
public enum RewriteAttempt<Rewritten> {
    case unchanged
    case rewritten(Rewritten)
    /// Past `TextNormalizer.outputLimit(for:)`. The whole item is left alone.
    case tooLarge

    public var value: Rewritten? {
        if case .rewritten(let value) = self { return value }
        return nil
    }

    /// Carries the two decisions through a change of representation. A
    /// transform that cannot produce anything reads as unchanged, since that
    /// flavour is then simply left as it was.
    public func map<Other>(_ transform: (Rewritten) -> Other?) -> RewriteAttempt<Other> {
        switch self {
        case .unchanged: .unchanged
        case .tooLarge: .tooLarge
        case .rewritten(let value): transform(value).map { .rewritten($0) } ?? .unchanged
        }
    }
}

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
        attempt(input, rules: rules, escaping: escaping).value
    }

    /// The same rewrite, saying whether nothing needed changing or it grew
    /// past what it was allowed.
    public static func attempt(
        _ input: String,
        rules: RewriteRules = .builtIn,
        escaping: Escaping = .none
    ) -> RewriteAttempt<String> {
        guard !input.isEmpty else { return .unchanged }
        var subject = input
        var tooLarge = false
        let bytes = subject.withUTF8 {
            rewrite($0, table: rules.table, escaping: escaping, tooLarge: &tooLarge)
        }
        guard let bytes else { return tooLarge ? .tooLarge : .unchanged }
        // The bytes came from a String plus the table's outputs, so there is
        // no invalid UTF-8 for the repairing initialiser to hide.
        // swiftlint:disable:next optional_data_string_conversion
        return .rewritten(String(decoding: bytes, as: UTF8.self))
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

    /// Every match in `utf8`, in order, for rewriters that splice into another
    /// encoding. The same scanner as `normalize`, so they cannot drift from it.
    ///
    /// `body` returns whether to carry on. A rewriter says no once its output
    /// has grown past what it will keep, so the memory is never taken: at the
    /// widest replacement, running to the end of a full-sized document would
    /// ask for tens of gigabytes.
    static func forEachRewrite(
        in utf8: UnsafeBufferPointer<UInt8>,
        using table: ScalarTable,
        _ body: (_ range: Range<Int>, _ replacement: String) -> Bool
    ) {
        var cursor = 0
        while let hit = nextRewrite(in: utf8, from: cursor, using: table) {
            guard body(hit.index..<hit.end, hit.replacement) else { return }
            cursor = hit.end
        }
    }

    // MARK: - Scanner

    /// One match. A plain value: an index into the table rather than the rule
    /// itself, because anything refcounted here costs on every return.
    struct Hit {
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

    /// The most a rewrite may produce, matching the most PasteBop will read.
    public static let maximumOutputBytes = 64 << 20

    /// What a rewrite of `inputBytes` may grow to before it is abandoned.
    ///
    /// PasteBop normalises, so a rewrite normally *shrinks*: every built-in
    /// replacement is no longer than what it matches. A user rule may
    /// reasonably be longer — an em dash to " (em dash) " — but only a
    /// pathological one multiplies a whole document, and at
    /// `RuleFile.Limits.replacementScalars` a copy grows 341-fold, so 64 MB
    /// of text would ask for 21 GB.
    ///
    /// Scaled to the input rather than flat, because a flat ceiling is only
    /// reached by filling it: a 50 KB article would take 64 MB to discover it
    /// did not fit. This is a few hundred kilobytes and a few milliseconds
    /// instead. The floor keeps a short copy from being held to almost
    /// nothing, and no rewrite may pass what PasteBop will read back.
    static func outputLimit(for inputBytes: Int) -> Int {
        min(maximumOutputBytes, max(1 << 20, inputBytes * 4))
    }

    /// What to reserve up front for a rewrite of `inputBytes`.
    ///
    /// A rewrite is about the size of its input, so reserving that much is one
    /// allocation and no copying. Doubling into it instead is *slower* — a
    /// 1 MB cap measured 5 % off `ai prose`, which fills what it reserves —
    /// so the cap is not a growth strategy, only a guard against an
    /// unreasonable grab: past it the arrays double as they fill, so a
    /// 64 MB paste costs three reallocations rather than tens of megabytes
    /// taken before a byte of it has been read, and taken again by every
    /// array a styled flavour builds.
    ///
    /// Set far above any real copy. `inlineTextBytes` — a hundred pages — is
    /// 256 KB, so nothing a person actually pastes reaches this.
    static func reservation(for inputBytes: Int) -> Int {
        min(inputBytes, 8 << 20)
    }

    /// Rewritten UTF-8, or `nil` if the input was already clean or grew past
    /// what `outputLimit(for:)` allows it.
    private static func rewrite(
        _ utf8: UnsafeBufferPointer<UInt8>,
        table: ScalarTable,
        escaping: Escaping,
        tooLarge: inout Bool
    ) -> [UInt8]? {
        guard var hit = nextRewrite(in: utf8, from: 0, using: table) else { return nil }

        let limit = outputLimit(for: utf8.count)
        var output = [UInt8]()
        output.reserveCapacity(reservation(for: utf8.count) + 16)
        var runStart = 0

        while true {
            output.append(contentsOf: UnsafeBufferPointer(rebasing: utf8[runStart..<hit.index]))
            var replacement = escape(hit.replacement, escaping, table)
            replacement.withUTF8 { output.append(contentsOf: $0) }
            // Checked as it grows, not at the end: the point is to stop
            // before the memory is allocated, not to discard it afterwards.
            guard output.count <= limit else {
                tooLarge = true
                return nil
            }
            runStart = hit.end
            guard let next = nextRewrite(in: utf8, from: runStart, using: table) else { break }
            hit = next
        }

        output.append(contentsOf: UnsafeBufferPointer(rebasing: utf8[runStart...]))
        guard output.count <= limit else {
            tooLarge = true
            return nil
        }
        return output
    }

    private static let blackFlag: UInt32 = 0x1F3F4

    /// Just past a well-formed tag sequence beginning at `start`, or nil. A
    /// run that never reaches the terminator is not a flag, so it is left to
    /// the table to delete.
    private static func emojiTagSequenceEnd(
        _ utf8: UnsafeBufferPointer<UInt8>,
        after start: Int
    ) -> Int? {
        var index = start
        var sawTag = false
        while index < utf8.count {
            let (value, width) = decodeScalar(utf8, at: index)
            if value == 0xE007F { return sawTag ? index + width : nil }
            guard value >= 0xE0020, value <= 0xE007E else { return nil }
            sawTag = true
            index += width
        }
        return nil
    }

    /// The next match at or after `start`. Internal rather than private
    /// because the styled paths scan with it too; it is the one scanner and
    /// nothing outside this module reaches it.
    @inline(__always)
    static func nextRewrite(
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

            // Tag characters after a black flag spell a country: 🏴 then tag
            // letters then U+E007F. They are the one meaningful use of the
            // block, and deleting them turns the flag of England into a bare
            // black flag. Stray tag characters — the smuggling vector the
            // block is deleted for — are not preceded by a flag and still go.
            //
            // Checked here rather than before the lookup: the flag has no
            // rule of its own, so this costs nothing on the path every
            // rewritten character takes.
            if value == Self.blackFlag,
               let end = emojiTagSequenceEnd(utf8, after: index + width) {
                index = end
                continue
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
