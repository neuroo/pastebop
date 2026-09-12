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

    /// One entry of every shape the file can hold.
    private let sample = RuleOverrides([
        .scalars(0x2014...0x2014): .off,
        .scalars(0x2013...0x2013): .output("--"),
        .scalars(0xE0000...0xE007F): .output(""),
        .sequence([0x0020, 0x2014, 0x0020]): .output(" - "),
        .scalars(0x00A9...0x00A9): .output("(c)"),
    ])

    @Test("Long keys survive the alignment padding")
    func longKeysAreNotTruncated() throws {
        // String.padding(toLength:) truncates; the range key is wider than
        // the column and must still come back whole.
        let text = RuleFile.encode(sample)
        #expect(text.contains("U+E0000..U+E007F"))
        #expect(try RuleFile.decode(text)[.scalars(Replacements.tagCharacters)] == .output(""))
    }

    @Test("The file parses back to exactly the changes it was written from")
    func roundTripsChanges() throws {
        #expect(try RuleFile.decode(RuleFile.encode(sample)) == sample)
    }

    @Test("Re-encoding what was parsed changes nothing")
    func encodingIsStable() throws {
        let text = RuleFile.encode(sample)
        #expect(RuleFile.encode(try RuleFile.decode(text)) == text)
    }

    @Test("A round-tripped set still rewrites the same way")
    func roundTripPreservesBehaviour() throws {
        let parsed = try RuleFile.decode(RuleFile.encode(sample))
        let text = Replacements.sampleText
        #expect(TextNormalizer.normalize(text, rules: RewriteRules(overrides: parsed))
                == TextNormalizer.normalize(text, rules: RewriteRules(overrides: sample)))
    }

    @Test("A file with nothing changed round-trips to nothing changed")
    func roundTripsNoChanges() throws {
        let text = RuleFile.encode(.none)
        let parsed = try RuleFile.decode(text)
        #expect(parsed.isEmpty)
        #expect(RewriteRules(overrides: parsed).replacements == RewriteRules.builtIn.replacements)
    }

    @Test("Switching every character off writes a file that still parses")
    func roundTripsEverythingOff() throws {
        var everything = RuleOverrides()
        for rule in Replacements.all { everything[rule.pattern] = .off }
        let parsed = try RuleFile.decode(RuleFile.encode(everything))
        #expect(RewriteRules(overrides: parsed).replacements.isEmpty)
        // Nil, not an identical copy: with nothing switched on the clipboard
        // is left alone rather than rewritten to itself.
        #expect(TextNormalizer.normalize("\u{2014}\u{201C}", rules: RewriteRules(overrides: parsed)) == nil)
    }

    @Test("off is a keyword; \"off\" is the literal text")
    func offKeywordVersusQuotedOff() throws {
        #expect(try RuleFile.decode(document(#"  U+2014: off"#))[.scalars(0x2014...0x2014)] == .off)
        #expect(try RuleFile.decode(document(#"  U+2014: "off""#))[.scalars(0x2014...0x2014)]
                == .output("off"))
    }

    @Test("A document past the size limit is refused by the parser itself")
    func refusesAnOversizedDocument() {
        // RuleStore stats the file before reading it, but that guard cannot
        // see a table arriving from anywhere else. Everything reaches a table
        // through decode, so the ceiling lives here too.
        let huge = String(repeating: "x", count: RuleFile.Limits.fileBytes + 1)
        #expect(reason(huge) == .fileTooLarge(bytes: RuleFile.Limits.fileBytes + 1))
    }

    @Test("An entry line reads back on its own")
    func decodesOneEntry() throws {
        // What iCloud holds is read this way, an entry at a time: decoding
        // them together would make one line from a newer version read as
        // "everything was deleted".
        let entry = try #require(RuleFile.decodeEntry(
            RuleFile.line(for: .scalars(0x2026...0x2026), .output("..."))
        ))
        #expect(entry.pattern == .scalars(0x2026...0x2026))
        #expect(entry.change == .output("..."))
    }

    @Test("A line this build cannot read says so rather than reading as empty")
    func decodeEntryRejectsWhatItCannotRead() {
        // Nil has to be distinguishable from "no entry": the sync treats the
        // two completely differently, and getting it wrong deletes rules.
        #expect(RuleFile.decodeEntry("U+NOPE: \"x\"") == nil)
        #expect(RuleFile.decodeEntry("") == nil)
    }

    // MARK: - Reading

    private func output(_ overrides: RuleOverrides, _ scalar: UInt32) -> String? {
        overrides[.scalars(scalar...scalar)]?.output
    }

    @Test("Reads a minimal file")
    func minimal() throws {
        let overrides = try RuleFile.decode(document(#"  U+2014: "--"  # EM DASH"#))
        #expect(overrides.count == 1)
        #expect(TextNormalizer.normalize("a\u{2014}b", rules: RewriteRules(overrides: overrides))
                == "a--b")
    }

    @Test("An empty rules section leaves every default in place")
    func emptyRules() throws {
        // The file holds changes, so saying nothing is how you ask for the
        // defaults — not how you turn everything off.
        let overrides = try RuleFile.decode("version: 1\nrules:\n")
        #expect(overrides.isEmpty)
        #expect(RewriteRules(overrides: overrides).replacements == RewriteRules.builtIn.replacements)
    }

    @Test("Reads ranges")
    func ranges() throws {
        // A range with no built-in rule, so the file is what puts it there.
        let overrides = try RuleFile.decode(document(#"  U+2500..U+257F: ""  # BOX DRAWING"#))
        #expect(overrides[.scalars(0x2500...0x257F)] == .output(""))
        #expect(TextNormalizer.normalize("a\u{2502}b", rules: RewriteRules(overrides: overrides))
                == "ab")
    }

    @Test("Switches a character off")
    func readsOff() throws {
        let overrides = try RuleFile.decode(document(#"  U+2014: off  # EM DASH"#))
        #expect(overrides[.scalars(0x2014...0x2014)] == .off)
        #expect(RewriteRules(overrides: overrides).rule(for: 0x2014) == nil)
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
        #expect(output(try RuleFile.decode(document(line)), 0x2014) == expected)
    }

    @Test("Control characters in a replacement survive the round trip", arguments: [
        "\r", "\n", "\t", "a\rb", "\r\n",
        // Everything else `CharacterSet.newlines` splits on: a line holding
        // one of these came back as two, and the file no longer parsed.
        "\u{0085}", "\u{2028}", "\u{2029}", "\u{000B}", "\u{000C}", "a\u{2028}b",
    ])
    func controlCharactersRoundTrip(_ output: String) throws {
        let overrides = RuleOverrides([.scalars(0x2014...0x2014): .output(output)])
        #expect(try RuleFile.decode(RuleFile.encode(overrides)) == overrides)
    }

    @Test("A separator inside a pattern survives too", arguments: [
        0x0085, 0x2028, 0x2029, 0x000B, 0x000C, 0x000A, 0x000D,
    ] as [UInt32])
    func separatorsInPatternsRoundTrip(_ scalar: UInt32) throws {
        // Not the replacement this time: a substring's generated comment is
        // the substring itself, so the separator ended the line from there.
        let overrides = RuleOverrides([.sequence([0x0061, scalar, 0x0062]): .output("X")])
        #expect(try RuleFile.decode(RuleFile.encode(overrides)) == overrides)
    }

    @Test("A replacement containing a hash is not mistaken for a comment")
    func hashInValue() throws {
        #expect(output(try RuleFile.decode(document(##"  U+2014: "#"  # EM DASH"##)), 0x2014) == "#")
    }

    @Test("Keeps the built-in name and family for a character it recognises")
    func recognisedCharacter() throws {
        let overrides = try RuleFile.decode(document(#"  U+2014: "-""#))
        let rule = try #require(RewriteRules(overrides: overrides).rule(for: 0x2014))
        #expect(rule.name == "EM DASH")
        #expect(rule.category == .dashes)
    }

    @Test("Puts an unrecognised character in the custom family")
    func customCharacter() throws {
        let overrides = try RuleFile.decode(document(#"  U+00A9: "(c)""#))
        let rules = RewriteRules(overrides: overrides)
        let rule = try #require(rules.rule(for: 0x00A9))
        #expect(rule.category == .custom)
        #expect(TextNormalizer.normalize("\u{a9} 2026", rules: rules) == "(c) 2026")
    }

    @Test("The built-in order survives however the file is sorted")
    func ordering() throws {
        let shuffled = document("""
              U+2192: "->"
              U+2014: "--"
              U+00AB: "\\""
            """)
        let rules = RewriteRules(overrides: try RuleFile.decode(shuffled))
        // The table keeps built-in order regardless of how the file is
        // written, so the Help window does not reshuffle.
        #expect(rules.replacements.map(\.pattern.firstScalar)
                == RewriteRules.builtIn.replacements.map(\.pattern.firstScalar))
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
