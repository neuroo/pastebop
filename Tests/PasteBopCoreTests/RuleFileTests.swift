//
//  RuleFileTests.swift
//  PasteBopCoreTests
//

import Testing
@testable import PasteBopCore

@Suite("Rule file")
struct RuleFileTests {

    private func document(_ rules: String) -> String {
        "version: 1\nrules:\n" + rules
    }

    private func reason(_ document: String) -> RuleFile.ParseError.Reason? {
        do {
            _ = try RuleFile.decode(document)
            return nil
        } catch let error as RuleFile.ParseError {
            return error.reason
        } catch {
            return nil
        }
    }

    // MARK: - Round trip

    @Test("Long keys survive the alignment padding")
    func longKeysAreNotTruncated() throws {
        // String.padding(toLength:) truncates; the range key is wider than the
        // column and must still come back whole.
        let text = RuleFile.encode(.builtIn)
        #expect(text.contains("U+E0000..U+E007F"))
        let parsed = try RuleFile.decode(text)
        #expect(parsed.replacements.contains { $0.range == Replacements.tagCharacters })
    }

    @Test("The generated file parses back to exactly the same table")
    func roundTripsTheBuiltInTable() throws {
        let text = RuleFile.encode(.builtIn)
        let parsed = try RuleFile.decode(text)
        #expect(parsed.replacements == RewriteRules.builtIn.replacements)
        #expect(parsed.scalarCount == RewriteRules.builtIn.scalarCount)
    }

    @Test("Re-encoding what was parsed changes nothing")
    func encodingIsStable() throws {
        let text = RuleFile.encode(.builtIn)
        #expect(RuleFile.encode(try RuleFile.decode(text)) == text)
    }

    @Test("A round-tripped table still rewrites the same way")
    func roundTripPreservesBehaviour() throws {
        let parsed = try RuleFile.decode(RuleFile.encode(.builtIn))
        let sample = Replacements.sampleText
        #expect(TextNormalizer.normalize(sample, rules: parsed)
                == TextNormalizer.normalize(sample, rules: .builtIn))
    }

    // MARK: - Reading

    @Test("Reads a minimal file")
    func minimal() throws {
        let rules = try RuleFile.decode(document(#"  U+2014: "--"  # EM DASH"#))
        #expect(rules.replacements.count == 1)
        #expect(TextNormalizer.normalize("a\u{2014}b", rules: rules) == "a--b")
    }

    @Test("An empty rules section turns everything off")
    func emptyRules() throws {
        let rules = try RuleFile.decode("version: 1\nrules:\n")
        #expect(rules.replacements.isEmpty)
        #expect(TextNormalizer.normalize(Replacements.sampleText, rules: rules) == nil)
    }

    @Test("Reads ranges")
    func ranges() throws {
        let rules = try RuleFile.decode(document(#"  U+E0000..U+E007F: ""  # TAG"#))
        #expect(TextNormalizer.normalize("a\u{E0041}b", rules: rules) == "ab")
    }

    @Test("Accepts the quoting styles a person would reach for", arguments: [
        (#"  U+2014: "--""#, "--"),
        (#"  U+2014: '--'"#, "--"),
        (#"  U+2014: """#, ""),
        (#"  U+2014: ''"#, ""),
        (#"  U+2014: " ""#, " "),
        (#"  U+2014: "\"""#, "\""),
        (#"  U+2014: ''''"#, "'"),
        (#"  U+2014: "a\\b""#, #"a\b"#),
        (#"  U+2014: "A""#, "A"),
        (#"  U+2014: "--"   # trailing comment"#, "--"),
        (#"  u+2014: "--""#, "--"),
    ])
    func quoting(_ line: String, _ expected: String) throws {
        let rules = try RuleFile.decode(document(line))
        #expect(rules.replacements.first?.output == expected)
    }

    @Test("A replacement containing a hash is not mistaken for a comment")
    func hashInValue() throws {
        let rules = try RuleFile.decode(document(##"  U+2014: "#"  # EM DASH"##))
        #expect(rules.replacements.first?.output == "#")
    }

    @Test("Keeps the built-in name and family for a character it recognises")
    func recognisedCharacter() throws {
        let rules = try RuleFile.decode(document(#"  U+2014: "-""#))
        let rule = try #require(rules.replacements.first)
        #expect(rule.name == "EM DASH")
        #expect(rule.category == .dashes)
    }

    @Test("Puts an unrecognised character in the custom family")
    func customCharacter() throws {
        let rules = try RuleFile.decode(document(#"  U+00A9: "(c)""#))
        let rule = try #require(rules.replacements.first)
        #expect(rule.category == .custom)
        #expect(TextNormalizer.normalize("\u{a9} 2026", rules: rules) == "(c) 2026")
    }

    @Test("Restores the built-in order regardless of how the file is sorted")
    func ordering() throws {
        let shuffled = document("""
              U+2192: "->"
              U+2014: "--"
              U+00AB: "\\""
            """)
        let rules = try RuleFile.decode(shuffled)
        // Guillemets and em dash come before arrows in the built-in table.
        #expect(rules.replacements.map(\.pattern.firstScalar) == [0x00AB, 0x2014, 0x2192])
    }

    // MARK: - Rejecting

    @Test("Names the line and the problem", arguments: [
        ("rules:\n  U+2014: \"-\"", RuleFile.ParseError.Reason.missingVersion),
        ("version: 2\nrules:\n", .unsupportedVersion(2)),
        ("version: x\nrules:\n", .badVersion("x")),
        ("version: 1\ncolour: blue\n", .unknownKey("colour")),
        ("version: 1\n  U+2014: \"-\"\n", .ruleOutsideRulesSection),
        ("version: 1\nrules\n", .missingColon),
    ])
    func topLevelErrors(_ document: String, _ expected: RuleFile.ParseError.Reason) {
        #expect(reason(document) == expected)
    }

    @Test("Rejects keys that are not scalars", arguments: [
        "  2014: \"-\"", "  U+: \"-\"", "  U+ZZZZ: \"-\"", "  U+110000: \"-\"",
        "  U+D800: \"-\"", "  U+2014..: \"-\"", "  U+1..U+2..U+3: \"-\"",
    ])
    func badKeys(_ line: String) {
        guard case .badScalar = reason(document(line)) else {
            Issue.record("expected badScalar for \(line), got \(String(describing: reason(document(line))))")
            return
        }
    }

    @Test("Rejects a range that ends before it starts")
    func backwardsRange() {
        #expect(reason(document(#"  U+2020..U+2010: """#)) == .emptyRange("U+2020..U+2010"))
    }

    @Test("Rejects a duplicated key and says where it was first set")
    func duplicateKey() {
        let text = document("  U+2014: \"-\"\n  U+2014: \"--\"")
        #expect(reason(text) == .duplicate("U+2014", firstSeenOnLine: 3))
    }

    @Test("Insists the replacement is quoted")
    func unquoted() {
        #expect(reason(document("  U+2014: --")) == .unquotedValue("--"))
        #expect(reason(document("  U+2014:")) == .unquotedValue(""))
    }

    @Test("Rejects a string that never closes")
    func unterminated() {
        #expect(reason(document(#"  U+2014: "--"#)) == .unterminatedString)
        #expect(reason(document(#"  U+2014: "a\"#)) == .unterminatedString)
    }

    @Test("Rejects escapes it does not understand")
    func badEscape() {
        #expect(reason(document(#"  U+2014: "\q""#)) == .badEscape("q"))
        #expect(reason(document(#"  U+2014: "\uZZZZ""#)) == .badEscape("uZZZZ"))
    }

    @Test("Rejects junk after the replacement")
    func trailingJunk() {
        #expect(reason(document(#"  U+2014: "--" oops"#)) == .trailingText("oops"))
    }

    @Test("Every error explains itself with a line number")
    func errorsAreReadable() throws {
        let error = try #require(
            (try? RuleFile.decode(document("  U+2014: --"))) == nil
                ? RuleFile.ParseError(line: 3, reason: .unquotedValue("--"))
                : nil
        )
        let description = try #require(error.errorDescription)
        #expect(description.hasPrefix("Line 3:"))
        #expect(description.contains("quoted"))
    }
}
