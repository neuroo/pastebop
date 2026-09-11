//
//  RuleFile.swift
//  PasteBopCore
//

import Foundation

/// Reads and writes the user-editable rules file. The file *is* the table:
/// delete a line and that character is left alone, add one and it is not.
///
/// ```yaml
/// version: 1
///
/// rules:
///   U+2014: "--"            # EM DASH
///   U+E0000..U+E007F: ""    # TAG CHARACTERS
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

    /// Names and families come from the built-in table where the pattern is
    /// recognised; anything new lands in the custom family.
    public static func decode(_ document: String) throws -> RewriteRules {
        var version: Int?
        var inRulesSection = false
        var parsed: [Replacement] = []
        var firstSeen: [Pattern: Int] = [:]

        let known = Dictionary(
            Replacements.all.map { ($0.pattern, $0) },
            uniquingKeysWith: { first, _ in first }
        )

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

            guard parsed.count < Limits.rules else {
                throw ParseError(line: number, reason: .tooManyRules)
            }
            let (key, rest) = try split(line, on: number)
            let pattern = try parsePattern(key, on: number)
            if let first = firstSeen[pattern] {
                throw ParseError(line: number, reason: .duplicate(key, firstSeenOnLine: first))
            }
            firstSeen[pattern] = number

            let output = try parseValue(rest, on: number)
            guard output.unicodeScalars.count <= Limits.replacementScalars else {
                throw ParseError(line: number, reason: .replacementTooLong)
            }
            let template = known[pattern]
            parsed.append(Replacement(
                pattern: pattern,
                output: output,
                name: template?.name ?? defaultName(for: pattern, key: key),
                category: template?.category ?? .custom
            ))
        }

        guard version != nil else { throw ParseError(line: 1, reason: .missingVersion) }
        return RewriteRules(ordered(parsed))
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

    /// Built-in order, new rules last, so the Help window does not reshuffle
    /// because someone sorted their file.
    private static func ordered(_ parsed: [Replacement]) -> [Replacement] {
        let position = Dictionary(
            Replacements.all.enumerated().map { ($1.pattern, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return parsed.sorted {
            (position[$0.pattern] ?? .max, $0.pattern.firstScalar, $0.scalarCount)
                < (position[$1.pattern] ?? .max, $1.pattern.firstScalar, $1.scalarCount)
        }
    }

    /// For a rule the built-in table does not know. A readable substring
    /// beats its code points.
    private static func defaultName(for pattern: Pattern, key: String) -> String {
        guard case .sequence(let scalars) = pattern else { return key }
        let text = String(String.UnicodeScalarView(scalars.compactMap(Unicode.Scalar.init)))
        return text.allSatisfy { !$0.isWhitespace && $0.isASCII || !$0.isASCII }
            ? "SEQUENCE \(text)"
            : key
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

    /// Grouped by family, aligned, and commented with each character's name.
    /// Written by hand because the comments and grouping are the point; a
    /// serialiser would emit 258 bare mappings.
    public static func encode(_ rules: RewriteRules) -> String {
        var lines = header

        // Aligned on single-scalar keys; the rare range key overflows.
        let width = rules.replacements.lazy
            .filter { !$0.isRange }
            .map { key(for: $0).count }
            .max() ?? 0

        for category in rules.families {
            lines.append("")
            lines.append("  # \(category.rawValue)")
            for rule in rules.rules(in: category) {
                lines.append(line(for: rule, keyWidth: width))
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static var header: [String] {
        [
            "# PasteBop rules",
            "#",
            "# Every character PasteBop rewrites is listed below, and this file is the",
            "# whole table: delete a line and that character is left alone, add a line",
            "# and it starts being rewritten. Saving applies the change immediately.",
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

    private static func line(for rule: Replacement, keyWidth: Int) -> String {
        // Not String.padding(toLength:), which truncates.
        let key = key(for: rule).rightPadded(to: keyWidth)
        let value = quote(rule.output).rightPadded(to: 8)
        return "  \(key): \(value)  # \(comment(for: rule))"
    }

    private static func key(for rule: Replacement) -> String {
        switch rule.pattern {
        case .scalars(let range) where range.lowerBound == range.upperBound:
            hex(range.lowerBound)
        case .scalars(let range):
            "\(hex(range.lowerBound))..\(hex(range.upperBound))"
        case .sequence(let scalars):
            scalars.map(hex).joined(separator: " ")
        }
    }

    private static func hex(_ value: UInt32) -> String {
        "U+" + String(value, radix: 16, uppercase: true).leftPadded(to: 4, with: "0")
    }

    private static func quote(_ output: String) -> String {
        var escaped = ""
        for character in output {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    private static func comment(for rule: Replacement) -> String {
        guard rule.category.hasVisibleGlyphs else { return rule.name }
        if let scalar = rule.scalar { return "\(scalar)  \(rule.name)" }
        if let text = rule.sequenceText, !text.isEmpty { return "\(text)  \(rule.name)" }
        return rule.name
    }
}

/// Neither truncates. Alignment is cosmetic; losing characters is not.
private extension String {
    func leftPadded(to width: Int, with pad: Character) -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
    }

    func rightPadded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
