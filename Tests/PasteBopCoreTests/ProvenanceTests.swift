//
//  ProvenanceTests.swift
//  PasteBopCoreTests
//

import Foundation
import Testing
@testable import PasteBopCore

@Suite("Provenance")
struct ProvenanceTests {

    /// Reads a real string the way the app does: rewrite it, then judge it by
    /// the rules that fired.
    private func reading(_ text: String) -> Provenance {
        Provenance(tally: TextNormalizer.tally(text), characterCount: text.unicodeScalars.count)
    }

    private func padded(_ core: String, to length: Int = 400) -> String {
        core + String(repeating: "a", count: max(0, length - core.unicodeScalars.count))
    }

    @Test("Says nothing about a short copy")
    func shortCopyIsInconclusive() {
        // A tweet's worth of text with one em dash proves nothing.
        let short = "Wait\u{2014}what? It\u{2019}s fine\u{2026}"
        #expect(reading(short).reading == .inconclusive)
        #expect(reading(short).summary == nil)
    }

    @Test("Says nothing when nothing was rewritten")
    func cleanTextIsInconclusive() {
        #expect(reading(padded("Plain ASCII prose with no typography at all. ")).reading
                == .inconclusive)
    }

    @Test("Smart quotes alone read as word-processed, not machine-written")
    func smartQuotesAreAutocorrect() {
        // What Pages and Word do to anything you type. One family, high volume.
        let typed = padded(String(
            repeating: "It\u{2019}s the user\u{2019}s text, typed by hand. ", count: 12
        ))
        let result = reading(typed)
        #expect(result.reading == .polished)
        #expect(result.isMachineWritten == false)
        #expect(result.summary?.contains("word-processed") == true)
    }

    @Test("Quotes, dashes and ellipses together read as machine-written")
    func assistantProseIsMachineWritten() {
        let assistant = padded("""
            Here\u{2019}s the thing\u{2014}there are a few considerations worth \
            weighing. It\u{2019}s not simply a matter of speed\u{2014}though that \
            matters\u{2026} The \u{201C}right\u{201D} answer depends on context, \
            and it\u{2019}s worth being precise about that\u{2014}rather than \
            reaching for a rule of thumb\u{2026}
            """)
        let result = reading(assistant)
        #expect(result.isMachineWritten)
        #expect(result.summary?.hasPrefix("Reads machine-written") == true)
        #expect(result.signals.contains("em dashes"))
    }

    @Test("Names the signals commonest first")
    func signalsAreRanked() {
        let text = padded(String(repeating: "a\u{2019}b\u{2019}c\u{2014}d\u{2026}e ", count: 20))
        let result = reading(text)
        // Two curly quotes per repeat against one dash and one ellipsis.
        #expect(result.signals.first == "curly quotes")
        #expect(result.signals.count == 3)
    }

    @Test("Density is per thousand characters")
    func densityScale() {
        var tally = RewriteTally()
        tally.record("2014", times: 5)
        let result = Provenance(tally: tally, characterCount: 1000)
        #expect(result.density == 5)
    }

    @Test("Ignores rules that are not fingerprints")
    func nonMarkerRulesDoNotCount() {
        // Bullets and arrows get rewritten too, but say nothing about origin.
        var tally = RewriteTally()
        tally.record("2022", times: 40)
        tally.record("2192", times: 40)
        let result = Provenance(tally: tally, characterCount: 1000)
        #expect(result.reading == .inconclusive)
        #expect(result.density == 0)
    }

    @Test("Survives a zero-length copy")
    func emptyInput() {
        let result = Provenance(tally: RewriteTally(), characterCount: 0)
        #expect(result.reading == .inconclusive)
        #expect(result.density == 0)
    }

    @Test("Reads only integers, never text")
    func usesOnlyCounts() {
        // Same counts, same verdict, whatever the text actually said.
        var tally = RewriteTally()
        tally.record("2014", times: 4)
        tally.record("2019", times: 9)
        tally.record("2026", times: 2)
        let first = Provenance(tally: tally, characterCount: 900)
        let second = Provenance(tally: tally, characterCount: 900)
        #expect(first == second)
        #expect(first.isMachineWritten)
    }
}

@Suite("Provenance in the report")
struct ProvenanceReportTests {

    private static let locale = Locale(identifier: "en_US")

    private func report(copies: Int, machine: Int, last: Provenance? = nil) -> ActivityReport {
        var tally = RewriteTally()
        tally.record("2014", times: 3)
        return ActivityReport(
            isEnabled: true,
            copyCount: copies,
            tally: tally,
            locale: Self.locale,
            lastProvenance: last,
            machineWrittenCopies: machine
        )
    }

    @Test("Withholds a percentage until it means something")
    func tooFewCopiesForAShare() {
        #expect(report(copies: 9, machine: 6).machineShareLine == nil)
        #expect(report(copies: 10, machine: 6).machineShareLine == "60% of it read as machine-written")
    }

    @Test("Shows nothing for a copy it could not read")
    func inconclusiveLastCopy() {
        let inconclusive = Provenance(tally: RewriteTally(), characterCount: 10)
        #expect(report(copies: 20, machine: 3, last: inconclusive).lastCopyLine == nil)
    }

    @Test("Reports the last copy when there is something to say")
    func lastCopyLine() {
        var tally = RewriteTally()
        tally.record("2014", times: 4)
        tally.record("2019", times: 8)
        let machine = Provenance(tally: tally, characterCount: 900)
        let line = report(copies: 20, machine: 3, last: machine).lastCopyLine
        #expect(line?.hasPrefix("Reads machine-written") == true)
    }
}
