//
//  RTFSyntax.swift
//  PasteBopCore
//

import Foundation

/// The pieces of RTF the rewriter has to recognise: control words, the
/// characters spelled as words, the destinations that are not document text,
/// and the code pages a `\'hh` byte is read in.
enum RTFSyntax {

    static let backslash = UInt8(ascii: "\\")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let space = UInt8(ascii: " ")

    struct ControlWord {
        let nameStart: Int
        let nameLength: Int
        let parameter: Int?
        /// Past the word, its parameter, and the space delimiter if there was one.
        let end: Int
        let spaceDelimited: Bool
    }

    /// The control word whose backslash is at `start`. The byte after the
    /// backslash is known to be a letter.
    static func controlWord(in source: UnsafeBufferPointer<UInt8>, at start: Int) -> ControlWord {
        let count = source.count
        var cursor = start + 1
        while cursor < count, isLetter(source[cursor]) { cursor += 1 }
        let nameEnd = cursor

        var parameter: Int?
        let negative = cursor < count && source[cursor] == UInt8(ascii: "-")
        if negative { cursor += 1 }
        var magnitude = 0
        var digits = 0
        while cursor < count, isDigit(source[cursor]), digits < 10 {
            magnitude = magnitude * 10 + Int(source[cursor] - UInt8(ascii: "0"))
            cursor += 1
            digits += 1
        }
        if digits > 0 {
            parameter = negative ? -magnitude : magnitude
        } else if negative {
            // A minus with no digits is text, not a parameter.
            cursor -= 1
        }

        let spaceDelimited = cursor < count && source[cursor] == space
        return ControlWord(
            nameStart: start + 1,
            nameLength: nameEnd - (start + 1),
            parameter: parameter,
            end: spaceDelimited ? cursor + 1 : cursor,
            spaceDelimited: spaceDelimited
        )
    }

    static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    /// Whether the `length` bytes at `start` spell `name`.
    static func word(
        _ source: UnsafeBufferPointer<UInt8>,
        _ start: Int,
        _ length: Int,
        is name: StaticString
    ) -> Bool {
        guard name.utf8CodeUnitCount == length else { return false }
        let expected = name.utf8Start
        for offset in 0..<length where source[start + offset] != expected[offset] { return false }
        return true
    }

    // MARK: - Characters spelled as words

    private static let namedCharacters: [(name: StaticString, scalar: UInt32)] = [
        ("emdash", 0x2014), ("endash", 0x2013),
        ("lquote", 0x2018), ("rquote", 0x2019), ("ldblquote", 0x201C), ("rdblquote", 0x201D),
        ("bullet", 0x2022), ("emspace", 0x2003), ("enspace", 0x2002), ("qmspace", 0x2005),
        ("zwbo", 0x200B), ("zwnbo", 0xFEFF), ("zwj", 0x200D), ("zwnj", 0x200C),
        ("ltrmark", 0x200E), ("rtlmark", 0x200F),
    ]

    static func namedCharacter(_ source: UnsafeBufferPointer<UInt8>, _ word: ControlWord) -> UInt32? {
        guard word.nameLength >= 3, word.nameLength <= 9 else { return nil }
        for entry in namedCharacters
        where Self.word(source, word.nameStart, word.nameLength, is: entry.name) {
            return entry.scalar
        }
        return nil
    }

    // MARK: - Destinations

    /// Groups whose contents are not document text.
    private static let skippedDestinations: [StaticString] = [
        "colortbl", "stylesheet", "info", "pict", "object", "listtext", "pntext",
        "themedata", "datastore", "xmlnstbl", "listtable", "listoverridetable", "rsidtbl",
        "generator", "latentstyles", "colorschememapping", "filetbl", "revtbl", "fldinst",
    ]

    enum Destination {
        case fontTable
        case skipped
    }

    /// What the group opening at `start` holds, if it is one the rewriter
    /// must leave alone. `\*` marks a destination readers may ignore when
    /// they do not know it, which is every destination this does not know.
    static func destination(in source: UnsafeBufferPointer<UInt8>, ofGroupAt start: Int) -> Destination? {
        let cursor = start + 1
        guard cursor + 1 < source.count, source[cursor] == backslash else { return nil }
        if source[cursor + 1] == UInt8(ascii: "*") { return .skipped }
        guard isLetter(source[cursor + 1]) else { return nil }
        let word = controlWord(in: source, at: cursor)
        if Self.word(source, word.nameStart, word.nameLength, is: "fonttbl") { return .fontTable }
        for name in skippedDestinations where Self.word(source, word.nameStart, word.nameLength, is: name) {
            return .skipped
        }
        return nil
    }

    /// Index just past the `}` closing the group opened at `start`.
    static func endOfGroup(in source: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        let count = source.count
        var depth = 0
        var cursor = start
        while cursor < count {
            switch source[cursor] {
            case openBrace:
                depth += 1
                cursor += 1
            case closeBrace:
                depth -= 1
                cursor += 1
                if depth <= 0 { return cursor }
            case backslash:
                guard cursor + 1 < count else { return count }
                guard isLetter(source[cursor + 1]) else { cursor += 2; continue }
                let word = controlWord(in: source, at: cursor)
                cursor = word.end
                // `\binN` is followed by N raw bytes, braces included.
                if Self.word(source, word.nameStart, word.nameLength, is: "bin") {
                    cursor = min(count, cursor + max(0, word.parameter ?? 0))
                }
            default:
                cursor += 1
            }
        }
        return count
    }

    // MARK: - Fonts

    struct Font {
        var charset: Int?
        var codePage: Int?
    }

    /// The `\fcharset` and `\cpg` of each font declared in the table at `start`.
    static func fonts(
        in source: UnsafeBufferPointer<UInt8>,
        tableFrom start: Int,
        to end: Int
    ) -> [Int: Font] {
        var fonts: [Int: Font] = [:]
        var current: Int?
        var cursor = start
        while cursor < end {
            guard source[cursor] == backslash else { cursor += 1; continue }
            guard cursor + 1 < end, isLetter(source[cursor + 1]) else { cursor += 2; continue }
            let word = controlWord(in: source, at: cursor)
            cursor = word.end
            guard let parameter = word.parameter else { continue }
            if Self.word(source, word.nameStart, word.nameLength, is: "f") {
                current = parameter
            } else if let current, Self.word(source, word.nameStart, word.nameLength, is: "fcharset") {
                fonts[current, default: Font()].charset = parameter
            } else if let current, Self.word(source, word.nameStart, word.nameLength, is: "cpg") {
                fonts[current, default: Font()].codePage = parameter
            }
        }
        return fonts
    }
}

/// The single-byte code pages a `\'hh` byte is read in. Any other, every
/// double-byte one included, leaves the byte alone.
enum RTFCodePage: Sendable {
    case windows1252
    case macRoman
    case unknown

    init(windows number: Int) {
        switch number {
        case 1252: self = .windows1252
        case 10000: self = .macRoman
        default: self = .unknown
        }
    }

    /// A font's own code page wins; otherwise its charset decides, and an
    /// ANSI charset defers to the document's.
    init(font: RTFSyntax.Font?, document: Self) {
        if let number = font?.codePage {
            self.init(windows: number)
            return
        }
        switch font?.charset ?? 0 {
        case 0, 1: self = document
        case 77: self = .macRoman
        default: self = .unknown
        }
    }

    func scalar(for byte: UInt8) -> UInt32? {
        switch self {
        case .windows1252: byte < 0x80 ? UInt32(byte) : Self.windows1252Upper[Int(byte - 0x80)]
        case .macRoman: byte < 0x80 ? UInt32(byte) : Self.macRomanUpper[Int(byte - 0x80)]
        case .unknown: nil
        }
    }

    private static let windows1252Upper = upperHalf(of: .windowsCP1252)
    private static let macRomanUpper = upperHalf(of: .macOSRoman)

    private static func upperHalf(of encoding: String.Encoding) -> [UInt32?] {
        (0x80...0xFF).map { String(bytes: [UInt8($0)], encoding: encoding)?.unicodeScalars.first?.value }
    }
}
