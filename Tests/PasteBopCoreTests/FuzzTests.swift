//
//  FuzzTests.swift
//  PasteBopCoreTests
//
//  The rules file is user-controlled input and the scanner walks raw bytes.
//  These throw deterministic garbage at both and assert the only acceptable
//  outcomes: a result, or a ParseError. Never a crash, never a read past the
//  end, never a different error type.
//

import AppKit
import Foundation
import Testing
@testable import PasteBopCore

/// Reproducible randomness, so a failure can be replayed from its seed.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

private enum Fuzz {
    /// `randomElement` returns an optional the arrays here can never produce.
    static func pick<T>(_ options: [T], _ rng: inout SeededGenerator) -> T {
        options[Int.random(in: 0..<options.count, using: &rng)]
    }

    /// Scalars from the neighbourhoods that matter: ASCII, Latin-1, the
    /// punctuation block, CJK, invisibles, and outside the BMP.
    static let interestingScalars: [UInt32] = [
        0x20, 0x41, 0x7F, 0xA0, 0xAB, 0xE9, 0xFF,
        0x2013, 0x2014, 0x2019, 0x201C, 0x2026, 0x200B, 0x200D, 0x202E,
        0x3000, 0x4E00, 0x65E5,
        0x1F600, 0x1F468, 0xE0041, 0x10FFFF,
    ]

    static func scalar(_ rng: inout SeededGenerator) -> Unicode.Scalar {
        if Bool.random(using: &rng) {
            return Unicode.Scalar(pick(interestingScalars, &rng)) ?? " "
        }
        // Any valid scalar at all, surrogates excluded by the initialiser.
        while true {
            if let scalar = Unicode.Scalar(UInt32.random(in: 0...0x10FFFF, using: &rng)) {
                return scalar
            }
        }
    }

    static func text(_ rng: inout SeededGenerator, length: Int) -> String {
        var view = String.UnicodeScalarView()
        for _ in 0..<length { view.append(scalar(&rng)) }
        return String(view)
    }

    static func bytes(_ rng: inout SeededGenerator, length: Int) -> String {
        // Random bytes repaired into whatever string they make is exactly the
        // garbage wanted here, so the repairing initialiser is deliberate.
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }, as: UTF8.self)
    }

    /// A rule set with the shapes a user could write: scalars, ranges,
    /// substrings (some ASCII-leading), outputs including markup and nothing.
    static func rules(_ rng: inout SeededGenerator) -> RewriteRules {
        let outputs = ["", "-", "--", "<", "&", "<b>", "x", " ", "\"", "\\", "abc"]
        var replacements: [Replacement] = []
        for _ in 0..<Int.random(in: 0...12, using: &rng) {
            let output = pick(outputs, &rng)
            // Qualified: AppKit and Testing both surface a Pattern of their own.
            let pattern: PasteBopCore.Pattern
            switch Int.random(in: 0...3, using: &rng) {
            case 0:
                let value = pick(interestingScalars.filter { $0 >= 0xA0 }, &rng)
                pattern = .scalars(value...value)
            case 1:
                let lower = UInt32.random(in: 0xA0...0x2100, using: &rng)
                pattern = .scalars(lower...(lower + UInt32.random(in: 0...600, using: &rng)))
            default:
                let count = Int.random(in: 2...4, using: &rng)
                pattern = .sequence((0..<count).map { _ in pick(interestingScalars, &rng) })
            }
            replacements.append(Replacement(pattern: pattern, output: output, name: "F", category: .custom))
        }
        return RewriteRules(replacements)
    }
}

@Suite("Fuzz")
struct FuzzTests {

    @Test("The parser never crashes and only ever throws ParseError", arguments: 0..<200)
    func parserSurvivesGarbage(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed))
        let document: String
        switch seed % 4 {
        case 0: document = Fuzz.bytes(&rng, length: Int.random(in: 0...400, using: &rng))
        case 1: document = Fuzz.text(&rng, length: Int.random(in: 0...200, using: &rng))
        case 2:
            // Mutate a valid file: the most likely real-world breakage.
            var lines = RuleFile.encode(.builtIn).components(separatedBy: "\n")
            for _ in 0..<Int.random(in: 1...5, using: &rng) {
                let line = Int.random(in: 0..<lines.count, using: &rng)
                let position = Int.random(in: 0...lines[line].count, using: &rng)
                let at = lines[line].index(lines[line].startIndex, offsetBy: position)
                lines[line].insert(contentsOf: Fuzz.text(&rng, length: 1), at: at)
            }
            document = lines.joined(separator: "\n")
        default:
            document = "version: 1\nrules:\n" + (0..<Int.random(in: 0...30, using: &rng)).map { _ in
                "  " + Fuzz.text(&rng, length: Int.random(in: 0...20, using: &rng))
            }.joined(separator: "\n")
        }

        do {
            _ = try RuleFile.decode(document)
        } catch is RuleFile.ParseError {
            // The only acceptable failure.
        } catch {
            Issue.record("seed \(seed): unexpected error type \(type(of: error))")
        }
    }

    @Test("The scanner never crashes and never reads past the end", arguments: 0..<300)
    func scannerSurvivesAnything(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed) &+ 1000)
        let rules = Fuzz.rules(&rng)
        let input = Fuzz.text(&rng, length: Int.random(in: 0...64, using: &rng))

        let plain = TextNormalizer.normalize(input, rules: rules)
        let html = TextNormalizer.normalize(input, rules: rules, escaping: .html)
        let tally = TextNormalizer.tally(input, rules: rules)
        _ = HTMLTextRewriter.rewrite("<p title=\"\(input)\">\(input)</p><!-- \(input) -->", rules: rules)

        // Output is bounded: at most every scalar replaced by the longest output.
        let longest = rules.replacements.map { $0.output.unicodeScalars.count }.max() ?? 0
        if let plain {
            #expect(plain.unicodeScalars.count <= input.unicodeScalars.count * max(1, longest) + 1)
        }
        // HTML mode only differs by escaping, never by what was matched.
        #expect((plain == nil) == (html == nil))
        // Nothing to rewrite means nothing counted, and vice versa.
        #expect((plain == nil) == tally.isEmpty)
    }

    @Test("Plain and attributed text always agree", arguments: 0..<150)
    func attributedMatchesPlain(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed) &+ 5000)
        let rules = Fuzz.rules(&rng)
        let input = Fuzz.text(&rng, length: Int.random(in: 0...48, using: &rng))

        let plain = TextNormalizer.normalize(input, rules: rules)
        let attributed = TextNormalizer.normalize(NSAttributedString(string: input), rules: rules)

        // Both paths share one scanner; a disagreement means the UTF-16
        // offset translation is wrong.
        #expect(attributed?.string == plain, "seed \(seed)")
    }

    @Test("RTF and plain text always agree", arguments: 0..<120)
    func rtfMatchesPlain(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed) &+ 7000)
        let rules = Fuzz.rules(&rng)
        // AppKit's RTF reader silently drops the bidi override, so a document
        // holding one cannot be compared through it.
        var input = Fuzz.text(&rng, length: Int.random(in: 1...48, using: &rng))
        input.unicodeScalars.removeAll { $0.value == 0x202E }

        // Styling every other few characters puts control words between the
        // escapes, which is where a splice can go wrong. Chunked by scalar, so
        // a style change never lands inside a surrogate pair.
        let styled = NSMutableAttributedString(string: input)
        let bold = NSFont.boldSystemFont(ofSize: 12)
        var scalars = input.unicodeScalars[...]
        var location = 0
        var isBold = false
        while !scalars.isEmpty {
            let chunk = scalars.prefix(Int.random(in: 1...5, using: &rng))
            let length = chunk.reduce(0) { $0 + $1.utf16.count }
            if isBold {
                styled.addAttribute(.font, value: bold, range: NSRange(location: location, length: length))
            }
            location += length
            scalars = scalars.dropFirst(chunk.count)
            isBold.toggle()
        }
        let whole = NSRange(location: 0, length: styled.length)
        guard let rtf = styled.rtf(from: whole, documentAttributes: [:]),
              NSAttributedString(rtf: rtf, documentAttributes: nil)?.string == input else {
            return  // AppKit did not round-trip the sample; nothing to compare against.
        }

        let expected = TextNormalizer.normalized(input, rules: rules)
        let rewritten = RTFTextRewriter.rewrite(rtf, rules: rules)
        let actual = rewritten.flatMap { NSAttributedString(rtf: $0, documentAttributes: nil)?.string }
        #expect((actual ?? input) == expected, "seed \(seed)")
    }

    @Test("The RTF rewriter never crashes", arguments: 0..<200)
    func rtfSurvivesGarbage(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed) &+ 9000)
        let rules = Fuzz.rules(&rng)
        let fragments = [
            "{", "}", "\\", "\\'93", "\\'9", "\\'zz", "\\u8220 ", "\\u-10179 ", "\\u55357 ", "\\uc1", "\\uc0",
            "\\f1", "\\f0 ", "\\bin3 abc", "\\bin999", "\\emdash", "\\~", "\\*", "\\fonttbl", "\\fcharset128",
            "\\dbch", "\\loch", "\\pard", "\\par", "\\ansicpg932", "\\mac", "text", " ", "\r\n", "\\{", "\\}",
            "{\\*\\x", "{\\pict", "{\\fonttbl{\\f0\\fcharset0 A;}}",
        ]
        var document = seed.isMultiple(of: 2) ? "{\\rtf1\\ansi" : ""
        for _ in 0..<Int.random(in: 0...40, using: &rng) {
            document += Bool.random(using: &rng) ? Fuzz.pick(fragments, &rng) : Fuzz.bytes(&rng, length: 3)
        }
        _ = RTFTextRewriter.rewrite(Data(document.utf8), rules: rules)
        _ = RTFTextRewriter.rewrite(Data((0..<Int.random(in: 0...64, using: &rng)).map { _ in
            UInt8.random(in: 0...255, using: &rng)
        }), rules: rules)
    }

    @Test("A rewrite is never applied twice to its own output when rules are self-stable")
    func builtInIsIdempotentUnderFuzz() {
        var rng = SeededGenerator(seed: 42)
        for _ in 0..<100 {
            let input = Fuzz.text(&rng, length: Int.random(in: 0...64, using: &rng))
            let once = TextNormalizer.normalized(input)
            #expect(TextNormalizer.normalize(once) == nil)
        }
    }
}
