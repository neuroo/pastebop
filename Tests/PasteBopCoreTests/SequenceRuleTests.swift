//
//  SequenceRuleTests.swift
//  PasteBopCoreTests
//

import Testing
@testable import PasteBopCore

@Suite("Substring rules")
struct SequenceRuleTests {

    private func rules(_ body: String) throws -> RewriteRules {
        // defaults: [] so the table is exactly what the test declared,
        // rather than the built-in table with it laid over the top.
        RewriteRules(overrides: try RuleFile.decode("version: 1\nrules:\n" + body), defaults: [])
    }

    // MARK: - Matching

    @Test("Replaces a substring written as scalars")
    func scalarSequence() throws {
        let table = try rules(#"  U+0020 U+2014 U+0020: " - ""#)
        #expect(TextNormalizer.normalize("he paused \u{2014} then left", rules: table)
                == "he paused - then left")
    }

    @Test("Replaces a substring written as a literal")
    func literalSequence() throws {
        let table = try rules(#"  " \#u{2014} ": " - ""#)
        #expect(TextNormalizer.normalize("a \u{2014} b", rules: table) == "a - b")
    }

    @Test("A one-character literal key is just a scalar rule")
    func singleCharacterLiteral() throws {
        let table = try rules(#"  "\#u{2014}": "--""#)
        #expect(table.replacements.first?.isSequence == false)
        #expect(TextNormalizer.normalize("a\u{2014}b", rules: table) == "a--b")
    }

    @Test("Deletes a substring")
    func deletingSequence() throws {
        let table = try rules(#"  U+200B U+200B: """#)
        #expect(TextNormalizer.normalize("a\u{200b}\u{200b}b", rules: table) == "ab")
    }

    @Test("A substring beats a single-scalar rule for the same character")
    func sequenceWinsOverScalar() throws {
        let table = try rules("""
              U+2014: "--"
              U+0020 U+2014 U+0020: " - "
            """)
        // The spaced form matches; the bare one still applies elsewhere.
        #expect(TextNormalizer.normalize("a \u{2014} b and c\u{2014}d", rules: table)
                == "a - b and c--d")
    }

    @Test("The longest substring wins")
    func longestWins() throws {
        let table = try rules("""
              U+2014 U+2014: "2"
              U+2014 U+2014 U+2014: "3"
            """)
        #expect(TextNormalizer.normalize("\u{2014}\u{2014}\u{2014}", rules: table) == "3")
        #expect(TextNormalizer.normalize("\u{2014}\u{2014}", rules: table) == "2")
    }

    @Test("A partial match falls through instead of consuming text")
    func partialMatch() throws {
        let table = try rules("""
              U+2014: "--"
              U+2014 U+2014: "=="
            """)
        // One dash then other text: the two-dash rule must not fire.
        #expect(TextNormalizer.normalize("\u{2014}x", rules: table) == "--x")
    }

    @Test("A substring at the very end of the input is not read past")
    func sequenceAtEndOfInput() throws {
        let table = try rules(#"  U+2014 U+2014: "==""#)
        // The second dash is missing, so nothing matches and nothing crashes.
        #expect(TextNormalizer.normalize("ab\u{2014}", rules: table) == nil)
        #expect(TextNormalizer.normalize("ab\u{2014}\u{2014}", rules: table) == "ab==")
    }

    @Test("Substrings work next to astral characters")
    func astralNeighbours() throws {
        let table = try rules(#"  U+1F600 U+2014: "x""#)
        #expect(TextNormalizer.normalize("\u{1F600}\u{2014}!", rules: table) == "x!")
    }

    @Test("An ASCII-leading substring still matches")
    func asciiLeadingSequence() throws {
        let table = try rules(#"  U+003C U+002D U+002D: "<=""#)
        #expect(TextNormalizer.normalize("a <-- b", rules: table) == "a <= b")
    }

    @Test("Pure ASCII input is untouched when no rule starts with ASCII")
    func asciiUntouchedByDefault() {
        #expect(TextNormalizer.normalize("plain ascii -- text") == nil)
    }

    // MARK: - Statistics

    @Test("Counts a substring under its own rule")
    func tallying() throws {
        let table = try rules(#"  U+0020 U+2014 U+0020: " - ""#)
        let tally = TextNormalizer.tally("a \u{2014} b \u{2014} c", rules: table)
        #expect(tally.counts["20.2014.20"] == 2)
        #expect(tally.characterCount == 2)
    }

    @Test("Names a substring in the statistics")
    func offenderName() throws {
        let table = try rules(#"  U+0020 U+2014 U+0020: " - ""#)
        let tally = TextNormalizer.tally("a \u{2014} b", rules: table)
        let offender = try #require(tally.topOffenders(rules: table).first)
        #expect(offender.glyph == " \u{2014} ")
        #expect(offender.category == .custom)
    }

    // MARK: - The file

    @Test("Substrings survive a round trip through the file")
    func roundTrip() throws {
        let body = """
              U+0020 U+2014 U+0020: " - "
              U+200B U+200B: ""
            """
        let overrides = try RuleFile.decode("version: 1\nrules:\n" + body)
        let reparsed = try RuleFile.decode(RuleFile.encode(overrides))
        #expect(reparsed == overrides)
        #expect(RewriteRules(overrides: reparsed, defaults: []).replacements
                == (try rules(body)).replacements)
    }

    @Test("Rejects a range inside a substring")
    func rangeInSequence() {
        let text = "version: 1\nrules:\n  U+0020 U+2010..U+2014: \"-\""
        #expect(throws: RuleFile.ParseError(line: 3, reason: .rangeInSequence("U+2010..U+2014"))) {
            try RuleFile.decode(text)
        }
    }

    @Test("Rejects an empty literal key")
    func emptyLiteralKey() {
        let text = "version: 1\nrules:\n  \"\": \"-\""
        #expect(throws: RuleFile.ParseError(line: 3, reason: .emptySequence)) {
            try RuleFile.decode(text)
        }
    }
}
