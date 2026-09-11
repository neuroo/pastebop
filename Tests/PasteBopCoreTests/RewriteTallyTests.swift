//
//  RewriteTallyTests.swift
//  PasteBopCoreTests
//

import Testing
@testable import PasteBopCore

@Suite("Rewrite tally")
struct RewriteTallyTests {

    @Test("Counts every rewritten character")
    func countsCharacters() {
        let tally = TextNormalizer.tally("\u{201C}a\u{201D}\u{2014}b\u{2014}c\u{2026}")
        #expect(tally.characterCount == 5)
        #expect(tally.counts["2014"] == 2)
        #expect(tally.counts["201c"] == 1)
        #expect(tally.counts["2026"] == 1)
    }

    @Test("Counts nothing for clean text")
    func cleanText() {
        #expect(TextNormalizer.tally("plain ascii").isEmpty)
        #expect(TextNormalizer.tally("caf\u{e9} \u{65e5}\u{672c}").isEmpty)
        #expect(TextNormalizer.tally("").isEmpty)
    }

    @Test("Counts a character covered by a range rule")
    func rangeRule() {
        let tally = TextNormalizer.tally("tag\u{e0041}here")
        #expect(tally.counts["e0000-e007f"] == 1)
        #expect(tally.topOffenders().first?.name == "Tag characters")
    }

    @Test("Ranks the commonest character first")
    func ranking() {
        let tally = TextNormalizer.tally(String(repeating: "\u{2019}", count: 9) + "\u{2014}\u{2014}\u{2026}")
        let top = tally.topOffenders(limit: 2)
        #expect(top.count == 2)
        #expect(top[0].count == 9)
        #expect(top[0].name == "Right single quotation mark")
        #expect(top[0].glyph == "\u{2019}")
        #expect(top[1].count == 2)
        #expect(top[1].name == "Em dash")
    }

    @Test("Hides the glyph for characters that have none")
    func invisibleGlyph() {
        let tally = TextNormalizer.tally("a\u{200b}b\u{a0}c")
        let names = tally.topOffenders()
        #expect(names.allSatisfy { $0.glyph == nil })
    }

    @Test("Groups by family, busiest first")
    func byFamily() {
        let tally = TextNormalizer.tally("\u{201C}\u{201D}\u{2019}\u{2014}\u{2022}")
        let totals = tally.familyTotals()
        // Quotes lead on count; the two singletons tie and fall back to the
        // family name, so "Dashes and hyphens" precedes "List bullets".
        #expect(totals.map(\.category) == [.quotes, .dashes, .bullets])
        #expect(totals.map(\.count) == [3, 1, 1])
    }

    @Test("Family order is stable when counts tie")
    func familyOrderIsStable() {
        let tally = TextNormalizer.tally("\u{2014}\u{2022}")
        // Equal counts fall back to the family name, not the hash order.
        #expect(tally.familyTotals().map(\.category) == [.dashes, .bullets])
    }

    @Test("Adds up")
    func addition() {
        let combined = TextNormalizer.tally("\u{2014}") + TextNormalizer.tally("\u{2014}\u{2026}")
        #expect(combined.counts["2014"] == 2)
        #expect(combined.characterCount == 3)
    }

    @Test("Survives a round trip through storage")
    func storageRoundTrip() {
        let tally = TextNormalizer.tally("\u{201C}a\u{201D}\u{2014}\u{e0041}")
        #expect(RewriteTally(storage: tally.storage) == tally)
    }

    @Test("Ignores junk in stored statistics")
    func storageIgnoresJunk() {
        let tally = RewriteTally(storage: ["2014": 3, "not hex": 9, "": 1])
        #expect(tally.counts == ["2014": 3])
    }
}
