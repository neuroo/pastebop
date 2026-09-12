//
//  RuleFile.swift
//  PasteBopCore
//

import Foundation

/// Reads and writes the user-editable rules file. The file holds *what
/// someone changed*, not the table: a character nobody mentions keeps its
/// built-in rule, which is how a new version's additions reach a Mac that
/// already has a file.
///
/// ```yaml
/// version: 1
///
/// rules:
///   U+2014: off     # leave this character alone
///   U+2013: "--"    # rewrite it to this instead
///   U+00A9: "(c)"   # a character with no built-in rule
/// ```
///
/// A small subset of YAML, parsed here rather than by a library, because the
/// schema is a flat mapping and a dependency would be the only third-party
/// code in the project. Valid-but-unsupported YAML is therefore rejected, so
/// every rejection names the line and says what was expected.
public enum RuleFile {

    /// Bumped when the file's meaning changes, so an older build refuses a
    /// file it would misread.
    public static let currentVersion = 1

    /// The file is user-controlled input; a pathological one must not make
    /// the scanner slow or the process large.
    public enum Limits {
        public static let rules = 10_000
        public static let sequenceScalars = 64
        public static let replacementScalars = 256
        public static let fileBytes = 4 << 20
    }

    // MARK: - Reading

    /// Names and families are not stored: they come from the built-in table
    /// when `RewriteRules` applies these.
    public static func decode(_ document: String) throws -> RuleOverrides {
        // The same ceiling RuleStore applies before it reads the file, here
        // too: every route to a table — the file, a copy arriving from
        // iCloud, the fuzzer — is held to one definition of acceptable.
        let bytes = document.utf8.count
        guard bytes <= Limits.fileBytes else {
            throw ParseError(line: 1, reason: .fileTooLarge(bytes: bytes))
        }

        var version: Int?
        var inRulesSection = false
        var overrides = RuleOverrides()
        var firstSeen: [Pattern: Int] = [:]

        for (offset, rawLine) in document.components(separatedBy: .newlines).enumerated() {
            let number = offset + 1
            guard !isBlankOrComment(rawLine) else { continue }

            let indented = rawLine.first == " " || rawLine.first == "\t"
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if !indented {
                switch try parseTopLevel(line, on: number) {
                case .rules: inRulesSection = true
                case .version(let parsed):
                    inRulesSection = false
                    version = parsed
                }
                continue
            }

            guard inRulesSection else {
                throw ParseError(line: number, reason: .ruleOutsideRulesSection)
            }

            guard overrides.count < Limits.rules else {
                throw ParseError(line: number, reason: .tooManyRules)
            }
            let (key, rest) = try split(line, on: number)
            let pattern = try parsePattern(key, on: number)
            if let first = firstSeen[pattern] {
                throw ParseError(line: number, reason: .duplicate(key, firstSeenOnLine: first))
            }
            firstSeen[pattern] = number

            let change = try parseChange(rest, on: number)
            if let output = change.output {
                guard output.unicodeScalars.count <= Limits.replacementScalars else {
                    throw ParseError(line: number, reason: .replacementTooLong)
                }
            }
            overrides[pattern] = change
        }

        guard version != nil else { throw ParseError(line: 1, reason: .missingVersion) }
        return overrides
    }

    /// `off` is the one value that is not quoted, optionally followed by the
    /// replacement to remember. Quotes stay required otherwise, or
    /// `--  # em dash` would be ambiguous and a replacement of `#`
    /// impossible — and `"off"` alone still means the literal text.
    static func parseChange(_ text: String, on number: Int) throws -> RuleOverrides.Change {
        let keyword = "off"
        if text.lowercased() == keyword || text.lowercased().hasPrefix(keyword + " ")
            || text.lowercased().hasPrefix(keyword + "\t") {
            let rest = String(text.dropFirst(keyword.count)).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || rest.hasPrefix("#") { return .off }
            // `off "--"`: switched off, and remembering what it was set to,
            // so switching it back on returns that rather than the default.
            return RuleOverrides.Change(output: try parseValue(rest, on: number), isOff: true)
        }
        return .output(try parseValue(text, on: number))
    }

    private enum TopLevel {
        case rules
        case version(Int)
    }

    private static func parseTopLevel(_ line: String, on number: Int) throws -> TopLevel {
        let (key, rest) = try split(line, on: number)
        switch key {
        case "rules":
            return .rules
        case "version":
            guard let parsed = Int(rest) else {
                throw ParseError(line: number, reason: .badVersion(rest))
            }
            guard parsed == currentVersion else {
                throw ParseError(line: number, reason: .unsupportedVersion(parsed))
            }
            return .version(parsed)
        default:
            throw ParseError(line: number, reason: .unknownKey(key))
        }
    }

    private static func isBlankOrComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    /// Splits `key: rest`. Keys never contain a colon, so the first one wins.
    private static func split(_ line: String, on number: Int) throws -> (key: String, rest: String) {
        guard let colon = line.firstIndex(of: ":") else {
            throw ParseError(line: number, reason: .missingColon)
        }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        var rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        // An unquoted trailing comment, as on "rules:  # the table".
        if rest.hasPrefix("#") { rest = "" }
        return (key, rest)
    }

    // MARK: - Scalars

    /// `U+2014`, a range `U+E0000..U+E007F`, a substring as scalars
    /// `U+0020 U+2014 U+0020`, or a substring as a literal `" - "`. The scalar
    /// form is the only way to write something invisible.
    static func parsePattern(_ key: String, on number: Int) throws -> Pattern {
        if let quote = key.first, quote == "\"" || quote == "'" {
            let text = try parseValue(key, on: number)
            let scalars = Array(text.unicodeScalars.map(\.value))
            guard !scalars.isEmpty else { throw ParseError(line: number, reason: .emptySequence) }
            return scalars.count == 1
                ? try scalarsPattern(scalars[0]...scalars[0], key: key, on: number)
                : try sequencePattern(scalars, key: key, on: number)
        }

        let words = key.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { throw ParseError(line: number, reason: .badScalar(key)) }
        if words.count == 1 {
            return try scalarsPattern(parseRange(words[0], on: number), key: key, on: number)
        }
        // A space-separated list is a substring; ranges cannot take part.
        let scalars = try words.map { word -> UInt32 in
            let range = try parseRange(word, on: number)
            guard range.lowerBound == range.upperBound else {
                throw ParseError(line: number, reason: .rangeInSequence(word))
            }
            return range.lowerBound
        }
        return try sequencePattern(scalars, key: key, on: number)
    }

    /// Refused below the scanner's floor: it skips ASCII without looking, so
    /// such a rule would be accepted and then never fire.
    private static func scalarsPattern(
        _ range: ClosedRange<UInt32>,
        key: String,
        on number: Int
    ) throws -> Pattern {
        guard range.lowerBound >= ScalarTable.floor else {
            throw ParseError(line: number, reason: .asciiScalar(key))
        }
        return .scalars(range)
    }

    private static func sequencePattern(_ scalars: [UInt32], key: String, on number: Int) throws -> Pattern {
        guard scalars.count <= Limits.sequenceScalars else {
            throw ParseError(line: number, reason: .sequenceTooLong(key))
        }
        return .sequence(scalars)
    }

    /// Parses `U+2014` or `U+E0000..U+E007F`.
    static func parseRange(_ key: String, on number: Int) throws -> ClosedRange<UInt32> {
        let parts = key.components(separatedBy: "..")
        guard parts.count <= 2 else { throw ParseError(line: number, reason: .badScalar(key)) }
        let bounds = try parts.map { try parseScalar($0, key: key, on: number) }
        let lower = bounds[0]
        let upper = bounds.count == 2 ? bounds[1] : lower
        guard lower <= upper else { throw ParseError(line: number, reason: .emptyRange(key)) }
        return lower...upper
    }

    private static func parseScalar(_ text: String, key: String, on number: Int) throws -> UInt32 {
        var digits = Substring(text.trimmingCharacters(in: .whitespaces))
        guard digits.hasPrefix("U+") || digits.hasPrefix("u+") else {
            throw ParseError(line: number, reason: .badScalar(key))
        }
        digits = digits.dropFirst(2)
        guard !digits.isEmpty, digits.count <= 6,
              let value = UInt32(digits, radix: 16),
              Unicode.Scalar(value) != nil
        else { throw ParseError(line: number, reason: .badScalar(key)) }
        return value
    }

    // MARK: - Values

    /// Quotes are required: without them `--  # em dash` is ambiguous and a
    /// replacement of `#` impossible.
    static func parseValue(_ text: String, on number: Int) throws -> String {
        guard let quote = text.first, quote == "\"" || quote == "'" else {
            throw ParseError(line: number, reason: .unquotedValue(text))
        }

        var output = ""
        var index = text.index(after: text.startIndex)
        var closed = false

        while index < text.endIndex {
            let character = text[index]
            if character == quote {
                // YAML doubles a quote to escape it inside a single-quoted string.
                let next = text.index(after: index)
                if quote == "'", next < text.endIndex, text[next] == "'" {
                    output.append("'")
                    index = text.index(after: next)
                    continue
                }
                closed = true
                index = next
                break
            }
            if character == "\\", quote == "\"" {
                index = text.index(after: index)
                guard index < text.endIndex else {
                    throw ParseError(line: number, reason: .unterminatedString)
                }
                output.append(try unescape(text, at: &index, on: number))
                continue
            }
            output.append(character)
            index = text.index(after: index)
        }

        guard closed else { throw ParseError(line: number, reason: .unterminatedString) }

        let trailing = String(text[index...]).trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || trailing.hasPrefix("#") else {
            throw ParseError(line: number, reason: .trailingText(trailing))
        }
        return output
    }

    /// Consumes one escape sequence, leaving `index` just past it.
    private static func unescape(
        _ text: String,
        at index: inout String.Index,
        on number: Int
    ) throws -> String {
        let escape = text[index]
        index = text.index(after: index)
        switch escape {
        case "\\": return "\\"
        case "\"": return "\""
        case "'": return "'"
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "0": return "\0"
        case "u":
            let digits = text[index...].prefix(4)
            guard digits.count == 4,
                  let value = UInt32(digits, radix: 16),
                  let scalar = Unicode.Scalar(value)
            else { throw ParseError(line: number, reason: .badEscape("u\(text[index...].prefix(4))")) }
            index = text.index(index, offsetBy: 4)
            return String(scalar)
        default:
            throw ParseError(line: number, reason: .badEscape(String(escape)))
        }
    }
}

// MARK: - Writing

extension RuleFile {

    /// Aligned, and commented with each character's name. Written by hand
    /// because the comments are the point: a bare mapping of code points is
    /// accurate and unreadable.
    public static func encode(_ overrides: RuleOverrides) -> String {
        var lines = header
        let entries = overrides.sorted

        if entries.isEmpty {
            lines.append("  # Nothing changed \u{2014} every character uses its default.")
        } else {
            // Aligned on single-scalar keys; the rare range or substring
            // key overflows rather than pushing every colon out.
            let width = entries.compactMap { entry -> Int? in
                guard case .scalars(let range) = entry.pattern,
                      range.lowerBound == range.upperBound else { return nil }
                return entry.pattern.fileKey.count
            }.max() ?? 0
            for entry in entries {
                lines.append(line(for: entry, keyWidth: width))
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static var header: [String] {
        [
            "# PasteBop rules",
            "#",
            "# Only what you have changed. Every other character uses PasteBop's",
            "# defaults, so a new version can add characters without this file",
            "# standing in the way. Saving applies the change immediately.",
            "#",
            "#   U+2014: off     leave this character alone",
            "#   U+2014: \"--\"    rewrite it to this instead",
            "#",
            "# Delete a line to go back to the default for that character.",
            "#",
            "# Keys are Unicode scalars written U+XXXX, or a range U+XXXX..U+YYYY.",
            "# Replacements must be quoted; \"\" deletes the character.",
            "#",
            "# Keep replacements to characters you can actually type, and be careful",
            "# adding rules for characters that carry meaning somewhere: accented",
            "# letters, CJK punctuation, and the joiners inside emoji and Persian text",
            "# are all left alone on purpose.",
            "#",
            "# To start over, choose \"Restore Default Rules\" from the PasteBop menu.",
            "",
            "version: \(currentVersion)",
            "",
            "rules:",
        ]
    }

    /// One entry line on its own, or nil when this build cannot read it.
    ///
    /// What the key-value store holds is read an entry at a time, because
    /// decoding it as one document would let a single line from a newer
    /// version discard every other entry — which a merge then reads as the
    /// other side having deleted them. Nil is not absence: the caller has to
    /// keep such an entry out of the merge rather than let it look deleted.
    public static func decodeEntry(_ line: String) -> (pattern: Pattern, change: RuleOverrides.Change)? {
        guard let one = try? decode(document([line])) else { return nil }
        return one.sorted.first
    }

    /// A minimal document around a set of entry lines: what the key-value
    /// store and the last-synced record hold, without the file's header.
    public static func document(_ lines: [String]) -> String {
        (["version: \(currentVersion)", "rules:"] + lines.map { "  " + $0 })
            .joined(separator: "\n")
    }

    /// One entry on its own, unpadded: what travels in the key-value store,
    /// so a copy arriving from iCloud is read by the same parser as the file.
    public static func line(for pattern: Pattern, _ change: RuleOverrides.Change) -> String {
        line(for: (pattern: pattern, change: change), keyWidth: 0)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func line(
        for entry: (pattern: Pattern, change: RuleOverrides.Change),
        keyWidth: Int
    ) -> String {
        // Not String.padding(toLength:), which truncates.
        let key = entry.pattern.fileKey.rightPadded(to: keyWidth)
        // `off "--"` is switched off but remembers its replacement, so
        // switching it back on does not silently hand back the built-in one.
        let value = switch (entry.change.isOff, entry.change.output) {
        case (true, nil): "off"
        case (true, let output?): "off " + quote(output)
        case (false, let output?): quote(output)
        case (false, nil): "off"
        }
        return "  \(key): \(value.rightPadded(to: 8))  # \(comment(for: entry.pattern))"
    }

    /// A comment runs to the end of the line, so a control character in one
    /// ends the line early and the file it was written into no longer parses.
    private static func printable(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            // A comment is not parsed, but it is still on a line, and a
            // separator in a character's name would end that line early.
            case let other where other.value < 0x20 || other.value == 0x7F || isLineBreak(other):
                result += "\\u{\(String(other.value, radix: 16, uppercase: true))}"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Scalars, not characters: Swift reads CR LF as one grapheme cluster,
    /// so iterating characters matches neither `\r` nor `\n` and writes the
    /// pair straight into the file, ending the line early.
    private static func quote(_ output: String) -> String {
        var escaped = ""
        for scalar in output.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case let other where isLineBreak(other): escaped += hexEscape(other)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    /// What the parser splits a document on, so what has to be escaped
    /// wherever it is written. More than `\n` and `\r`: `CharacterSet`
    /// counts U+000B, U+000C, U+0085, U+2028 and U+2029 as newlines too, and
    /// a replacement holding one used to write a line that came back as two.
    /// Asked of the set itself rather than listed, so the two cannot drift.
    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.newlines.contains(scalar)
    }

    /// `\uXXXX`, the only numeric escape the parser reads. Every scalar it
    /// treats as a newline is inside the basic plane, so four digits reach
    /// all of them.
    private static func hexEscape(_ scalar: Unicode.Scalar) -> String {
        let digits = String(scalar.value, radix: 16, uppercase: true)
        return "\\u" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }

    /// The name comes from the built-in table where there is one, so
    /// changing what a character becomes never changes what it is called.
    private static func comment(for pattern: Pattern) -> String {
        let known = Replacements.builtIn(pattern)
        // The name too, not just the glyph: a substring's display name is the
        // substring itself, so a separator inside one would end the line it
        // was written on and the file would come back with an extra rule.
        let name = printable(known?.name ?? pattern.displayName)
        guard known?.category.hasVisibleGlyphs ?? true else { return name }
        if case .scalars(let range) = pattern, range.lowerBound == range.upperBound,
           let scalar = Unicode.Scalar(range.lowerBound) {
            return "\(printable(String(scalar)))  \(name)"
        }
        if case .sequence(let scalars) = pattern {
            let text = printable(String(String.UnicodeScalarView(scalars.compactMap(Unicode.Scalar.init))))
            if !text.isEmpty { return "\(text)  \(name)" }
        }
        return name
    }
}

/// Does not truncate. Alignment is cosmetic; losing characters is not.
private extension String {
    func rightPadded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
