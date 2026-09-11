//
//  TextNormalizerTests.swift
//  PasteBopCoreTests
//

import Foundation
import Testing
@testable import PasteBopCore

@Suite("Text normalizer")
struct TextNormalizerTests {

    // MARK: - Rewrites

    @Test("Rewrites typographic characters", arguments: [
        ("\u{201C}Hello\u{201D}", "\"Hello\""),
        ("it\u{2019}s", "it's"),
        ("\u{201A}low\u{2018} and \u{201E}low\u{201C}", "'low' and \"low\""),
        ("\u{ab}guillemets\u{bb}", "\"guillemets\""),
        ("\u{2039}single\u{203a}", "'single'"),
        ("5\u{2032}9\u{2033}", "5'9\""),
        ("wait\u{2014}no", "wait--no"),
        ("2010\u{2013}2024", "2010-2024"),
        ("and so on\u{2026}", "and so on..."),
        ("a\u{a0}b", "a b"),
        ("thin\u{2009}space", "thin space"),
        ("\u{2022} item", "- item"),
        ("\u{25e6} nested", "- nested"),
        ("3\u{d7}4", "3x4"),
        ("x \u{2260} y", "x != y"),
        ("a \u{2192} b", "a -> b"),
        ("p \u{21d2} q", "p => q"),
        ("\u{2264}5", "<=5"),
        ("10\u{b1}1", "10+/-1"),
    ])
    func rewrites(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test("Deletes invisible characters", arguments: [
        "zero\u{200b}width",
        "bom\u{feff}here",
        "soft\u{ad}hyphen",
        "joined\u{2060}word",
        "override\u{202e}text\u{202c}",
        "isolate\u{2066}text\u{2069}",
        "tag\u{e0041}smuggle",
    ])
    func deletesInvisibles(_ input: String) {
        let result = TextNormalizer.normalized(input)
        #expect(result.allSatisfy { $0.isASCII })
        #expect(result.unicodeScalars.allSatisfy { $0.value < 0x80 })
    }

    // MARK: - Pass-through

    @Test("Leaves plain ASCII untouched", arguments: [
        "",
        "hello world",
        "let x = \"quoted\"; // it's fine",
        "https://example.com/a?b=1&c=2",
        "a - b -- c ... 'x' \"y\"",
    ])
    func asciiUnchanged(_ input: String) {
        #expect(TextNormalizer.normalize(input) == nil)
        #expect(TextNormalizer.needsRewrite(input) == false)
    }

    @Test("Leaves meaningful non-ASCII untouched", arguments: [
        "café naïve Ötzi Ångström",
        "Приве́т мир",
        "日本語のテキストです。",
        "مرحبا بالعالم",
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",  // family emoji, joined by ZWJ
        "میروم",                                        // Persian, needs ZWNJ
        "100 € · 50 £ © 2024",
    ])
    func meaningfulTextUnchanged(_ input: String) {
        #expect(TextNormalizer.normalize(input) == nil, "rewrote \(input)")
    }

    // MARK: - Properties

    @Test("Normalising is idempotent")
    func idempotent() {
        let once = TextNormalizer.normalized(Replacements.sampleText)
        #expect(TextNormalizer.normalize(once) == nil)
    }

    @Test("Handles a rewrite at either end")
    func boundaries() {
        #expect(TextNormalizer.normalize("\u{2026}tail") == "...tail")
        #expect(TextNormalizer.normalize("head\u{2026}") == "head...")
        #expect(TextNormalizer.normalize("\u{2026}") == "...")
        #expect(TextNormalizer.normalize("\u{2026}\u{2026}") == "......")
    }

    @Test("Rewrites next to a surrogate pair")
    func nextToAstralScalar() {
        #expect(TextNormalizer.normalize("\u{1F600}\u{2014}\u{1F600}") == "\u{1F600}--\u{1F600}")
    }

    @Test("The sample text reduces to keyboard characters")
    func sampleText() {
        let result = TextNormalizer.normalized(Replacements.sampleText)
        // café and naïve keep their accents; nothing else survives.
        let leftovers = Set(result.unicodeScalars.filter { $0.value > 0x7F })
        #expect(leftovers == Set("\u{e9}\u{ef}".unicodeScalars))
    }

    // MARK: - Attributed text

    @Test("Keeps attributes across a rewrite")
    func attributedStringKeepsAttributes() throws {
        let input = NSMutableAttributedString(string: "a \u{201C}b\u{201D} c")
        input.addAttribute(.init("mark"), value: 1, range: NSRange(location: 2, length: 3))

        let result = try #require(TextNormalizer.normalize(input))
        #expect(result.string == "a \"b\" c")

        var range = NSRange()
        let value = result.attribute(.init("mark"), at: 2, effectiveRange: &range) as? Int
        #expect(value == 1)
        #expect(range == NSRange(location: 2, length: 3))
    }

    @Test("Attributed rewrite that changes length keeps later attributes aligned")
    func attributedStringShiftsRanges() throws {
        // The em dash becomes two characters, so everything after it moves.
        let input = NSMutableAttributedString(string: "x\u{2014}tail")
        input.addAttribute(.init("mark"), value: 1, range: NSRange(location: 2, length: 4))

        let result = try #require(TextNormalizer.normalize(input))
        #expect(result.string == "x--tail")

        var range = NSRange()
        _ = result.attribute(.init("mark"), at: 3, effectiveRange: &range)
        #expect(range == NSRange(location: 3, length: 4))
    }

    @Test("Attributed text with nothing to fix returns nil")
    func attributedStringUnchanged() {
        #expect(TextNormalizer.normalize(NSAttributedString(string: "plain ascii")) == nil)
        #expect(TextNormalizer.normalize(NSAttributedString(string: "café")) == nil)
    }

    // MARK: - Throughput

    @Test("Stays fast on a large clipboard", .timeLimit(.minutes(1)))
    func throughput() {
        let paragraph = "The \u{201C}quick\u{201D} brown fox\u{2014}jumped\u{2026} over caf\u{e9}. "
        let input = String(repeating: paragraph, count: 20_000)  // about 1.2 MB
        let started = ContinuousClock.now
        let result = TextNormalizer.normalize(input)
        let elapsed = ContinuousClock.now - started

        #expect(result != nil)
        print("normalize: \(input.utf8.count.formatted()) bytes in \(elapsed)")
        // A tripwire, not a benchmark. Release builds run this in about 3 ms
        // and debug in about 30 ms, so the bound catches a collapse of the
        // byte scanner without failing on a loaded CI runner.
        #expect(elapsed < .milliseconds(500))
    }

    @Test("The ASCII fast path avoids work entirely", .timeLimit(.minutes(1)))
    func asciiThroughput() {
        let input = String(repeating: "let value = compute(a, b) // plain ascii source\n", count: 40_000)
        let started = ContinuousClock.now
        let result = TextNormalizer.normalize(input)
        let elapsed = ContinuousClock.now - started

        #expect(result == nil)
        print("ascii scan: \(input.utf8.count.formatted()) bytes in \(elapsed)")
        #expect(elapsed < .milliseconds(250))
    }
}
