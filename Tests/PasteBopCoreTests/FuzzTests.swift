//
//  FuzzTests.swift
//  PasteBopCoreTests
//
//  The rules file is user-controlled input and the scanner walks raw bytes.
//  These throw deterministic garbage at both and assert the only acceptable
//  outcomes: a result, or a ParseError. Never a crash, never a read past the
//  end, never a different error type.
//

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
            let pattern: Pattern
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
