//
//  Replacements.swift
//  PasteBopCore
//
//  The single source of truth for every character PasteBop rewrites.
//  Anything absent from this table is passed through untouched.
//

/// What a rule matches.
public enum Pattern: Sendable, Hashable {
    /// One scalar, or a contiguous run of them.
    case scalars(ClosedRange<UInt32>)
    /// Two or more scalars that must appear in order. Matched greedily, so a
    /// sequence always beats a single-scalar rule for the same first scalar.
    case sequence([UInt32])

    /// The scalars that can begin a match.
    var firstScalar: UInt32 {
        switch self {
        case .scalars(let range): range.lowerBound
        case .sequence(let scalars): scalars.first ?? 0
        }
    }

    /// The statistics key. A single scalar's key is its bare code point, so
    /// statistics recorded before sequences existed still read.
    public var key: String {
        switch self {
        case .scalars(let range) where range.lowerBound == range.upperBound:
            String(range.lowerBound, radix: 16)
        case .scalars(let range):
            "\(String(range.lowerBound, radix: 16))-\(String(range.upperBound, radix: 16))"
        case .sequence(let scalars):
            scalars.map { String($0, radix: 16) }.joined(separator: ".")
        }
    }
}

extension Pattern {

    /// How the rules file writes this: `U+2014`, `U+E0000..U+E007F`, or a
    /// substring's scalars separated by spaces.
    public var fileKey: String {
        switch self {
        case .scalars(let range) where range.lowerBound == range.upperBound:
            Self.hex(range.lowerBound)
        case .scalars(let range):
            "\(Self.hex(range.lowerBound))..\(Self.hex(range.upperBound))"
        case .sequence(let scalars):
            scalars.map(Self.hex).joined(separator: " ")
        }
    }

    /// What to call a pattern the built-in table does not know. A readable
    /// substring beats its code points.
    public var displayName: String {
        guard case .sequence(let scalars) = self else { return fileKey }
        let text = String(String.UnicodeScalarView(scalars.compactMap(Unicode.Scalar.init)))
        return text.allSatisfy { !$0.isWhitespace && $0.isASCII || !$0.isASCII }
            ? "SEQUENCE \(text)"
            : fileKey
    }

    private static func hex(_ value: UInt32) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return "U+" + (digits.count >= 4 ? digits : String(repeating: "0", count: 4 - digits.count) + digits)
    }
}

/// One rewrite rule.
public struct Replacement: Sendable, Hashable {
    public let pattern: Pattern
    /// Empty means "delete".
    public let output: String
    /// Shown in the rules file and the Help window.
    public let name: String
    public let category: Category

    public init(pattern: Pattern, output: String, name: String, category: Category) {
        self.pattern = pattern
        self.output = output
        self.name = name
        self.category = category
    }

    init(_ value: UInt32, _ output: String, _ name: String, _ category: Category) {
        self.init(pattern: .scalars(value...value), output: output, name: name, category: category)
    }

    init(_ range: ClosedRange<UInt32>, _ output: String, _ name: String, _ category: Category) {
        self.init(pattern: .scalars(range), output: output, name: name, category: category)
    }

    public var range: ClosedRange<UInt32>? {
        switch pattern {
        case .scalars(let range): range
        case .sequence: nil
        }
    }

    public var sequence: [UInt32]? {
        switch pattern {
        case .scalars: nil
        case .sequence(let scalars): scalars
        }
    }

    public var isRange: Bool {
        guard case .scalars(let range) = pattern else { return false }
        return range.lowerBound != range.upperBound
    }

    public var isSequence: Bool {
        if case .sequence = pattern { return true }
        return false
    }

    public var scalarCount: Int {
        switch pattern {
        case .scalars(let range): range.count
        case .sequence(let scalars): scalars.count
        }
    }

    /// Nil for ranges, sequences and surrogate values, never a stand-in.
    public var scalar: Unicode.Scalar? {
        guard case .scalars(let range) = pattern, range.lowerBound == range.upperBound else {
            return nil
        }
        return Unicode.Scalar(range.lowerBound)
    }

    public var sequenceText: String? {
        sequence.map { String(String.UnicodeScalarView($0.compactMap(Unicode.Scalar.init))) }
    }
}

extension Replacement {
    public enum Category: String, Sendable, CaseIterable {
        case quotes = "Quotes and apostrophes"
        case dashes = "Dashes and hyphens"
        case punctuation = "Punctuation"
        case spaces = "Spaces"
        case invisibles = "Invisible characters"
        case bullets = "List bullets"
        case symbols = "Math and arrows"
        /// Anything the user added to the rules file that is not in the
        /// built-in table.
        case custom = "Custom"

        /// Whether characters in this family render as something you can see.
        /// Spaces and invisibles do not, so they are named rather than shown.
        public var hasVisibleGlyphs: Bool {
            self != .invisibles && self != .spaces
        }
    }
}

/// The rewrite table, grouped by family.
///
/// Deliberately *not* rewritten, because they are meaningful text rather than
/// typographic noise:
///
/// - Accented Latin letters (`é ñ ü ç …`) — typable on international layouts.
/// - `© ® ™ § ¶ † ‡ ° €` — intentional symbols, not AI residue.
/// - `U+200C` ZWNJ and `U+200D` ZWJ — load-bearing in Persian, Hindi and in
///   emoji sequences such as 👨‍👩‍👧.
/// - `U+200E` LRM / `U+200F` RLM — real formatting in mixed right-to-left text.
/// - CJK punctuation (`。、「」`) and fullwidth forms other than the quote
///   and hyphen variants below.
/// - `U+FFFD` REPLACEMENT CHARACTER — it signals data loss, so it should stay visible.
public enum Replacements {

    /// Every rule, in table order.
    /// The built-in rule for a pattern, where there is one. Names and
    /// families come from here, so changing what a character becomes never
    /// changes what it is called.
    public static func builtIn(_ pattern: Pattern) -> Replacement? {
        byPattern[pattern]
    }

    private static let byPattern: [Pattern: Replacement] =
        Dictionary(all.map { ($0.pattern, $0) }, uniquingKeysWith: { first, _ in first })

    public static let all: [Replacement] =
        quotes + dashes + punctuation + spaces + invisibles + bullets + symbols

    // MARK: - Quotes and apostrophes

    public static let quotes: [Replacement] = [
        Replacement(0x2018, "'", "LEFT SINGLE QUOTATION MARK", .quotes),
        Replacement(0x2019, "'", "RIGHT SINGLE QUOTATION MARK", .quotes),
        Replacement(0x201A, "'", "SINGLE LOW-9 QUOTATION MARK", .quotes),
        Replacement(0x201B, "'", "SINGLE HIGH-REVERSED-9 QUOTATION MARK", .quotes),
        Replacement(0x201C, "\"", "LEFT DOUBLE QUOTATION MARK", .quotes),
        Replacement(0x201D, "\"", "RIGHT DOUBLE QUOTATION MARK", .quotes),
        Replacement(0x201E, "\"", "DOUBLE LOW-9 QUOTATION MARK", .quotes),
        Replacement(0x201F, "\"", "DOUBLE HIGH-REVERSED-9 QUOTATION MARK", .quotes),
        Replacement(0x00AB, "\"", "LEFT-POINTING DOUBLE ANGLE QUOTATION MARK", .quotes),
        Replacement(0x00BB, "\"", "RIGHT-POINTING DOUBLE ANGLE QUOTATION MARK", .quotes),
        Replacement(0x2039, "'", "SINGLE LEFT-POINTING ANGLE QUOTATION MARK", .quotes),
        Replacement(0x203A, "'", "SINGLE RIGHT-POINTING ANGLE QUOTATION MARK", .quotes),
        Replacement(0x2032, "'", "PRIME", .quotes),
        Replacement(0x2033, "\"", "DOUBLE PRIME", .quotes),
        Replacement(0x2034, "'''", "TRIPLE PRIME", .quotes),
        Replacement(0x2035, "'", "REVERSED PRIME", .quotes),
        Replacement(0x2036, "\"", "REVERSED DOUBLE PRIME", .quotes),
        Replacement(0x2037, "'''", "REVERSED TRIPLE PRIME", .quotes),
        Replacement(0x00B4, "'", "ACUTE ACCENT", .quotes),
        Replacement(0x02B9, "'", "MODIFIER LETTER PRIME", .quotes),
        Replacement(0x02BA, "\"", "MODIFIER LETTER DOUBLE PRIME", .quotes),
        Replacement(0x02BB, "'", "MODIFIER LETTER TURNED COMMA", .quotes),
        Replacement(0x02BC, "'", "MODIFIER LETTER APOSTROPHE", .quotes),
        Replacement(0x02BD, "'", "MODIFIER LETTER REVERSED COMMA", .quotes),
        Replacement(0x02C8, "'", "MODIFIER LETTER VERTICAL LINE", .quotes),
        Replacement(0x02DD, "\"", "DOUBLE ACUTE ACCENT", .quotes),
        Replacement(0x275B, "'", "HEAVY SINGLE TURNED COMMA QUOTATION MARK ORNAMENT", .quotes),
        Replacement(0x275C, "'", "HEAVY SINGLE COMMA QUOTATION MARK ORNAMENT", .quotes),
        Replacement(0x275D, "\"", "HEAVY DOUBLE TURNED COMMA QUOTATION MARK ORNAMENT", .quotes),
        Replacement(0x275E, "\"", "HEAVY DOUBLE COMMA QUOTATION MARK ORNAMENT", .quotes),
        Replacement(0x301D, "\"", "REVERSED DOUBLE PRIME QUOTATION MARK", .quotes),
        Replacement(0x301E, "\"", "DOUBLE PRIME QUOTATION MARK", .quotes),
        Replacement(0xFF02, "\"", "FULLWIDTH QUOTATION MARK", .quotes),
        Replacement(0xFF07, "'", "FULLWIDTH APOSTROPHE", .quotes),
    ]

    // MARK: - Dashes and hyphens

    public static let dashes: [Replacement] = [
        Replacement(0x2010, "-", "HYPHEN", .dashes),
        Replacement(0x2011, "-", "NON-BREAKING HYPHEN", .dashes),
        Replacement(0x2012, "-", "FIGURE DASH", .dashes),
        Replacement(0x2013, "-", "EN DASH", .dashes),
        Replacement(0x2014, "--", "EM DASH", .dashes),
        Replacement(0x2015, "--", "HORIZONTAL BAR", .dashes),
        Replacement(0x2212, "-", "MINUS SIGN", .dashes),
        Replacement(0x2E3A, "---", "TWO-EM DASH", .dashes),
        Replacement(0x2E3B, "----", "THREE-EM DASH", .dashes),
        Replacement(0xFE58, "-", "SMALL EM DASH", .dashes),
        Replacement(0xFE63, "-", "SMALL HYPHEN-MINUS", .dashes),
        Replacement(0xFF0D, "-", "FULLWIDTH HYPHEN-MINUS", .dashes),
    ]

    // MARK: - Punctuation

    public static let punctuation: [Replacement] = [
        Replacement(0x2024, ".", "ONE DOT LEADER", .punctuation),
        Replacement(0x2025, "..", "TWO DOT LEADER", .punctuation),
        Replacement(0x2026, "...", "HORIZONTAL ELLIPSIS", .punctuation),
        Replacement(0x22EF, "...", "MIDLINE HORIZONTAL ELLIPSIS", .punctuation),
        Replacement(0x203C, "!!", "DOUBLE EXCLAMATION MARK", .punctuation),
        Replacement(0x203D, "?!", "INTERROBANG", .punctuation),
        Replacement(0x2047, "??", "DOUBLE QUESTION MARK", .punctuation),
        Replacement(0x2048, "?!", "QUESTION EXCLAMATION MARK", .punctuation),
        Replacement(0x2049, "!?", "EXCLAMATION QUESTION MARK", .punctuation),
        Replacement(0x2044, "/", "FRACTION SLASH", .punctuation),
        Replacement(0x2016, "||", "DOUBLE VERTICAL LINE", .punctuation),
        Replacement(0x2017, "_", "DOUBLE LOW LINE", .punctuation),
    ]

    // MARK: - Spaces

    public static let spaces: [Replacement] = [
        Replacement(0x00A0, " ", "NO-BREAK SPACE", .spaces),
        Replacement(0x1680, " ", "OGHAM SPACE MARK", .spaces),
        Replacement(0x2000, " ", "EN QUAD", .spaces),
        Replacement(0x2001, " ", "EM QUAD", .spaces),
        Replacement(0x2002, " ", "EN SPACE", .spaces),
        Replacement(0x2003, " ", "EM SPACE", .spaces),
        Replacement(0x2004, " ", "THREE-PER-EM SPACE", .spaces),
        Replacement(0x2005, " ", "FOUR-PER-EM SPACE", .spaces),
        Replacement(0x2006, " ", "SIX-PER-EM SPACE", .spaces),
        Replacement(0x2007, " ", "FIGURE SPACE", .spaces),
        Replacement(0x2008, " ", "PUNCTUATION SPACE", .spaces),
        Replacement(0x2009, " ", "THIN SPACE", .spaces),
        Replacement(0x200A, " ", "HAIR SPACE", .spaces),
        Replacement(0x202F, " ", "NARROW NO-BREAK SPACE", .spaces),
        Replacement(0x205F, " ", "MEDIUM MATHEMATICAL SPACE", .spaces),
        Replacement(0x3000, " ", "IDEOGRAPHIC SPACE", .spaces),
    ]

    // MARK: - Invisible characters (deleted)

    public static let invisibles: [Replacement] = [
        Replacement(0x00AD, "", "SOFT HYPHEN", .invisibles),
        Replacement(0x034F, "", "COMBINING GRAPHEME JOINER", .invisibles),
        Replacement(0x180E, "", "MONGOLIAN VOWEL SEPARATOR", .invisibles),
        Replacement(0x200B, "", "ZERO WIDTH SPACE", .invisibles),
        Replacement(0x202A, "", "LEFT-TO-RIGHT EMBEDDING", .invisibles),
        Replacement(0x202B, "", "RIGHT-TO-LEFT EMBEDDING", .invisibles),
        Replacement(0x202C, "", "POP DIRECTIONAL FORMATTING", .invisibles),
        Replacement(0x202D, "", "LEFT-TO-RIGHT OVERRIDE", .invisibles),
        Replacement(0x202E, "", "RIGHT-TO-LEFT OVERRIDE", .invisibles),
        Replacement(0x2060, "", "WORD JOINER", .invisibles),
        Replacement(0x2061, "", "FUNCTION APPLICATION", .invisibles),
        Replacement(0x2062, "", "INVISIBLE TIMES", .invisibles),
        Replacement(0x2063, "", "INVISIBLE SEPARATOR", .invisibles),
        Replacement(0x2064, "", "INVISIBLE PLUS", .invisibles),
        Replacement(0x2066, "", "LEFT-TO-RIGHT ISOLATE", .invisibles),
        Replacement(0x2067, "", "RIGHT-TO-LEFT ISOLATE", .invisibles),
        Replacement(0x2068, "", "FIRST STRONG ISOLATE", .invisibles),
        Replacement(0x2069, "", "POP DIRECTIONAL ISOLATE", .invisibles),
        Replacement(0x206A, "", "INHIBIT SYMMETRIC SWAPPING", .invisibles),
        Replacement(0x206B, "", "ACTIVATE SYMMETRIC SWAPPING", .invisibles),
        Replacement(0x206C, "", "INHIBIT ARABIC FORM SHAPING", .invisibles),
        Replacement(0x206D, "", "ACTIVATE ARABIC FORM SHAPING", .invisibles),
        Replacement(0x206E, "", "NATIONAL DIGIT SHAPES", .invisibles),
        Replacement(0x206F, "", "NOMINAL DIGIT SHAPES", .invisibles),
        Replacement(0xFFF9, "", "INTERLINEAR ANNOTATION ANCHOR", .invisibles),
        Replacement(0xFFFA, "", "INTERLINEAR ANNOTATION SEPARATOR", .invisibles),
        Replacement(0xFFFB, "", "INTERLINEAR ANNOTATION TERMINATOR", .invisibles),
        Replacement(0xFFFC, "", "OBJECT REPLACEMENT CHARACTER", .invisibles),
        Replacement(0xFEFF, "", "ZERO WIDTH NO-BREAK SPACE (BOM)", .invisibles),
        // Invisible, carry no text, and the usual vehicle for smuggling hidden
        // instructions inside copied text, so the whole block goes.
        Replacement(tagCharacters, "", "TAG CHARACTERS", .invisibles),
    ]

    /// The Unicode tag block, deleted wholesale.
    public static let tagCharacters: ClosedRange<UInt32> = 0xE0000...0xE007F

    /// A messy sample exercising most of the table, behind the Help window's
    /// "Try it" button and used by the tests.
    public static let sampleText = """
        \u{201C}It\u{2019}s fine,\u{201D} she said\u{2014}then paused\u{2026}
        \u{2022} caf\u{e9} \u{ab}na\u{ef}ve\u{bb} \u{2248} 3\u{d7}4 \u{2192} 12
        \u{a0}Zero-width\u{200b}and\u{feff}bidi\u{202e} junk\u{202c} gone.
        """

    // MARK: - List bullets

    public static let bullets: [Replacement] = [
        Replacement(0x2022, "-", "BULLET", .bullets),
        Replacement(0x2023, "-", "TRIANGULAR BULLET", .bullets),
        Replacement(0x2043, "-", "HYPHEN BULLET", .bullets),
        Replacement(0x2219, "-", "BULLET OPERATOR", .bullets),
        Replacement(0x25AA, "-", "BLACK SMALL SQUARE", .bullets),
        Replacement(0x25AB, "-", "WHITE SMALL SQUARE", .bullets),
        Replacement(0x25B8, "-", "BLACK RIGHT-POINTING SMALL TRIANGLE", .bullets),
        Replacement(0x25B9, "-", "WHITE RIGHT-POINTING SMALL TRIANGLE", .bullets),
        Replacement(0x25CB, "-", "WHITE CIRCLE", .bullets),
        Replacement(0x25CF, "-", "BLACK CIRCLE", .bullets),
        Replacement(0x25E6, "-", "WHITE BULLET", .bullets),
    ]

    // MARK: - Math and arrows

    public static let symbols: [Replacement] = [
        Replacement(0x00D7, "x", "MULTIPLICATION SIGN", .symbols),
        Replacement(0x00F7, "/", "DIVISION SIGN", .symbols),
        Replacement(0x00B1, "+/-", "PLUS-MINUS SIGN", .symbols),
        Replacement(0x2215, "/", "DIVISION SLASH", .symbols),
        Replacement(0x2216, "\\", "SET MINUS", .symbols),
        Replacement(0x2217, "*", "ASTERISK OPERATOR", .symbols),
        Replacement(0x2248, "~", "ALMOST EQUAL TO", .symbols),
        Replacement(0x2260, "!=", "NOT EQUAL TO", .symbols),
        Replacement(0x2264, "<=", "LESS-THAN OR EQUAL TO", .symbols),
        Replacement(0x2265, ">=", "GREATER-THAN OR EQUAL TO", .symbols),
        Replacement(0x2190, "<-", "LEFTWARDS ARROW", .symbols),
        Replacement(0x2192, "->", "RIGHTWARDS ARROW", .symbols),
        Replacement(0x2194, "<->", "LEFT RIGHT ARROW", .symbols),
        Replacement(0x21D0, "<=", "LEFTWARDS DOUBLE ARROW", .symbols),
        Replacement(0x21D2, "=>", "RIGHTWARDS DOUBLE ARROW", .symbols),
        Replacement(0x21D4, "<=>", "LEFT RIGHT DOUBLE ARROW", .symbols),
    ]
}
