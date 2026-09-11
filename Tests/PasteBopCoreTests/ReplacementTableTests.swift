//
//  ReplacementTableTests.swift
//  PasteBopCoreTests
//
//  Invariants of the table itself. These guard the assumptions the fast path
//  makes, so breaking one here is what stops a silent no-op in production.
//

import Testing
@testable import PasteBopCore

@Suite("Replacement table")
struct ReplacementTableTests {

    @Test("No scalar is listed twice")
    func noDuplicates() {
        var seen: [UInt32: String] = [:]
        for rule in Replacements.all {
            guard let range = rule.range else { continue }
            for value in range {
                let previous = seen.updateValue(rule.name, forKey: value)
                #expect(previous == nil, """
                    U+\(String(value, radix: 16, uppercase: true)) listed as \
                    both \(previous ?? "") and \(rule.name)
                    """)
            }
        }
    }

    @Test("Every rule sits above the ASCII fast-path floor")
    func aboveFloor() {
        // TextNormalizer skips any string that is pure ASCII, and ScalarTable
        // rejects anything below U+00A0 outright. A rule below that line would
        // never fire.
        for rule in Replacements.all {
            #expect(rule.pattern.firstScalar >= ScalarTable.floor,
                    "\(rule.name) is below the lookup floor")
        }
    }

    @Test("Every replacement is typable ASCII")
    func outputsAreASCII() {
        for rule in Replacements.all {
            #expect(rule.output.allSatisfy { $0.isASCII },
                    "\(rule.name) produces non-ASCII \(rule.output)")
        }
    }

    @Test("No replacement reintroduces a character the table rewrites")
    func outputsAreStable() {
        // Guarantees normalisation reaches a fixed point in one pass.
        for rule in Replacements.all {
            for scalar in rule.output.unicodeScalars {
                #expect(RewriteRules.builtIn.table.replacement(for: scalar) == nil,
                        "\(rule.name) emits \(scalar) which is itself rewritten")
            }
        }
    }

    @Test("Characters that must survive are absent from the table", arguments: [
        "é", "ñ", "ü", "ç", "ø", "å", "ß",        // international layouts
        "©", "®", "™", "§", "¶", "°", "€", "£",   // intentional symbols
        "\u{200C}", "\u{200D}",                    // ZWNJ / ZWJ: script and emoji joiners
        "\u{200E}", "\u{200F}",                    // LRM / RLM: real bidi formatting
        "。", "、", "「", "」",                     // CJK punctuation
        "\u{FFFD}",                                // replacement char signals data loss
        "·",                                       // Catalan l·l
    ])
    func preservedCharacters(_ character: String) {
        let table = RewriteRules.builtIn.table
        for scalar in character.unicodeScalars {
            #expect(table.replacement(for: scalar) == nil, "\(character) would be rewritten")
        }
    }
}
